#!/bin/bash
#===============================================================================
# build-app.sh — compile BackupManagerApp (SPM) and assemble it into a
# double-clickable, ad-hoc signed BackupManager.app bundle. No Xcode.app
# required — only Command Line Tools (swiftc, iconutil, codesign).
#===============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_MANAGER_DIR="$HOME/backup-manager"
BRAND_DIR="$PROJECT_DIR/Sources/BackupManagerApp/Resources/Brand"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="BackupManager"
APP_DIR="$PROJECT_DIR/dist/$APP_NAME.app"
BUNDLE_ID="com.mednor.backupmanager"
# Défauts si BM_VERSION/BM_BUILD_NUMBER ne sont pas fournis : le dernier tag
# git (pas un "0.1.0" figé) et un timestamp (comme release.sh) plutôt qu'un
# "1" toujours plus vieux que n'importe quelle vraie release publiée -- sinon
# Sparkle croit l'app installée périmée et propose sans fin de "mettre à jour"
# vers la version qu'on vient littéralement de builder (vécu le 12/07/2026).
GIT_TAG_VERSION="$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
VERSION="${BM_VERSION:-${GIT_TAG_VERSION:-0.1.0}}"
BUILD_NUMBER="${BM_BUILD_NUMBER:-$(date +%s)}"
[ -n "${BM_VERSION:-}" ] || echo "==> BM_VERSION non fourni -- utilise le dernier tag git : $VERSION"
[ -n "${BM_BUILD_NUMBER:-}" ] || echo "==> BM_BUILD_NUMBER non fourni -- utilise un timestamp : $BUILD_NUMBER"
FEED_URL="https://github.com/mednordz/backup-manager-app/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_KEY="FmMS3RHcMSVyDbbY7YbaNL3ypevcrVc1mWvHC5U2liE="
BMENGINE_SIGN_IDENTITY="Backup Manager Self-Signed"

echo "==> swift build -c release"
cd "$PROJECT_DIR"
swift build -c release

BIN_PATH="$BUILD_DIR/release/BackupManagerApp"
[ -x "$BIN_PATH" ] || { echo "build failed: $BIN_PATH not found" >&2; exit 1; }

BMENGINE_BIN="$BUILD_DIR/release/bmengine"
[ -x "$BMENGINE_BIN" ] || { echo "build failed: $BMENGINE_BIN not found" >&2; exit 1; }
security find-identity -p codesigning 2>/dev/null | grep -q "$BMENGINE_SIGN_IDENTITY" || {
  echo "build failed: signing identity '$BMENGINE_SIGN_IDENTITY' not in keychain — see $BACKUP_MANAGER_DIR/_signing/README.txt" >&2
  exit 1
}

SPARKLE_FRAMEWORK="$BUILD_DIR/arm64-apple-macosx/release/Sparkle.framework"
[ -d "$SPARKLE_FRAMEWORK" ] || SPARKLE_FRAMEWORK="$(find "$BUILD_DIR" -maxdepth 4 -iname "Sparkle.framework" -print -quit)"
[ -d "$SPARKLE_FRAMEWORK" ] || { echo "build failed: Sparkle.framework not found" >&2; exit 1; }

echo "==> assembling app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# ------------------------------------------------------------------------------
# Backend Flask embarqué (Resources/backup-manager-src) : sur un Mac où l'app
# n'a jamais tourné, ~/backup-manager n'existe pas — FlaskSupervisor le
# bootstrape depuis cette copie au premier lancement (voir
# FlaskSupervisor.bootstrapBackendIfNeeded). Liste blanche EXPLICITE, jamais
# un `cp -R` du dossier source entier : celui-ci contient aussi _signing/
# (clé privée de signature bmengine) et .venv/, qui ne doivent JAMAIS finir
# dans un DMG distribué publiquement.
# ------------------------------------------------------------------------------
echo "==> bundling Flask backend (Resources/backup-manager-src)"
BACKEND_DEST="$APP_DIR/Contents/Resources/backup-manager-src"
mkdir -p "$BACKEND_DEST/bin"
for item in app.py backup-engine.sh progress-parse.py verify-parse.py requirements.txt static docs; do
  cp -R "$BACKUP_MANAGER_DIR/$item" "$BACKEND_DEST/$item"
done
find "$BACKEND_DEST" -name ".DS_Store" -delete

echo "==> building + signing bmengine (identity: $BMENGINE_SIGN_IDENTITY)"
cp "$BMENGINE_BIN" "$BACKEND_DEST/bin/bmengine"
codesign --force --sign "$BMENGINE_SIGN_IDENTITY" \
  --identifier "com.mednor.backupmanager.engine" "$BACKEND_DEST/bin/bmengine"

# rsync moderne embarqué : Apple ne fournit qu'un openrsync ancien (pas de
# --backup-dir, pas de -A/-X), donc l'app a TOUJOURS nécessité un rsync
# Homebrew installé à part — sans automatisation aucune jusqu'ici (constaté en
# usage réel : un Mac sans Homebrew reste bloqué sur "rsync introuvable", sans
# rien pour corriger ça). vendor-rsync.sh relocalise le rsync Homebrew de la
# machine de build (+ ses dylibs) en un paquet autonome, sans référence à
# /opt/homebrew — il tourne donc sur n'importe quel Mac, avec ou sans Homebrew.
echo "==> vendoring rsync (self-contained, no Homebrew required on target)"
"$PROJECT_DIR/scripts/vendor-rsync.sh" "$BUILD_DIR/rsync-vendor"
cp "$BUILD_DIR/rsync-vendor/bin/rsync" "$BACKEND_DEST/bin/rsync"
mkdir -p "$BACKEND_DEST/lib"
cp "$BUILD_DIR/rsync-vendor/lib/"*.dylib "$BACKEND_DEST/lib/"
mkdir -p "$BACKEND_DEST/THIRD-PARTY-NOTICES"
cat > "$BACKEND_DEST/THIRD-PARTY-NOTICES/rsync.txt" <<'NOTICE'
rsync est distribué sous licence GPLv3 (Copyright Andrew Tridgell, Wayne
Davison et contributeurs). Binaire fourni tel quel, non modifié, compilé par
le projet Homebrew (formule "rsync"). Code source :
  https://github.com/RsyncProject/rsync
  https://formulae.brew.sh/formula/rsync (recette de compilation)
Texte complet de la licence : https://www.gnu.org/licenses/gpl-3.0.txt
NOTICE

echo "==> embedding Sparkle.framework"
rm -rf "$APP_DIR/Contents/Frameworks/Sparkle.framework"
cp -R "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
install_name_tool -change \
  "@rpath/Sparkle.framework/Versions/B/Sparkle" \
  "@executable_path/../Frameworks/Sparkle.framework/Versions/B/Sparkle" \
  "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null || true

echo "==> bundling help.html + help-images (menu Aide)"
cp "$PROJECT_DIR/Sources/BackupManagerApp/Resources/help.html" "$APP_DIR/Contents/Resources/help.html"
cp -R "$PROJECT_DIR/Sources/BackupManagerApp/Resources/help-images" "$APP_DIR/Contents/Resources/help-images"

echo "==> bundling uninstall.sh (menu Aide -> Désinstaller complètement…)"
cp "$PROJECT_DIR/Sources/BackupManagerApp/Resources/uninstall.sh" "$APP_DIR/Contents/Resources/uninstall.sh"
chmod +x "$APP_DIR/Contents/Resources/uninstall.sh"

echo "==> generating icons from $BRAND_DIR (brand kit)"
# AppIcon : composé une fois (tuile blanche + symbole officiel centré à 60% de
# hauteur, rayon 25% -- voir design_handoff_brand/README.md) et vérifié
# manuellement ; déjà carré (1024x1024), simple redimensionnement ici, aucune
# dépendance externe (sips est du CLT de base, contrairement à rsvg-convert).
ICONSET="$PROJECT_DIR/.build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$BRAND_DIR/appicon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$BRAND_DIR/appicon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

# menubar status-item icon : symbole officiel en COULEURS RÉELLES, pas un
# template monochrome -- la charte montre explicitement ce contexte en
# couleur (Brand Board, panneau "BARRE DE MENUS"). isTemplate=false côté
# Swift (AppDelegate/MenuBarStatus) ; le statut d'activité se signale par un
# petit badge superposé, jamais en recolorant le symbole. Pas carrée
# (1024x1179) : -Z préserve le ratio plutôt que déformer.
#
# symbol-dark-bg.png (pas symbol.png) : la barre de menus est un fond SOMBRE,
# or symbol.png a le haut en encre foncee (#0D1117), prevu pour une plaque
# CLAIRE (AppIcon/avatar) -- utilise tel quel ici, le haut du symbole devenait
# quasi invisible (encre sur fond sombre). symbol-dark-bg.png est une variante
# derivee (meme forme, meme degrade menthe en bas, INCHANGE) avec le haut
# recolore en #F4F7FB (le token "texte fort" officiel de la charte, jamais un
# blanc pur) -- exactement la meme logique de contraste que lockup-dark.png
# (texte clair sur fond sombre) applique au symbole seul. Constate en
# conditions reelles le 19/07/2026 (captures d'ecran utilisateur).
sips -Z 18 "$BRAND_DIR/symbol-dark-bg.png" --out "$APP_DIR/Contents/Resources/StatusIcon.png" >/dev/null
sips -Z 36 "$BRAND_DIR/symbol-dark-bg.png" --out "$APP_DIR/Contents/Resources/StatusIcon@2x.png" >/dev/null

echo "==> writing Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Backup Manager</string>
  <key>CFBundleDisplayName</key><string>Backup Manager</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Backup Manager</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

echo "==> writing entitlements"
# Sparkle.framework ships pre-signed under its own Team ID; hardened runtime's
# Library Validation otherwise refuses to load a differently-signed embedded
# framework from an ad-hoc-signed host app. This is Sparkle's own documented
# fix — it disables only that one check, not the rest of hardened runtime.
ENTITLEMENTS="$BUILD_DIR/entitlements.plist"
cat > "$ENTITLEMENTS" <<ENTPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
ENTPLIST

echo "==> codesign (ad-hoc, stable identifier: $BUNDLE_ID)"
codesign --force --deep --sign - --identifier "$BUNDLE_ID" --options runtime \
  --entitlements "$ENTITLEMENTS" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "==> done: $APP_DIR"

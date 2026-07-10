#!/bin/bash
#===============================================================================
# make-dmg.sh — build BackupManager.app (via build-app.sh) and package it into
# a distributable, ad-hoc signed .dmg with a drag-to-Applications layout.
# No Xcode.app required.
#===============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="BackupManager"
APP_DIR="$PROJECT_DIR/dist/$APP_NAME.app"
BUNDLE_ID="com.mednor.backupmanager"
STAGING="$PROJECT_DIR/.build/dmg-staging"

echo "==> build-app.sh"
"$PROJECT_DIR/scripts/build-app.sh"

# Read the version back from the just-built Info.plist (reflects BM_VERSION
# if the caller set it) rather than computing it before the rebuild.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo 0.1.0)"
DMG_NAME="$APP_NAME-$VERSION"
DMG_OUT="$PROJECT_DIR/dist/$DMG_NAME.dmg"

echo "==> staging DMG contents"
rm -rf "$STAGING" "$DMG_OUT"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Copie du guide d'aide à la racine du DMG (lisible avant même d'ouvrir
# l'app — utile pour la section Gatekeeper du guide, sinon impossible à
# consulter tant que l'app elle-même est bloquée). Repris depuis le bundle
# déjà construit par build-app.sh, pas une seconde copie indépendante.
cp "$APP_DIR/Contents/Resources/help.html" "$STAGING/Guide d'utilisation.html"
cp -R "$APP_DIR/Contents/Resources/help-images" "$STAGING/help-images"

echo "==> creating $DMG_OUT"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_OUT" >/dev/null

echo "==> codesign (ad-hoc, stable identifier: $BUNDLE_ID)"
codesign --force --sign - --identifier "$BUNDLE_ID.dmg" "$DMG_OUT"
codesign --verify "$DMG_OUT"

rm -rf "$STAGING"
echo "==> done: $DMG_OUT"

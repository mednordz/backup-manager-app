#!/bin/bash
#===============================================================================
# release.sh — build a signed .dmg, generate/update the Sparkle appcast, and
# publish both as a GitHub Release (repo must already exist + `gh auth login`
# already done). Usage: scripts/release.sh <version> [build_number] [notes_file]
#
# Notes de version : generate_appcast embarque automatiquement dans
# l'appcast (donc dans la fenêtre de mise à jour Sparkle) tout fichier
# .md/.html/.txt qui porte le même nom que l'archive — voir
# releases/BackupManager-<version>.md ci-dessous.
#===============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: release.sh <version> [build_number] [notes_file]}"
BUILD_NUMBER="${2:-$(date +%s)}"
NOTES_FILE_ARG="${3:-}"
RELEASES_DIR="$PROJECT_DIR/releases"
GENERATE_APPCAST="$(find "$PROJECT_DIR/.build/artifacts/sparkle" -iname generate_appcast -print -quit)"
NOTES_FILE="$RELEASES_DIR/BackupManager-$VERSION.md"

[ -x "$GENERATE_APPCAST" ] || { echo "generate_appcast not found — run 'swift build' first" >&2; exit 1; }

mkdir -p "$RELEASES_DIR"

#------------------------------------------------------------------------------
# PORTAIL D'ÉPREUVES DU BACKEND — BLOQUANT, contrairement à check-help-coverage.
#
# Le DMG embarque le backend tel qu'il est dans ~/backup-manager : c'est LUI
# qu'on publie. Leçon des 2026-07-25/30 : un moteur syntaxiquement invalide
# sous bash 3.2 a été publié et a vécu six jours, et un bug de normalisation
# Unicode quatre, parce que les épreuves n'étaient pas rejouées à chaque
# publication. La partie rapide (< 10 s, sans matériel) tourne donc ici, et
# son échec ARRÊTE la release. La partie complète (disque jetable + NAS) reste
# manuelle : tests/lancer.sh --complet.
#------------------------------------------------------------------------------
BM_SRC_DIR="${BM_SRC_DIR:-$HOME/backup-manager}"
if [ -x "$BM_SRC_DIR/tests/lancer.sh" ]; then
  echo "==> épreuves du backend (bloquant)"
  "$BM_SRC_DIR/tests/lancer.sh" || {
    echo "ERREUR : les épreuves du backend échouent — publication refusée." >&2
    exit 1
  }
else
  echo "ERREUR : $BM_SRC_DIR/tests/lancer.sh introuvable — le portail d'épreuves est obligatoire." >&2
  exit 1
fi

echo "==> notes de version"
if [ -n "$NOTES_FILE_ARG" ]; then
  cp "$NOTES_FILE_ARG" "$NOTES_FILE"
else
  LAST_TAG="$(cd "$PROJECT_DIR" && git describe --tags --abbrev=0 2>/dev/null || true)"
  if [ ! -f "$NOTES_FILE" ]; then
    {
      echo "# Nouveautés — $VERSION"
      echo
      if [ -n "$LAST_TAG" ]; then
        (cd "$PROJECT_DIR" && git log "$LAST_TAG..HEAD" --pretty="format:- %s" | grep -v '^- Bump version' || true)
      fi
    } > "$NOTES_FILE"
  fi
  "${EDITOR:-nano}" "$NOTES_FILE"
fi
[ -s "$NOTES_FILE" ] || { echo "notes de version vides, abandon (fichier: $NOTES_FILE)" >&2; exit 1; }

echo "==> building BackupManager-$VERSION.dmg (build $BUILD_NUMBER)"
BM_VERSION="$VERSION" BM_BUILD_NUMBER="$BUILD_NUMBER" "$PROJECT_DIR/scripts/make-dmg.sh"

echo "==> smoke-test du bundle avant publication"
"$PROJECT_DIR/scripts/smoke-test.sh" "$PROJECT_DIR/dist/BackupManager.app"

echo "==> couverture de l'Aide (informatif, ne bloque pas la release)"
"$PROJECT_DIR/scripts/check-help-coverage.sh" || true

cp "$PROJECT_DIR/dist/BackupManager-$VERSION.dmg" "$RELEASES_DIR/"

echo "==> signing + generating appcast.xml (avec notes de version embarquées)"
"$GENERATE_APPCAST" "$RELEASES_DIR"

echo "==> creating + pushing git tag v$VERSION"
cd "$PROJECT_DIR"
HEAD_COMMIT="$(git rev-parse HEAD)"
TAG_WAS_NEW=1
if EXISTING_TAG_COMMIT="$(git rev-parse "v$VERSION^{commit}" 2>/dev/null)"; then
  if [ "$EXISTING_TAG_COMMIT" != "$HEAD_COMMIT" ]; then
    echo "ERREUR : le tag v$VERSION existe déjà et pointe vers un autre commit ($EXISTING_TAG_COMMIT), pas HEAD ($HEAD_COMMIT) — abandon pour ne pas écraser un tag déjà publié." >&2
    exit 1
  fi
  echo "• tag v$VERSION existe déjà et pointe déjà vers HEAD — republication à l'identique"
  TAG_WAS_NEW=0
  TAG_FORCE=(-f)
else
  TAG_FORCE=()
fi
# ${arr[@]+"${arr[@]}"} et non "${arr[@]}" : sous `set -u`, bash 3.2 (celui de
# macOS, /bin/bash) traite le développement d'un tableau VIDE comme une
# variable non définie et avorte. Or TAG_FORCE est justement vide dans le cas
# NORMAL -- publier une version neuve. Le script ne fonctionnait donc que pour
# une republication à l'identique, où TAG_FORCE vaut (-f). Même règle que
# backup-engine.sh, qui cible aussi bash 3.2 (voir CLAUDE.md).
git tag ${TAG_FORCE[@]+"${TAG_FORCE[@]}"} "v$VERSION"
git push ${TAG_FORCE[@]+"${TAG_FORCE[@]}"} origin "v$VERSION"

# Si la publication de la release GitHub échoue APRÈS ce point, le tag public
# resterait orphelin (poussé mais sans release associée). On le retire alors
# pour repartir d'un état propre -- sauf si ce tag existait déjà avant cette
# invocation (republication à l'identique, cf. TAG_WAS_NEW ci-dessus) : dans
# ce cas il n'est pas "nouveau" et pourrait déjà avoir une release légitime.
GH_RELEASE_OK=0
cleanup_orphan_tag() {
  if [ "$GH_RELEASE_OK" != "1" ] && [ "$TAG_WAS_NEW" = "1" ]; then
    echo "==> échec après publication du tag -- retrait du tag orphelin v$VERSION (local + distant)" >&2
    git tag -d "v$VERSION" >/dev/null 2>&1 || true
    git push origin ":refs/tags/v$VERSION" >/dev/null 2>&1 || true
  fi
}
trap cleanup_orphan_tag EXIT

echo "==> publishing GitHub release"
# Les fichiers .delta produits par generate_appcast ci-dessus n'étaient PAS
# publiés : seuls le DMG, l'appcast et les notes l'étaient. L'appcast annonçait
# donc des URL de mise à jour différentielle qui répondaient toutes 404 (constaté
# en vrai sur les releases 0.2.34 à 0.2.36 : 15 deltas générés, aucun publié).
# Sparkle retombe sur le DMG complet, donc rien ne cassait -- la mise à jour
# différentielle, elle, n'a simplement jamais servi, alors que tout le travail
# de génération était fait à chaque publication.
# Tous les deltas vont sur la release LA PLUS RÉCENTE, pas sur celle de leur
# version d'origine : les URL de l'appcast pointent vers /releases/latest/download/.
# ${arr[@]+"${arr[@]}"} et non "${arr[@]}" -- même règle bash 3.2 que pour
# TAG_FORCE plus haut, sous `set -u` un tableau vide avorterait le script.
DELTAS=()
for d in "$RELEASES_DIR"/*.delta; do
  [ -e "$d" ] && DELTAS+=("$d")
done
echo "• ${#DELTAS[@]} fichier(s) delta à joindre"
if gh release view "v$VERSION" >/dev/null 2>&1; then
  gh release upload "v$VERSION" "$RELEASES_DIR/BackupManager-$VERSION.dmg" "$RELEASES_DIR/appcast.xml" "$NOTES_FILE" \
    ${DELTAS[@]+"${DELTAS[@]}"} --clobber
  gh release edit "v$VERSION" --notes-file "$NOTES_FILE"
else
  gh release create "v$VERSION" \
    "$RELEASES_DIR/BackupManager-$VERSION.dmg" \
    "$RELEASES_DIR/appcast.xml" \
    "$NOTES_FILE" \
    ${DELTAS[@]+"${DELTAS[@]}"} \
    --title "BackupManager $VERSION" \
    --notes-file "$NOTES_FILE"
fi
GH_RELEASE_OK=1

echo "==> done: https://github.com/mednordz/backup-manager-app/releases/tag/v$VERSION"

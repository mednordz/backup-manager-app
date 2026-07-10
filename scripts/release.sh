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

cp "$PROJECT_DIR/dist/BackupManager-$VERSION.dmg" "$RELEASES_DIR/"

echo "==> signing + generating appcast.xml (avec notes de version embarquées)"
"$GENERATE_APPCAST" "$RELEASES_DIR"

echo "==> creating + pushing git tag v$VERSION"
cd "$PROJECT_DIR"
git tag -f "v$VERSION"
git push -f origin "v$VERSION"

echo "==> publishing GitHub release"
if gh release view "v$VERSION" >/dev/null 2>&1; then
  gh release upload "v$VERSION" "$RELEASES_DIR/BackupManager-$VERSION.dmg" "$RELEASES_DIR/appcast.xml" "$NOTES_FILE" --clobber
  gh release edit "v$VERSION" --notes-file "$NOTES_FILE"
else
  gh release create "v$VERSION" \
    "$RELEASES_DIR/BackupManager-$VERSION.dmg" \
    "$RELEASES_DIR/appcast.xml" \
    "$NOTES_FILE" \
    --title "BackupManager $VERSION" \
    --notes-file "$NOTES_FILE"
fi

echo "==> done: https://github.com/mednordz/backup-manager-app/releases/tag/v$VERSION"

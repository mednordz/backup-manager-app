#!/bin/bash
#===============================================================================
# release.sh — build a signed .dmg, generate/update the Sparkle appcast, and
# publish both as a GitHub Release (repo must already exist + `gh auth login`
# already done). Usage: scripts/release.sh <version> [build_number]
#===============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: release.sh <version> [build_number]}"
BUILD_NUMBER="${2:-$(date +%s)}"
RELEASES_DIR="$PROJECT_DIR/releases"
GENERATE_APPCAST="$(find "$PROJECT_DIR/.build/artifacts/sparkle" -iname generate_appcast -print -quit)"

[ -x "$GENERATE_APPCAST" ] || { echo "generate_appcast not found — run 'swift build' first" >&2; exit 1; }

echo "==> building BackupManager-$VERSION.dmg (build $BUILD_NUMBER)"
BM_VERSION="$VERSION" BM_BUILD_NUMBER="$BUILD_NUMBER" "$PROJECT_DIR/scripts/make-dmg.sh"

mkdir -p "$RELEASES_DIR"
cp "$PROJECT_DIR/dist/BackupManager-$VERSION.dmg" "$RELEASES_DIR/"

echo "==> signing + generating appcast.xml"
"$GENERATE_APPCAST" "$RELEASES_DIR"

echo "==> creating git tag v$VERSION"
cd "$PROJECT_DIR"
git tag -f "v$VERSION"

echo "==> publishing GitHub release"
if gh release view "v$VERSION" >/dev/null 2>&1; then
  gh release upload "v$VERSION" "$RELEASES_DIR/BackupManager-$VERSION.dmg" "$RELEASES_DIR/appcast.xml" --clobber
else
  gh release create "v$VERSION" \
    "$RELEASES_DIR/BackupManager-$VERSION.dmg" \
    "$RELEASES_DIR/appcast.xml" \
    --title "BackupManager $VERSION" \
    --notes "Voir les commits pour le détail des changements."
fi

echo "==> done: https://github.com/mednor/backup-manager-app/releases/tag/v$VERSION"

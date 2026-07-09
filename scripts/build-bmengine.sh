#!/bin/bash
#===============================================================================
# build-bmengine.sh — compile et signe le lanceur `bmengine`, puis l'installe
# au chemin STABLE ~/backup-manager/bin/bmengine.
#
# bmengine donne au moteur de backup une identité TCC (Accès complet au disque)
# unique et stable : launchd le lance comme racine de l'arbre, et bash+rsync
# héritent de SON autorisation -> une seule entrée à autoriser dans les Réglages.
#
# La signature utilise le certificat AUTO-SIGNÉ "Backup Manager Self-Signed"
# (trousseau login). Sa designated requirement pointe l'empreinte du certificat,
# donc l'autorisation FDA PERSISTE à travers les recompilations. Voir
# ~/backup-manager/_signing/README.txt pour recréer/réimporter le certificat.
#===============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGN_IDENTITY="Backup Manager Self-Signed"
DEST="$HOME/backup-manager/bin/bmengine"

echo "==> swift build -c release --product bmengine"
cd "$PROJECT_DIR"
swift build -c release --product bmengine

BIN="$PROJECT_DIR/.build/release/bmengine"
[ -x "$BIN" ] || { echo "build failed: $BIN introuvable" >&2; exit 1; }

if ! security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "ERREUR: identité de signature « $SIGN_IDENTITY » absente du trousseau." >&2
  echo "Réimporte-la : voir ~/backup-manager/_signing/README.txt" >&2
  exit 1
fi

echo "==> installation -> $DEST"
mkdir -p "$(dirname "$DEST")"
cp "$BIN" "$DEST"

echo "==> signature (identité stable: $SIGN_IDENTITY)"
codesign --force --sign "$SIGN_IDENTITY" \
  --identifier "com.mednor.backupmanager.engine" "$DEST"

echo "==> designated requirement :"
codesign -d -r- "$DEST" 2>&1 | grep "designated"
echo "==> done: $DEST"

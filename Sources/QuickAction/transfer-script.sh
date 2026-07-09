#!/bin/bash
# Finder Quick Action -> POST /api/transfer (Backup Manager).
# Receives selected Finder items as "$@". Asks for a destination folder,
# then transfers each item in turn (the API refuses concurrent transfers,
# so items are sent sequentially, waiting for each to finish).
set -euo pipefail

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"
BASE="http://$LAN_IP:8787"

DEST="$(osascript -e 'POSIX path of (choose folder with prompt "Destination du transfert :")' 2>/dev/null)" || exit 0
[ -z "$DEST" ] && exit 0

for SRC in "$@"; do
  IS_FILE="false"
  [ -f "$SRC" ] && IS_FILE="true"

  BODY="$(SRC="$SRC" DEST="$DEST" IS_FILE="$IS_FILE" python3 -c '
import json, os
print(json.dumps({
    "source": os.environ["SRC"],
    "dest": os.environ["DEST"],
    "mode": "copy",
    "source_is_file": os.environ["IS_FILE"] == "true",
}))
')"

  curl -s -X POST "$BASE/api/transfer" -H "Content-Type: application/json" -d "$BODY" -o /dev/null

  # Attend la fin de ce transfert avant de lancer le suivant (l'API refuse les transferts concurrents).
  while curl -s "$BASE/api/transfer" 2>/dev/null | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("running") else 1)' 2>/dev/null; do
    sleep 1
  done
done

osascript -e 'display notification "Transfert terminé." with title "Backup Manager"' >/dev/null 2>&1 || true

#!/bin/bash
# Finder Quick Action -> POST /api/transfer (Backup Manager).
# Recoit les elements selectionnes dans "$@". Demande un dossier de
# destination, puis soumet chaque element.
#
# L API ne REFUSE pas les demandes concurrentes (le commentaire precedent le
# pretendait) : elle en lance une et met les suivantes en file d attente,
# reponse 202 {"queued": true}. On soumet donc tout, puis on attend que le
# transfert en cours ET la file soient vides.
set -euo pipefail

# Meme regle que LocalNetwork.swift, qui refuse explicitement de presumer du
# nom de interface. Le "ipconfig getifaddr en0 || en1" en dur qui etait ici
# laissait un Mac dont le LAN passe par un dongle (en5 et au-dela) retomber sur
# 127.0.0.1 -- precisement adresse rendue inutilisable sur cette machine par un
# effet de bord de la regle pf. On prend donc, dans le meme ordre que le code
# Swift : une adresse privee RFC 1918 sur une interface physique, puis a defaut
# la premiere adresse routable trouvee.
lan_ip() {
  local iface addr repli
  repli=""
  for iface in $(ifconfig -lu 2>/dev/null); do
    case "$iface" in
      en*|bridge*) ;;
      *) continue ;;
    esac
    addr="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
    [ -n "$addr" ] || continue
    case "$addr" in
      # 172.16/12 va jusqu a 172.31 seulement : au-dela ce sont des adresses publiques.
      10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
        printf '%s\n' "$addr"
        return 0 ;;
      169.254.*|127.*) ;;
      *) [ -n "$repli" ] || repli="$addr" ;;
    esac
  done
  printf '%s\n' "${repli:-127.0.0.1}"
}

LAN_IP="$(lan_ip)"
BASE="http://$LAN_IP:8787"

DEST="$(osascript -e 'POSIX path of (choose folder with prompt "Destination du transfert :")' 2>/dev/null)" || exit 0
[ -z "$DEST" ] && exit 0

# Detail du dernier refus, renseigne par post_transfer.
ERREUR=""

# Soumet un element et LIT la reponse.
#
# Avant : "curl -s" sans -f, sortie jetee dans /dev/null. Un 400 (destination a
# interieur de la source), un 403 (garde Host) ou un 500 passaient donc pour un
# succes, en silence. Combine a une boucle attente qui sortait aussitot, une
# selection de 3 dossiers pendant un transfert donnait 0 transfert reel et une
# notification "Transfert termine".
#
# -w '\n%{http_code}' ajoute le code HTTP sur une derniere ligne, apres le
# corps : on peut ainsi rendre les deux, sans -f qui masquerait justement le
# message de erreur renvoye par le backend.
post_transfer() {
  local body reponse code corps
  body="$1"
  reponse="$(curl -s -m 30 -w '\n%{http_code}' -X POST "$BASE/api/transfer" \
             -H "Content-Type: application/json" -d "$body")" || {
    ERREUR="serveur injoignable sur $BASE"
    return 1
  }
  code="${reponse##*$'\n'}"
  corps="${reponse%$'\n'*}"
  case "$code" in
    200|201|202) return 0 ;;
  esac
  ERREUR="HTTP $code : $(printf '%s' "$corps" | tr '\n' ' ' | cut -c1-160)"
  return 1
}

ACCEPTES=0
REFUSES=0

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

  if post_transfer "$BODY"; then
    ACCEPTES=$((ACCEPTES + 1))
  else
    REFUSES=$((REFUSES + 1))
    echo "Backup Manager : refus de $SRC -- $ERREUR" >&2
  fi
done

# Attente de la fin REELLE.
#
# ancienne boucle ne testait que "running", et surtout elle confondait deux
# choses : quand curl echouait, python recevait une entree vide, json.load
# levait, le code de sortie valait 1 -- soit exactement le meme signal que
# "plus rien ne tourne". Serveur injoignable se lisait donc "termine". Ici on
# distingue les trois cas, et on attend aussi que la FILE se vide, sans quoi on
# annoncerait la fin alors que des elements attendent encore leur tour.
if [ "$ACCEPTES" -gt 0 ]; then
  while :; do
    ETAT="$(curl -s -m 10 "$BASE/api/transfer" || true)"
    if [ -z "$ETAT" ]; then
      REFUSES=$((REFUSES + 1))
      ERREUR="serveur injoignable pendant attente"
      break
    fi
    printf '%s' "$ETAT" | python3 -c '
import json, sys
try:
    etat = json.load(sys.stdin)
except ValueError:
    sys.exit(2)                      # reponse illisible : on arrete attendre
sys.exit(0 if (etat.get("running") or etat.get("queue")) else 1)
' || break
    sleep 1
  done
fi

# La notification dit la verite, y compris quand elle est mauvaise.
if [ "$REFUSES" -eq 0 ]; then
  MESSAGE="Transfert termine ($ACCEPTES element(s))."
elif [ "$ACCEPTES" -eq 0 ]; then
  MESSAGE="Aucun transfert lance -- $REFUSES refus. $ERREUR"
else
  MESSAGE="$ACCEPTES transfert(s) lance(s), $REFUSES refuse(s). $ERREUR"
fi
# Le detail vient du backend : on retire guillemets et antislashs avant de
# incruster dans le script AppleScript, sinon un message avec un guillemet
# casserait la commande osascript (et la notification disparaitrait avec elle).
MESSAGE="$(printf '%s' "$MESSAGE" | tr -d '"\\' | tr '\n' ' ')"
osascript -e "display notification \"$MESSAGE\" with title \"Backup Manager\"" >/dev/null 2>&1 || true

# Pas de sortie en erreur ici : Automator afficherait sa propre boite de
# dialogue par-dessus, en double de la notification qui vient de tout dire.
exit 0

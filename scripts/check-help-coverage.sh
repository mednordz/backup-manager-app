#!/bin/bash
#===============================================================================
# check-help-coverage.sh — repère les libellés d'interface (boutons, titres,
# champs) du backend qui ne sont mentionnés nulle part dans le guide Aide
# embarqué (help.html).
#
# Ni exhaustif ni infaillible : c'est une extraction heuristique par regex,
# pas un vrai parseur HTML. Objectif = remplacer le grep manuel refait à
# chaque fois qu'on se demande "l'Aide est-elle vraiment à jour ?" par une
# commande unique, pour ne plus se fier seulement à la mémoire de ce qui a
# déjà été documenté. Le rapport est informatif : chaque ligne listée mérite
# un coup d'œil, mais toutes ne méritent pas forcément une section dédiée
# (boutons génériques type "Fermer"/"Annuler" par exemple).
#
# Usage : scripts/check-help-coverage.sh
#===============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_MANAGER_DIR="$HOME/backup-manager"
SRC_HTML="$BACKUP_MANAGER_DIR/static/index.html"
HELP_HTML="$PROJECT_DIR/Sources/BackupManagerApp/Resources/help.html"

[ -f "$SRC_HTML" ] || { echo "introuvable : $SRC_HTML (le dépôt backup-manager est-il cloné à côté ?)" >&2; exit 1; }
[ -f "$HELP_HTML" ] || { echo "introuvable : $HELP_HTML" >&2; exit 1; }

# Libellés visibles : texte de <button>, <h2>, <h3>, <label> (juste avant un
# <input>/<small>), et title="…" — c'est-à-dire tout ce qu'un utilisateur
# peut effectivement lire ou cliquer dans l'interface.
labels=$(
  grep -oE '>[A-ZÀ-Ü][a-zàâäéèêëîïôöùûüçA-ZÀ-Ü0-9 ,'"'"':%.…()/⚡-]{2,50}<' "$SRC_HTML" \
    | sed -E 's/^>//; s/<$//; s/ +$//' \
    | sort -u
)

title_labels=$(
  grep -oE 'title="[^"]{3,60}"' "$SRC_HTML" \
    | sed -E 's/^title="//; s/"$//' \
    | sort -u
)

all_labels=$(printf '%s\n%s\n' "$labels" "$title_labels" | sort -u | grep -v '^$')

missing=0
echo "Libellés de l'interface (backup-manager/static/index.html) absents de help.html :"
echo "---"
while IFS= read -r label; do
  [ -z "$label" ] && continue
  # ignore les libellés triviaux/génériques trop courts pour être signifiants
  case "$label" in
    Fermer|Annuler|Enregistrer|Copier|Déplacer|"Choisir…"|"Dossier…"|"Fichier…") continue ;;
  esac
  if ! grep -qF "$label" "$HELP_HTML"; then
    echo "  - $label"
    missing=$((missing + 1))
  fi
done <<< "$all_labels"

echo "---"
if [ "$missing" -eq 0 ]; then
  echo "Aucun écart détecté — tous les libellés extraits apparaissent dans help.html."
else
  echo "$missing libellé(s) potentiellement non documenté(s). Chacun ne mérite pas forcément"
  echo "une section — mais avant de dire \"l'Aide est complète\", vérifier cette liste plutôt"
  echo "que de se fier à la relecture du guide seul."
fi

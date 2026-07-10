#!/bin/bash
#===============================================================================
# vendor-rsync.sh — relocalise le rsync Homebrew (+ ses dylibs) en un paquet
# autonome, sans dépendance à /opt/homebrew, pour l'embarquer dans l'app.
#
# Pourquoi : Apple ne fournit qu'un openrsync ancien (pas de --backup-dir, pas
# de -A/-X) — backup-engine.sh a TOUJOURS nécessité le rsync moderne de
# Homebrew. Jusqu'ici cette dépendance n'était jamais vérifiée ni installée
# automatiquement : sur un Mac sans Homebrew, le premier garde-fou du moteur
# échouait silencieusement ("rsync introuvable"), sans qu'aucune installation
# automatique ne se déclenche. Ce script rend rsync livrable AVEC l'app.
#
# Usage : scripts/vendor-rsync.sh <dest-dir>
# Produit : <dest-dir>/bin/rsync + <dest-dir>/lib/*.dylib, tous ad-hoc signés,
# sans plus aucune référence à /opt/homebrew (vérifié en sortie).
#===============================================================================
set -euo pipefail

DEST="${1:?usage: vendor-rsync.sh <dest-dir>}"
SRC_RSYNC="$(brew --prefix rsync 2>/dev/null)/bin/rsync"
[ -x "$SRC_RSYNC" ] || { echo "vendor-rsync: rsync Homebrew introuvable sur cette machine (brew install rsync)" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST/bin" "$DEST/lib"
cp "$SRC_RSYNC" "$DEST/bin/rsync"

# --- ferme la liste des dylibs Homebrew nécessaires (transitivement) --------
# bash 3.2 (défaut macOS) n'a pas de tableaux associatifs -> dédoublonnage via
# une simple liste de noms séparés par des espaces, testée avec un `case`.
queue=("$DEST/bin/rsync")
seen_names=""
lib_count=0

while [ "${#queue[@]}" -gt 0 ]; do
  cur="${queue[0]}"; queue=("${queue[@]:1}")
  while IFS= read -r dep; do
    case "$dep" in
      /opt/homebrew/*|/usr/local/*)
        name="$(basename "$dep")"
        case " $seen_names " in
          *" $name "*) continue ;;
        esac
        seen_names="$seen_names $name"
        lib_count=$((lib_count + 1))
        cp "$dep" "$DEST/lib/$name"
        queue+=("$DEST/lib/$name")
        ;;
    esac
  done < <(otool -L "$cur" 2>/dev/null | tail -n +2 | awk '{print $1}')
done

# --- réécrit tous les chemins /opt/homebrew|/usr/local -> @executable_path/../lib ---
rewrite_deps() {
  local target="$1"
  while IFS= read -r dep; do
    case "$dep" in
      /opt/homebrew/*|/usr/local/*)
        name="$(basename "$dep")"
        install_name_tool -change "$dep" "@executable_path/../lib/$name" "$target"
        ;;
    esac
  done < <(otool -L "$target" 2>/dev/null | tail -n +2 | awk '{print $1}')
}

rewrite_deps "$DEST/bin/rsync"
for lib in "$DEST"/lib/*.dylib; do
  install_name_tool -id "@rpath/$(basename "$lib")" "$lib"
  rewrite_deps "$lib"
done

# --- re-signature (toute modification de load commands invalide la signature) ---
codesign --force --sign - "$DEST/bin/rsync"
for lib in "$DEST"/lib/*.dylib; do
  codesign --force --sign - "$lib"
done

# --- vérification : plus AUCUNE référence à /opt/homebrew ou /usr/local -----
if otool -L "$DEST/bin/rsync" "$DEST"/lib/*.dylib 2>/dev/null | grep -qE '/opt/homebrew|/usr/local'; then
  echo "vendor-rsync: ÉCHEC — des références Homebrew subsistent :" >&2
  otool -L "$DEST/bin/rsync" "$DEST"/lib/*.dylib 2>/dev/null | grep -E '/opt/homebrew|/usr/local' >&2
  exit 1
fi

echo "==> rsync vendored : $DEST/bin/rsync (+ $lib_count dylib(s) dans $DEST/lib/)"

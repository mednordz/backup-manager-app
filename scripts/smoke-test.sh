#!/bin/bash
#===============================================================================
# smoke-test.sh — vérifie un .app fraîchement construit avant publication.
#
# Pourquoi : chaque release (v0.2.4 -> v0.2.8) a exigé une inspection manuelle
# répétée du DMG publié (otool sur rsync, codesign --verify, identité bmengine,
# santé Flask) pour rattraper des régressions comme celle du Mac mini (rsync
# introuvable) ou une future fuite de _signing/.venv dans un DMG public. Ce
# script automatise ces contrôles pour que release.sh les fasse échouer AVANT
# publication plutôt qu'après un retour utilisateur.
#
# Usage : scripts/smoke-test.sh [chemin-vers-BackupManager.app]
#         (par défaut : dist/BackupManager.app)
#===============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-$PROJECT_DIR/dist/BackupManager.app}"
BACKEND="$APP_DIR/Contents/Resources/backup-manager-src"
BUNDLE_ID="com.mednor.backupmanager"
BMENGINE_SIGN_IDENTITY="Backup Manager Self-Signed"
FAILED=0

fail() { echo "  ÉCHEC — $1" >&2; FAILED=1; }
ok()   { echo "  ok — $1"; }

[ -d "$APP_DIR" ] || { echo "smoke-test: $APP_DIR introuvable (lancer make-dmg.sh d'abord)" >&2; exit 1; }

echo "==> [1/5] bundle & signature"
codesign --verify --deep --strict "$APP_DIR" 2>/dev/null \
  && ok "codesign --verify --deep --strict" \
  || fail "codesign --verify --deep --strict a échoué"

APP_CODESIGN_INFO="$(codesign -dvvv "$APP_DIR" 2>&1 || true)"
IDENTIFIER="$(echo "$APP_CODESIGN_INFO" | awk -F= '/^Identifier=/{print $2}')"
[ "$IDENTIFIER" = "$BUNDLE_ID" ] \
  && ok "identifiant de bundle stable ($BUNDLE_ID)" \
  || fail "identifiant de bundle inattendu : '$IDENTIFIER' (attendu $BUNDLE_ID)"

[ -d "$APP_DIR/Contents/Frameworks/Sparkle.framework" ] \
  && ok "Sparkle.framework embarqué" \
  || fail "Sparkle.framework manquant"

echo "==> [2/5] bmengine (identité TCC stable)"
BMENGINE="$BACKEND/bin/bmengine"
if [ -x "$BMENGINE" ]; then
  BMENGINE_CODESIGN_INFO="$(codesign -dvvv "$BMENGINE" 2>&1 || true)"
  AUTHORITY="$(echo "$BMENGINE_CODESIGN_INFO" | awk -F= '/^Authority=/{print $2}' | awk 'NR==1')"
  [ "$AUTHORITY" = "$BMENGINE_SIGN_IDENTITY" ] \
    && ok "signé avec '$BMENGINE_SIGN_IDENTITY'" \
    || fail "bmengine signé avec une identité inattendue : '$AUTHORITY'"
else
  fail "bmengine absent ou non exécutable ($BMENGINE)"
fi

echo "==> [3/5] rsync vendorisé (autonome, sans Homebrew)"
RSYNC="$BACKEND/bin/rsync"
if [ -x "$RSYNC" ]; then
  OTOOL_OUT="$(otool -L "$RSYNC" "$BACKEND"/lib/*.dylib 2>/dev/null || true)"
  if echo "$OTOOL_OUT" | grep -qE '/opt/homebrew|/usr/local'; then
    fail "référence Homebrew/local résiduelle détectée :"
    echo "$OTOOL_OUT" | grep -E '/opt/homebrew|/usr/local' >&2
  else
    ok "otool -L propre (aucune référence /opt/homebrew ou /usr/local)"
  fi
  "$RSYNC" --version >/dev/null 2>&1 \
    && ok "rsync --version s'exécute" \
    || fail "rsync --version a échoué"
  RSYNC_HELP="$("$RSYNC" --help 2>&1 || true)"
  echo "$RSYNC_HELP" | grep -q -- '--backup-dir' \
    && ok "rsync moderne confirmé (--backup-dir disponible, absent d'openrsync Apple)" \
    || fail "rsync ne supporte pas --backup-dir — build Apple openrsync au lieu du Homebrew vendorisé ?"

  SCRATCH="$(mktemp -d)"
  trap 'rm -rf "$SCRATCH" 2>/dev/null || true' EXIT
  mkdir -p "$SCRATCH/src" "$SCRATCH/dst" "$SCRATCH/bak"
  echo "smoke-test $$" > "$SCRATCH/src/probe.txt"
  if "$RSYNC" -aHAX --delete --backup --backup-dir="$SCRATCH/bak" "$SCRATCH/src/" "$SCRATCH/dst/" >/dev/null 2>&1 \
     && [ -f "$SCRATCH/dst/probe.txt" ]; then
    ok "transfert réel -aHAX --backup-dir réussi"
  else
    fail "transfert réel rsync a échoué (voir $SCRATCH)"
  fi
else
  fail "rsync absent ou non exécutable ($RSYNC)"
fi

echo "==> [4/5] pureté du backend embarqué"
for item in app.py backup-engine.sh progress-parse.py verify-parse.py requirements.txt static docs bin/bmengine bin/rsync THIRD-PARTY-NOTICES/rsync.txt; do
  [ -e "$BACKEND/$item" ] && ok "présent : $item" || fail "manquant : $item"
done
if [ -e "$BACKEND/_signing" ] || [ -e "$BACKEND/.venv" ]; then
  fail "FUITE : _signing/ ou .venv/ présent dans le backend embarqué (clé privée / venv ne doivent JAMAIS être distribués)"
else
  ok "aucune fuite de _signing/ ou .venv/"
fi

echo "==> [5/5] backend Flask (démarrage isolé, port + HOME dédiés)"
VENV_PYTHON="$HOME/backup-manager/.venv/bin/python"
if [ ! -x "$VENV_PYTHON" ]; then
  echo "  ignoré — pas de venv local ($VENV_PYTHON introuvable)"
else
  FLASK_SCRATCH="$(mktemp -d)"
  cp -R "$BACKEND"/. "$FLASK_SCRATCH/"
  ALT_PORT=8799
  ALT_HOME="$FLASK_SCRATCH/home"
  mkdir -p "$ALT_HOME"
  ( cd "$FLASK_SCRATCH" && HOME="$ALT_HOME" BACKUP_MANAGER_PORT="$ALT_PORT" "$VENV_PYTHON" app.py >"$FLASK_SCRATCH/flask.log" 2>&1 & echo $! > "$FLASK_SCRATCH/pid" )
  FLASK_PID="$(cat "$FLASK_SCRATCH/pid")"
  UP=0
  for _ in $(seq 1 20); do
    HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$ALT_PORT/api/jobs" 2>/dev/null || true)"
    if [ "$HTTP_CODE" = "200" ]; then
      UP=1
      break
    fi
    sleep 0.5
  done
  kill "$FLASK_PID" >/dev/null 2>&1 || true
  wait "$FLASK_PID" 2>/dev/null || true
  # macOS écrit parfois un cache python en tâche de fond (~/Library/Caches/com.apple.python)
  # après la fin du process -> rm -rf immédiat peut échouer sur "Directory not empty";
  # sans conséquence (dossier temporaire, nettoyé par macOS de toute façon), non bloquant.
  rm -rf "$FLASK_SCRATCH" 2>/dev/null || true
  [ "$UP" = "1" ] \
    && ok "backend Flask embarqué répond 200 sur /api/jobs (HOME + port isolés)" \
    || fail "backend Flask embarqué n'a jamais répondu (voir log ci-dessus)"
fi

echo
if [ "$FAILED" = "0" ]; then
  echo "==> smoke-test : TOUT PASSE ($APP_DIR)"
  exit 0
else
  echo "==> smoke-test : ÉCHEC — voir ci-dessus" >&2
  exit 1
fi

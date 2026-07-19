#!/bin/bash
#===============================================================================
# uninstall.sh — désinstallation complète de Backup Manager.
#
# Arrête tous les backups en cours et toutes les tâches planifiées, sauvegarde
# vos configurations de job sur le Bureau, puis supprime l'app et tout son
# état système (préférences, journaux, cache, launchd).
#
# Ne touche JAMAIS aux fichiers déjà sauvegardés sur vos disques de
# destination (miroirs et corbeilles datées) : ce script n'a structurellement
# aucun moyen d'y accéder — il supprime les fichiers de CONFIGURATION des
# jobs (qui contiennent les chemins), jamais les données elles-mêmes sur les
# disques que ces chemins désignent.
#
# Lancé de deux façons possibles, avec le même comportement :
#   - double-clic sur "Désinstaller BackupManager.command" présent sur le DMG
#   - menu Aide → Désinstaller complètement… de l'app elle-même (qui copie ce
#     script vers un emplacement temporaire avant de se fermer, pour qu'il
#     continue de tourner une fois l'app quittée)
#===============================================================================
set -uo pipefail
# Pas de -e : une étape qui échoue (fichier déjà absent, process déjà mort…)
# ne doit jamais interrompre les étapes suivantes.

# Chemins surchargeables par variable d'environnement — comportement en
# production strictement identique (personne ne positionne ces variables
# normalement), mais permet de rejouer ce script contre un bac à sable
# jetable pour le tester sans jamais toucher à une vraie installation.
BUNDLE_ID="${BM_UNINSTALL_BUNDLE_ID:-com.mednor.backupmanager}"
APP_PATH="${BM_UNINSTALL_APP_PATH:-/Applications/BackupManager.app}"
BACKEND_DIR="${BM_UNINSTALL_BACKEND_DIR:-$HOME/backup-manager}"
CONFIG_DIR="${BM_UNINSTALL_CONFIG_DIR:-$HOME/.config/backup-manager}"
SAVE_DIR="$HOME/Desktop/BackupManager-config-sauvegarde-$(date +%Y%m%d-%H%M%S)"

echo "==================================================================="
echo " Désinstallation complète de Backup Manager"
echo "==================================================================="
echo
echo "Ce script va :"
echo "  1. Arrêter tous les backups en cours et toutes les tâches planifiées"
echo "  2. Sauvegarder vos configurations de job sur le Bureau (avant suppression)"
echo "  3. Supprimer l'app, ses préférences, journaux, cache et fichiers système"
echo
echo "Il NE TOUCHE JAMAIS à ce qui est déjà sauvegardé sur vos disques de"
echo "destination (miroirs et corbeilles) — seule la CONFIGURATION des jobs"
echo "est supprimée ici, pas les données elles-mêmes."
echo

# Cas du lancement depuis le menu Aide : l'app vient de se fermer juste avant
# ce script — on laisse quelques secondes pour que ce soit bien effectif
# avant de toucher à ses fichiers.
for _ in $(seq 1 20); do
  pgrep -x "BackupManager" >/dev/null 2>&1 || break
  sleep 0.5
done

read -r -p "Continuer la désinstallation ? Tapez SUPPRIMER pour confirmer : " confirm
if [ "$confirm" != "SUPPRIMER" ]; then
  echo "Annulé — rien n'a été supprimé."
  read -r -p "Appuyez sur Entrée pour fermer cette fenêtre..." _
  exit 0
fi

echo
echo "==> Arrêt des tâches planifiées"
shopt -s nullglob
for plist in "$HOME/Library/LaunchAgents/"com.mednor.backup.*.plist "$HOME/Library/LaunchAgents/"com.mednor.backupmanager.*.plist; do
  label="$(basename "$plist" .plist)"
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  rm -f "$plist"
  echo "   déchargé : $label"
done
shopt -u nullglob

echo "==> Arrêt des processus restants"
pkill -TERM -f "backup-engine.sh" >/dev/null 2>&1 || true
pkill -TERM -f "bin/bmengine" >/dev/null 2>&1 || true
# Filet de sécurité pour un éventuel serveur Flask déjà orphelin (constaté en
# usage réel : un process app.py peut survivre à une fermeture normale de
# l'app si elle a quitté avant ce correctif — voir FlaskSupervisor.stop()).
pkill -TERM -f "backup-manager/app.py" >/dev/null 2>&1 || true
sleep 1
pkill -KILL -f "backup-engine.sh" >/dev/null 2>&1 || true
pkill -KILL -f "backup-manager/app.py" >/dev/null 2>&1 || true
rm -f /tmp/backup-*.lock >/dev/null 2>&1 || true
rmdir /tmp/backup-*.lock >/dev/null 2>&1 || true

if [ -d "$CONFIG_DIR/jobs" ] || [ -f "$CONFIG_DIR/settings.json" ]; then
  echo "==> Sauvegarde de vos configurations de job avant suppression"
  mkdir -p "$SAVE_DIR"
  [ -d "$CONFIG_DIR/jobs" ] && cp -R "$CONFIG_DIR/jobs" "$SAVE_DIR/"
  [ -f "$CONFIG_DIR/settings.json" ] && cp "$CONFIG_DIR/settings.json" "$SAVE_DIR/"
  echo "   sauvegardé dans : $SAVE_DIR"
fi

echo "==> Suppression de la configuration ($CONFIG_DIR)"
rm -rf "$CONFIG_DIR"

if [ -d "$BACKEND_DIR/.git" ]; then
  echo "==> $BACKEND_DIR contient un dépôt git (machine de développement) — conservé, non supprimé."
else
  echo "==> Suppression du backend ($BACKEND_DIR)"
  rm -rf "$BACKEND_DIR"
fi

echo "==> Suppression des préférences"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"

echo "==> Suppression des journaux"
# "backupmanager-*.log" (sans tiret) : ancienne architecture pre-fusion (menubar/ui
# separes) -- constate reel le 19/07/2026 sur une installation qui datait d'avant
# cette fusion, jamais nettoye par le seul motif "backup-*.log" ci-dessous.
rm -f "$HOME/Library/Logs/"backup-*.log "$HOME/Library/Logs/"backup-*.launchd.log \
      "$HOME/Library/Logs/"backupmanager-*.log >/dev/null 2>&1 || true
rm -f /tmp/backup-manager.out >/dev/null 2>&1 || true

echo "==> Suppression du cache"
rm -rf "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/Caches/BackupManagerApp"

# Donnees propres a la WebView (cache/cookies/stockage local du panneau,
# ~/Library/Caches ci-dessus ne les couvre PAS -- constate reel le 19/07/2026 :
# un ancien logo restait affiche dans le panneau apres une desinstallation
# "complete" + reinstallation, a cause de ce cache WebKit jamais purge, meme
# si le fichier servi par Flask etait deja le bon).
rm -rf "$HOME/Library/WebKit/$BUNDLE_ID" "$HOME/Library/WebKit/BackupManagerApp"
rm -rf "$HOME/Library/HTTPStorages/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies"

echo "==> Suppression des rapports de plantage"
rm -f "$HOME/Library/Application Support/CrashReporter/BackupManager_"*.plist \
      "$HOME/Library/Application Support/CrashReporter/BackupManagerApp_"*.plist >/dev/null 2>&1 || true

echo "==> Suppression de l'application"
if [ -d "$APP_PATH" ]; then
  rm -rf "$APP_PATH"
else
  echo "   $APP_PATH introuvable (déjà déplacée ou supprimée ?)"
fi

echo "==> Retrait de l'icône du Dock (si épinglée manuellement)"
python3 - <<'PYEOF' >/dev/null 2>&1 || true
import plistlib, os
path = os.path.expanduser("~/Library/Preferences/com.apple.dock.plist")
try:
    with open(path, "rb") as f:
        data = plistlib.load(f)
except FileNotFoundError:
    raise SystemExit
apps = data.get("persistent-apps", [])
kept = [e for e in apps if "BackupManager.app" not in e.get("tile-data", {}).get("file-data", {}).get("_CFURLString", "")]
if len(kept) != len(apps):
    data["persistent-apps"] = kept
    with open(path, "wb") as f:
        plistlib.dump(data, f)
PYEOF
killall Dock >/dev/null 2>&1 || true

echo
echo "==================================================================="
echo " Terminé."
echo "==================================================================="
echo
echo "Deux choses que ce script ne peut pas faire automatiquement :"
echo
echo "  - Si « Ouvrir au démarrage » était activé, Backup Manager peut rester"
echo "    listé (grisé, inactif) dans Réglages Système -> Général -> Éléments"
echo "    de connexion. Retirez-le manuellement là-bas si besoin."
echo
echo "  - Les autorisations Accès complet au disque et Automatisation restent"
echo "    visibles dans Réglages Système -> Confidentialité et sécurité."
echo "    macOS ne permet pas de les retirer par script — elles ne servent"
echo "    plus à rien une fois l'app supprimée, vous pouvez les retirer"
echo "    manuellement si vous le souhaitez."
echo
if [ -d "$SAVE_DIR" ]; then
  echo "Vos configurations de job ont été sauvegardées avant suppression ici :"
  echo "  $SAVE_DIR"
  echo
fi
echo "Vos fichiers déjà sauvegardés (miroirs et corbeilles sur vos disques de"
echo "destination) n'ont pas été touchés."
echo
read -r -p "Appuyez sur Entrée pour fermer cette fenêtre..." _

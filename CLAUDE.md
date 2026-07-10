# Backup Manager — coquille native (backup-manager-app)

Coquille macOS native (Swift/AppKit, sans Xcode.app — juste Command Line Tools + SPM) qui embarque et distribue le backend Flask. Dépôt **public** sur GitHub (nécessaire pour Sparkle : les mises à jour se téléchargent depuis les releases GitHub). Lire `README.md` en entier avant tout changement non trivial.

## Deux dépôts, un seul projet

- **`backup-manager-app`** (ce dépôt) — l'app Swift/AppKit : menu bar + Dock, `WKWebView` chargeant `127.0.0.1:8787`, `FlaskSupervisor` qui lance/supervise le backend, `bmengine` (lanceur signé pour une identité TCC stable), Sparkle pour les mises à jour auto.
- **[`backup-manager`](https://github.com/mednordz/backup-manager)** (privé) — le backend Flask + `backup-engine.sh` réels. `scripts/build-app.sh` les copie (liste blanche explicite, jamais un `cp -R` aveugle) dans `Contents/Resources/backup-manager-src/` à la compilation. `FlaskSupervisor.bootstrapBackendIfNeeded()` les synchronise vers `~/backup-manager` sur la machine cible **à chaque lancement**, sauf si `~/backup-manager` contient un `.git` (protège une machine de développement pour ne jamais écraser du travail en cours).

**Modifier `backup-engine.sh` se fait dans le dépôt `backup-manager`, pas ici.** Une modification là-bas n'atteint les machines déjà installées qu'après une nouvelle release de CE dépôt (`scripts/release.sh`).

## Contrainte du projet, à ne jamais oublier

**Pas de compte développeur Apple payant (99$/an).** L'app est signée ad-hoc (`codesign --sign -`), non notariée. Toute solution proposée doit fonctionner dans ce cadre — ça a déjà éliminé des pistes entières (ex. FSKit natif pour le support NTFS/EXT4 exige ce compte payant, voir historique de commits pour la recherche complète menée sur le sujet).

## Build & release

```
scripts/build-app.sh     # -> dist/BackupManager.app
scripts/make-dmg.sh      # -> dist/BackupManager-<version>.dmg
scripts/smoke-test.sh    # vérifie signature, rsync autonome, backend Flask (auto dans release.sh)
scripts/release.sh <version>   # build + smoke-test + tag + GitHub Release + appcast Sparkle
```

**Nécessite le certificat de signature "Backup Manager Self-Signed"** dans le trousseau login de la machine de build — sinon `build-app.sh` échoue explicitement (par design, plutôt que produire un `bmengine` non signé). Ce certificat vit dans `~/backup-manager/_signing/` (gitignore, jamais commité — ni ici ni là-bas, et le mot de passe n'est délibérément PAS répété dans ce fichier public). **Pour builder depuis une nouvelle machine**, transporter `_signing/backup-manager-signing.p12` hors Git (AirDrop, clé USB chiffrée, gestionnaire de mots de passe…), puis suivre exactement les instructions de `~/backup-manager/_signing/README.txt` (dépôt privé) — commande d'import + mot de passe + empreinte du certificat.

Sans ce certificat, on peut toujours éditer/lire le code Swift depuis une nouvelle machine (ou même via Claude Code sur le web, sans Mac du tout) — juste pas builder/publier une release réelle.

## Règle : tenir l'Aide (help.html) à jour

`Sources/BackupManagerApp/Resources/help.html` est le guide embarqué (menu Aide → Guide d'utilisation). Erreur déjà commise deux fois : relire ce fichier de mémoire et le déclarer "complet" sans avoir vérifié contre le vrai code de l'UI — des fonctionnalités entières (destination SSH distante, alertes iMessage, historique des runs) sont restées non documentées alors qu'elles existaient déjà dans `backup-manager/static/index.html`.

**Après toute modification d'interface** (nouveau bouton, champ, menu, comportement visible) — ici ou dans `backup-manager` — lancer `scripts/check-help-coverage.sh` et regarder si le nouvel élément apparaît dans le rapport. Ce n'est pas un gate automatique (le script tourne en informatif dans `release.sh`, il ne bloque jamais) : chaque libellé signalé ne mérite pas forcément une section, mais **ne jamais affirmer que l'Aide est complète sans avoir fait tourner ce script d'abord** — la relecture du guide seul ne suffit pas, c'est justement l'erreur qui s'est produite.

## Règle absolue : demander avant de publier

**Ne jamais lancer `scripts/release.sh` (donc publier un tag + release GitHub visible publiquement) sans confirmation explicite de l'utilisateur pour CETTE publication précise.** Une confirmation passée ne vaut pas pour la suivante.

## Repartir de zéro sur une nouvelle machine

1. `git clone` ce dépôt et `git clone` `backup-manager` (privé — accès GitHub authentifié requis).
2. Lire ce fichier, puis `README.md`.
3. `git log --oneline -30` dans les deux dépôts.
4. Si l'objectif est de builder/publier une vraie release : importer le certificat (voir ci-dessus). Sinon, éditer/discuter le code suffit sans lui.

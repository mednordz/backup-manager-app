<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Sources/BackupManagerApp/Resources/Brand/lockup-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="Sources/BackupManagerApp/Resources/Brand/lockup-light.png">
  <img alt="BackupManager" src="Sources/BackupManagerApp/Resources/Brand/lockup-dark.png" width="480">
</picture>

# BackupManager (native shell)

Coquille native macOS (Swift/AppKit) pour [backup-manager](https://github.com/mednordz/backup-manager) (privé) :
icône de menu bar, fenêtre `WKWebView` hébergeant le panneau existant, supervision
du process Flask, notifications natives, démarrage automatique, mise à jour
automatique (Sparkle).

Pas de Xcode.app requis — uniquement les Command Line Tools + Swift Package Manager.

**Reprendre ce projet depuis une nouvelle machine ?** Lire `CLAUDE.md` (ce dépôt), puis le
[`RESUME.md`](https://github.com/mednordz/backup-manager/blob/master/RESUME.md) du dépôt
`backup-manager` — il contient le prompt exact à donner à Claude Code.

## Build

```
scripts/build-app.sh     # -> dist/BackupManager.app
scripts/make-dmg.sh      # -> dist/BackupManager-<version>.dmg
scripts/smoke-test.sh    # vérifie un .app construit (signature, rsync autonome, backend Flask)
```

`smoke-test.sh` vérifie le bundle produit avant publication : signature ad-hoc valide, identité TCC stable de `bmengine`, `rsync` embarqué sans aucune référence Homebrew (+ un vrai transfert `-aHAX --backup-dir`), absence de fuite de `_signing/`/`.venv/` dans le backend embarqué, et démarrage réel du backend Flask embarqué (HOME + port isolés, sans toucher `~/backup-manager` ni `~/.config/backup-manager`). `release.sh` l'exécute automatiquement après `make-dmg.sh` et abandonne la publication s'il échoue.

`build-app.sh` embarque aussi le backend Flask complet (`~/backup-manager/{app.py,backup-engine.sh,progress-parse.py,verify-parse.py,requirements.txt,static,docs}` + `bmengine` fraîchement compilé et signé + `rsync` autonome relocalisé — voir `scripts/vendor-rsync.sh`, aucune dépendance à Homebrew requise sur la machine cible) dans `Contents/Resources/backup-manager-src/`. Sur un Mac où l'app n'a jamais tourné, `FlaskSupervisor.bootstrapBackendIfNeeded()` installe cette copie dans `~/backup-manager` — et la resynchronise à CHAQUE lancement (sauf si `~/backup-manager` est un dépôt git, ex. la machine de dev) pour que les correctifs backend atteignent aussi les machines déjà installées, pas seulement les nouvelles.

Requiert que le certificat auto-signé « Backup Manager Self-Signed » soit dans le trousseau login de la machine de build (voir `~/backup-manager/_signing/README.txt`) — `build-app.sh` échoue explicitement si absent plutôt que de produire un `bmengine` non signé.

## Release (Sparkle)

```
scripts/release.sh <version>
```

Construit le `.dmg`, signe la mise à jour (clé EdDSA dans le trousseau), génère
`appcast.xml`, et publie une GitHub Release avec les deux fichiers.

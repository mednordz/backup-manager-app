# BackupManager (native shell)

Coquille native macOS (Swift/AppKit) pour [backup-manager](https://github.com) :
icône de menu bar, fenêtre `WKWebView` hébergeant le panneau existant, supervision
du process Flask, notifications natives, démarrage automatique, mise à jour
automatique (Sparkle).

Pas de Xcode.app requis — uniquement les Command Line Tools + Swift Package Manager.

## Build

```
scripts/build-app.sh     # -> dist/BackupManager.app
scripts/make-dmg.sh      # -> dist/BackupManager-<version>.dmg
```

`build-app.sh` embarque aussi le backend Flask complet (`~/backup-manager/{app.py,backup-engine.sh,progress-parse.py,verify-parse.py,requirements.txt,static,docs}` + `bmengine` fraîchement compilé et signé) dans `Contents/Resources/backup-manager-src/`. Sur un Mac où l'app n'a jamais tourné, `FlaskSupervisor.bootstrapBackendIfNeeded()` installe cette copie dans `~/backup-manager` au premier lancement — sans ça, `python app.py` échoue immédiatement (fichier introuvable) et l'app reste bloquée sur « Démarrage du serveur… » indéfiniment (bug réel constaté sur un second Mac, corrigé en v0.2.4).

Requiert que le certificat auto-signé « Backup Manager Self-Signed » soit dans le trousseau login de la machine de build (voir `~/backup-manager/_signing/README.txt`) — `build-app.sh` échoue explicitement si absent plutôt que de produire un `bmengine` non signé.

## Release (Sparkle)

```
scripts/release.sh <version>
```

Construit le `.dmg`, signe la mise à jour (clé EdDSA dans le trousseau), génère
`appcast.xml`, et publie une GitHub Release avec les deux fichiers.

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

## Release (Sparkle)

```
scripts/release.sh <version>
```

Construit le `.dmg`, signe la mise à jour (clé EdDSA dans le trousseau), génère
`appcast.xml`, et publie une GitHub Release avec les deux fichiers.

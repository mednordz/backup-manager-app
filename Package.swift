// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BackupManagerApp",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "BackupManagerApp",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/BackupManagerApp",
            // help.html n'est pas une ressource SPM classique : build-app.sh le
            // copie lui-même dans Contents/Resources/ (même logique que l'icône
            // ou Sparkle.framework, assemblés à la main pour ce bundle .app).
            exclude: ["Resources/help.html", "Resources/help-images", "Resources/uninstall.sh"]
        ),
        // Petit lanceur signé du moteur : donne à bash+rsync une identité TCC
        // unique et stable (voir Sources/bmengine/main.swift).
        .executableTarget(
            name: "bmengine",
            path: "Sources/bmengine"
        )
    ]
)

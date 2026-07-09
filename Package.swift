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
            path: "Sources/BackupManagerApp"
        ),
        // Petit lanceur signé du moteur : donne à bash+rsync une identité TCC
        // unique et stable (voir Sources/bmengine/main.swift).
        .executableTarget(
            name: "bmengine",
            path: "Sources/bmengine"
        )
    ]
)

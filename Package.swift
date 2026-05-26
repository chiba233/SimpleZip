// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SimpleZipCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SimpleZipCore", targets: ["SimpleZipCore"])
    ],
    targets: [
        .target(
            name: "SimpleZipCore",
            path: "SimpleZip",
            exclude: [
                "App",
                "AppIcon.icns",
                "Assets.xcassets",
                "Features",
                "Tools",
                "de.lproj",
                "en.lproj",
                "es.lproj",
                "fr.lproj",
                "ja.lproj",
                "ko.lproj",
                "ru.lproj",
                "th.lproj",
                "zh-Hans.lproj",
                "zh-Hant.lproj"
            ],
            sources: [
                "Core/AppPreferences.swift",
                "Core/ArchiveError.swift",
                "Core/ArchiveModels.swift",
                "Core/ArchiveOperationOptions.swift",
                "Core/ArchiveSafety.swift",
                "Core/ArchiveService.swift",
                "Core/L10n.swift",
                "Core/TemporaryResourceManager.swift"
            ]
        ),
        .testTarget(
            name: "SimpleZipCoreTests",
            dependencies: ["SimpleZipCore"],
            path: "Tests/SimpleZipCoreTests"
        )
    ]
)

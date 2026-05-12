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
            sources: [
                "ArchiveError.swift",
                "ArchiveModels.swift",
                "ArchiveOperationOptions.swift",
                "ArchiveService.swift",
                "AppPreferences.swift",
                "L10n.swift"
            ]
        ),
        .testTarget(
            name: "SimpleZipCoreTests",
            dependencies: ["SimpleZipCore"],
            path: "Tests/SimpleZipCoreTests"
        )
    ]
)

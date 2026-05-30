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
                "Core/ArchiveOperationFeedback.swift",
                "Core/ArchiveModels.swift",
                "Core/ArchiveOperationOptions.swift",
                "Core/ArchiveSafety.swift",
                "Core/ArchiveService+Arguments.swift",
                "Core/ArchiveService+Parsing.swift",
                "Core/ArchiveService.swift",
                "Core/BackendProcessRunner.swift",
                "Core/Backends/ArchiveBackend.swift",
                "Core/Backends/DiskImageBackend.swift",
                "Core/Backends/GPGBackend.swift",
                "Core/Backends/NativeZipBackend.swift",
                "Core/Backends/RarBackend.swift",
                "Core/Backends/SevenZipBackend.swift",
                "Core/FinderFavoritesReader.swift",
                "Core/L10n.swift",
                "Core/OperationDiagnosticsReporter.swift",
                "Core/PreferencesPayloadCodec.swift",
                "Core/PresetPasswordStore.swift",
                "Core/SIZArchive.swift",
                "Core/SZSArchive.swift",
                "Core/TemporaryResourceManager.swift"
            ]
        ),
        .testTarget(
            name: "SimpleZipCoreTests",
            dependencies: ["SimpleZipCore"],
            path: "Tests/SimpleZipCoreTests",
            // Fixtures/ 下是预录的二进制压缩包 + 生成脚本 + README，
            // 通过 Bundle.module 给测试代码拿到 URL，避免依赖 swift test 当前工作目录。
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)

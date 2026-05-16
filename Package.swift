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
                "AboutPanel.swift",
                "AppDelegate.swift",
                "AppIcon.icns",
                "ArchiveAssociationService.swift",
                "ArchiveBrowserModel.swift",
                "ArchiveCreationOptionsView.swift",
                "ArchiveExtractionCoordinator.swift",
                "ArchiveTable.swift",
                "Assets.xcassets",
                "BenchmarkResultsView.swift",
                "ContentView.swift",
                "ExternalFileOpenQueue.swift",
                "ExtractArchiveOptionsView.swift",
                "ExtractOptionsForm.swift",
                "ExtractSelectionOptionsView.swift",
                "FileTable.swift",
                "HashModels.swift",
                "HashResultsView.swift",
                "HashService.swift",
                "SettingsView.swift",
                "Sidebar.swift",
                "SimpleZipApp.swift",
                "StatusBar.swift",
                "TableSupport.swift",
                "TopBar.swift",
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

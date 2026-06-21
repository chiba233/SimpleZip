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
            sources: ["Core"]   // 目录式:递归收录 Core/ 下全部 .swift(子文件夹随意分,无需逐条登记)
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

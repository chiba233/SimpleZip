import Foundation
import Testing
@testable import SimpleZipCore

/// #6 App bundle / DMG / XIP 专项发布检查 —— 纯函数部分(Info.plist 解析 / DMG 顶层结构 /
/// pkgutil 输出解析)。codesign/spctl 的真实调用不进 SwiftPM(依赖系统状态)。
struct BundleReleaseCheckTests {

    private func entry(_ path: String, isDirectory: Bool = false, symlink: String = "") -> ArchiveItem {
        ArchiveItem(name: path, isDirectory: isDirectory, size: 0, modified: nil,
                    sizeText: "", modifiedText: "", method: "", symlinkTarget: symlink)
    }

    // MARK: Info.plist

    @Test func appBundleInfoPlistChecks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleZip-BundleCheckTests-\(UUID().uuidString)/Demo.app")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let macOS = root.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "dev.example.demo",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "CFBundleExecutable": "Demo"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: root.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("Demo")
        FileManager.default.createFile(atPath: executable.path, contents: Data("x".utf8),
                                       attributes: [.posixPermissions: 0o755])

        let findings = BundleReleaseCheck.infoPlistFindings(at: root)
        let keys = findings.map(\.titleKey)
        #expect(keys.contains("inspect.bundle.infoPlist.ok"))
        #expect(findings.first { $0.titleKey == "inspect.bundle.identifier" }?.titleArgument == "dev.example.demo")
        #expect(findings.first { $0.titleKey == "inspect.bundle.version" }?.titleArgument == "1.2.3 (42)")
        #expect(findings.first { $0.titleKey == "inspect.bundle.executable.ok" }?.titleArgument == "Demo")
        #expect(findings.allSatisfy { $0.severity == .pass })

        // 删掉可执行 → executable.missing(failure)。
        try FileManager.default.removeItem(at: executable)
        let broken = BundleReleaseCheck.infoPlistFindings(at: root)
        #expect(broken.contains { $0.titleKey == "inspect.bundle.executable.missing" && $0.severity == .failure })
    }

    @Test func missingInfoPlistIsFailure() {
        let findings = BundleReleaseCheck.infoPlistFindings(
            at: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Fake.app"))
        #expect(findings.count == 1)
        #expect(findings[0].titleKey == "inspect.bundle.infoPlist.missing")
        #expect(findings[0].severity == .failure)
    }

    // MARK: DMG 顶层结构

    @Test func dmgLayoutHappyPath() {
        // 7zz 列 DMG:卷名作根。理想布局 = 一个 .app + Applications 链接。
        let findings = BundleReleaseCheck.diskImageLayoutFindings(items: [
            entry("MyApp 1.0", isDirectory: true),
            entry("MyApp 1.0/MyApp.app", isDirectory: true),
            entry("MyApp 1.0/MyApp.app/Contents/Info.plist"),
            entry("MyApp 1.0/Applications", symlink: "/Applications")
        ])
        #expect(findings.first { $0.titleKey == "inspect.bundle.dmg.singleApp" }?.titleArgument == "MyApp.app")
        #expect(findings.contains { $0.titleKey == "inspect.bundle.dmg.applicationsLink" && $0.severity == .pass })
        #expect(!findings.contains { $0.titleKey == "inspect.bundle.dmg.extraItems" })
    }

    @Test func dmgLayoutFlagsMissingLinkAndExtras() {
        let findings = BundleReleaseCheck.diskImageLayoutFindings(items: [
            entry("Vol", isDirectory: true),
            entry("Vol/MyApp.app", isDirectory: true),
            entry("Vol/MyApp.app/Contents/MacOS/MyApp"),
            entry("Vol/README.txt"),
            entry("Vol/.background", isDirectory: true),
            entry("Vol/.DS_Store")
        ])
        #expect(findings.contains { $0.titleKey == "inspect.bundle.dmg.applicationsLink.missing" && $0.severity == .warning })
        let extras = findings.first { $0.titleKey == "inspect.bundle.dmg.extraItems" }
        #expect(extras?.titleArgument == "1")
        #expect(extras?.detail == "README.txt")
    }

    @Test func dmgLayoutWithoutVolumeRootAndNoApp() {
        let findings = BundleReleaseCheck.diskImageLayoutFindings(items: [
            entry("README.txt"),
            entry("payload.bin")
        ])
        #expect(findings.contains { $0.titleKey == "inspect.bundle.dmg.noApp" })
    }

    // MARK: XIP 签名解析

    @Test func xipSignatureParsing() {
        let apple = BundleReleaseCheck.xipSignatureFinding(fromCheckSignatureOutput: """
        Package "Xcode.xip":
           Status: signed Apple Software
           Certificate Chain:
            1. Software Update
        """)
        #expect(apple.titleKey == "inspect.bundle.xip.apple")
        #expect(apple.severity == .pass)

        let thirdParty = BundleReleaseCheck.xipSignatureFinding(fromCheckSignatureOutput: """
           Status: signed by a developer certificate issued by Apple (Development)
        """)
        #expect(thirdParty.titleKey == "inspect.bundle.xip.thirdParty")
        #expect(thirdParty.severity == .warning)

        let unsigned = BundleReleaseCheck.xipSignatureFinding(fromCheckSignatureOutput: "   Status: no signature")
        #expect(unsigned.titleKey == "inspect.bundle.xip.unsigned")
    }

    // MARK: 目标探测

    @Test func targetDetection() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleZip-BundleTarget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("Thing.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let dmg = dir.appendingPathComponent("disk.dmg")
        FileManager.default.createFile(atPath: dmg.path, contents: Data())
        let xip = dir.appendingPathComponent("pack.xip")
        FileManager.default.createFile(atPath: xip.path, contents: Data())
        let zip = dir.appendingPathComponent("a.zip")
        FileManager.default.createFile(atPath: zip.path, contents: Data())

        #expect(BundleReleaseCheck.Target.detect(at: app) == .appBundle)
        #expect(BundleReleaseCheck.Target.detect(at: dmg) == .diskImage)
        #expect(BundleReleaseCheck.Target.detect(at: xip) == .xipArchive)
        #expect(BundleReleaseCheck.Target.detect(at: zip) == nil)
    }
}

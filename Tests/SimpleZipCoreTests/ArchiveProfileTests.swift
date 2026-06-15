//
//  ArchiveProfileTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:归档确定性画像 + 隐私红线(加密条目绝不进画像)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ArchiveProfileTests {
    private func item(_ name: String, dir: Bool = false, enc: Bool = false,
                      sym: String = "", attrs: String = "") -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: dir, size: 0, modified: nil,
                    sizeText: "", modifiedText: "", method: "", isEncrypted: enc,
                    attributes: attrs, symlinkTarget: sym)
    }

    @Test func detectsSourceArchiveSwiftProjectAndLocalization() {
        let items = [
            item("App/Package.swift"),
            item("App/README.md"),
            item("App/Sources/a.swift"),
            item("App/Sources/b.swift"),
            item("App/Sources/c.swift"),
            item("App/Sources/d.swift"),
            item("App/Sources/e.swift"),
            item("App/Resources/zh-Hans.lproj/Localizable.strings")
        ]
        let profile = ArchiveProfile.derive(from: items)
        #expect(profile.semanticTags.contains("source-archive"))
        #expect(profile.semanticTags.contains("swift-project"))
        #expect(profile.semanticTags.contains("localized-app"))
        #expect(profile.semanticTags.contains("documentation"))
        #expect(profile.markerFiles.contains("Package.swift"))
        #expect(profile.markerFiles.contains("README.md"))
        #expect(profile.dominantExtensions.first?.ext == "swift")
        #expect(profile.structure.topLevelShape == "single_root_folder")
        #expect(profile.structure.topLevelNames == ["App"])
    }

    @Test func detectsReleaseArtifact() {
        let items = [
            item("SHA256SUMS"),
            item("SimpleZip.dmg"),
            item("PUBLIC_KEY.asc")
        ]
        let profile = ArchiveProfile.derive(from: items)
        #expect(profile.semanticTags.contains("release-artifact"))
        #expect(profile.semanticTags.contains("signed-container-related"))
        #expect(profile.semanticTags.contains("installer"))
        #expect(profile.structure.topLevelShape == "scattered_files")
    }

    @Test func encryptedEntriesAreNeverProfiled() {
        let items = [
            item("README.md"),
            item("secret/private.pem", enc: true),
            item("vault/passwords.kdbx", enc: true)
        ]
        let profile = ArchiveProfile.derive(from: items)
        // 加密条目名 / 扩展名绝不出现在画像任何字段。
        let flat = (profile.markerFiles + profile.semanticTags + profile.dominantExtensions.map(\.ext)
                    + profile.structure.topLevelNames).joined(separator: " ")
        #expect(!flat.contains("private.pem"))
        #expect(!flat.contains("kdbx"))
        #expect(!flat.contains("pem"))
        #expect(!flat.contains("secret"))
        #expect(!flat.contains("vault"))
        // 但计数 + omission 保留。
        #expect(profile.structure.encryptedEntryCount == 2)
        #expect(profile.structure.entryCount == 1) // 只有 README.md 可见
        #expect(profile.omissions.contains { $0.type == "encrypted_entry_names" && $0.count == 2 })
    }

    @Test func riskHintsForBundleSymlinkExecutable() {
        let items = [
            item("Payload/Foo.app/Contents/MacOS/Foo", attrs: "-rwxr-xr-x"),
            item("Payload/link", sym: "../target")
        ]
        let profile = ArchiveProfile.derive(from: items)
        #expect(profile.riskHints.contains("contains-app-bundle"))
        #expect(profile.riskHints.contains("contains-symlink"))
        #expect(profile.riskHints.contains("contains-executable"))
        #expect(profile.semanticTags.contains("application-bundle"))
    }

    @Test func structureShapes() {
        // 多个散落顶层文件。
        let scattered = ArchiveProfile.derive(from: [item("a.txt"), item("b.txt"), item("c.txt")])
        #expect(scattered.structure.topLevelShape == "scattered_files")
        // 多根目录。
        let multi = ArchiveProfile.derive(from: [item("rootA/x.txt"), item("rootB/y.txt")])
        #expect(multi.structure.topLevelShape == "multi_root")
        // 空。
        #expect(ArchiveProfile.derive(from: []).structure.topLevelShape == "empty")
    }

    @Test func deterministicAcrossRuns() {
        let items = [item("App/Package.swift"), item("App/a.swift"), item("App/b.swift")]
        #expect(ArchiveProfile.derive(from: items) == ArchiveProfile.derive(from: items))
    }
}

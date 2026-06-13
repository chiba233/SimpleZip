//
//  ReleaseDirectoryAuditTests.swift
//  SimpleZipCoreTests
//
//  0.4.4 #11:发布目录检查纯逻辑 —— 清点分类 / 校验覆盖 / 文档引用 / 孤儿。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ReleaseDirectoryAuditTests {
    private let isArchive: (String) -> Bool = { name in
        ["zip", "7z", "dmg"].contains((name as NSString).pathExtension.lowercased())
    }

    @Test func classifiesByReleaseRole() {
        let inventory = ReleaseDirectoryAudit.classify(
            names: ["MyApp.zip", "SHA256SUMS", "SHA256SUMS 2", "MyApp.szs", "PUBLIC_KEY.asc",
                    "VERIFY.md", "release-manifest.json", "README.txt", ".DS_Store"],
            isArchiveName: isArchive
        )
        #expect(inventory.artifacts == ["MyApp.zip"])
        #expect(inventory.checksumFiles == ["SHA256SUMS", "SHA256SUMS 2"])
        #expect(inventory.containers == ["MyApp.szs"])
        #expect(inventory.publicKeys == ["PUBLIC_KEY.asc"])
        #expect(inventory.verifyDocs == ["VERIFY.md"])
        #expect(inventory.manifests == ["release-manifest.json"])
        #expect(inventory.others == ["README.txt"])   // 隐藏文件不参与
    }

    @Test func checksumCoverageFindsUncoveredAndStale() {
        let coverage = ReleaseDirectoryAudit.checksumCoverage(
            entryNames: ["a.zip", "gone.zip"],
            artifacts: ["a.zip", "b.zip"]
        )
        #expect(coverage.uncovered == ["b.zip"])
        #expect(coverage.stale == ["gone.zip"])
    }

    @Test func documentReferencesDetectMissingFiles() {
        let doc = """
        # Verifying MyApp.zip
        gpg --import PUBLIC_KEY.asc
        shasum -a 256 -c SHA256SUMS
        Renamed old artifact: OldApp-1.0.dmg
        Visit example.com for details. Version 1.2.3 ships today.
        """
        let missing = ReleaseDirectoryAudit.missingDocumentReferences(
            documentText: doc,
            directoryNames: ["MyApp.zip", "PUBLIC_KEY.asc", "SHA256SUMS"]
        )
        // SHA256SUMS 无扩展名不被当 token;域名 / 版本号被过滤;只有真正缺的 dmg 上榜。
        #expect(missing == ["OldApp-1.0.dmg"])
    }

    @Test func orphansAreJustTheOthers() {
        var inventory = ReleaseDirectoryAudit.Inventory()
        inventory.others = ["notes.txt"]
        #expect(ReleaseDirectoryAudit.orphans(in: inventory) == ["notes.txt"])
    }
}

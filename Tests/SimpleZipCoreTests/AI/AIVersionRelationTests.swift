//
//  AIVersionRelationTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 版本关系确定性分类(白皮书 Feat 16)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIVersionRelationTests {
    private func item(_ id: String, _ tokens: [String], role: AIArchiveRole? = nil,
                      hash: String? = nil, size: Int64? = nil) -> AIVersionRelationItem {
        AIVersionRelationItem(id: id, nameTokens: tokens, role: role?.rawValue, hashGroup: hash, byteSize: size)
    }

    @Test func sameHashIsSameContent() {
        let a = item("a", ["SimpleZip", "0.4.5"], hash: "h1", size: 100)
        let b = item("b", ["SimpleZip", "0.4.5", "copy"], hash: "h1", size: 100)
        #expect(AIVersionRelationClassifier.classify(a, b) == .sameContentDifferentName)
    }

    @Test func volumeSetDetected() {
        let a = item("a", ["release", "7z", "001"])
        let b = item("b", ["release", "7z", "002"])
        #expect(AIVersionRelationClassifier.classify(a, b) == .partialVolumeSet)
    }

    @Test func sourceVsBinary() {
        let src = item("a", ["SimpleZip", "source"], role: .sourcePackage)
        let bin = item("b", ["SimpleZip", "release"], role: .releasePackage)
        #expect(AIVersionRelationClassifier.classify(src, bin) == .sourceVsBinaryRelease)
    }

    @Test func newBuildOfSameRelease() {
        let a = item("a", ["SimpleZip", "0.4.4"], role: .releasePackage)
        let b = item("b", ["SimpleZip", "0.4.5"], role: .releasePackage)
        #expect(AIVersionRelationClassifier.classify(a, b) == .sameReleaseNewBuild)
    }

    @Test func localizedVariant() {
        let a = item("a", ["Manual", "zh"], role: .sourcePackage)
        let b = item("b", ["Manual", "en"], role: .sourcePackage)
        #expect(AIVersionRelationClassifier.classify(a, b) == .localizedVariant)
    }

    @Test func backupVsCurrent() {
        let a = item("a", ["project", "backup"])
        let b = item("b", ["project"])
        #expect(AIVersionRelationClassifier.classify(a, b) == .oldBackupVsCurrent)
    }

    @Test func unrelatedItems() {
        let a = item("a", ["minecraft", "mods"])
        let b = item("b", ["taxes", "2024"])
        #expect(AIVersionRelationClassifier.classify(a, b) == .unrelated)
    }

    @Test func tokenHelpers() {
        #expect(AIVersionRelationClassifier.isVolumeToken("001"))
        #expect(AIVersionRelationClassifier.isVolumeToken("part"))
        #expect(!AIVersionRelationClassifier.isVolumeToken("12"))
        #expect(AIVersionRelationClassifier.isVersionToken("0.4.5"))
        #expect(AIVersionRelationClassifier.isVersionToken("v1.2"))
        #expect(!AIVersionRelationClassifier.isVersionToken("release"))
    }

    @Test func symmetricAndCodable() throws {
        let a = item("a", ["SimpleZip", "source"], role: .sourcePackage)
        let b = item("b", ["SimpleZip", "release"], role: .releasePackage)
        // 关系对称(源码vs二进制两序一致)。
        #expect(AIVersionRelationClassifier.classify(a, b) == AIVersionRelationClassifier.classify(b, a))
        let data = try JSONEncoder().encode(a)
        #expect(try JSONDecoder().decode(AIVersionRelationItem.self, from: data) == a)
    }
}

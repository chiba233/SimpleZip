//
//  AIPresetRecommendationTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 预设推荐(白皮书 Feat 10)。确定性角色/扩展名→预设类别 + 安全 option 提示;
//  hints 永不含密码/加密(安全白名单);无匹配预设仍给 hints;Codable 往返。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIPresetRecommendationTests {
    @Test func sourceRoleRecommendsSourceArchive() {
        let r = AIPresetRecommender.recommend(role: AIArchiveRole.sourcePackage.rawValue)
        #expect(r.kind == .sourceArchive)
        #expect(r.optionHints.contains(AIPresetOptionHint("excludeJunk", .bool(true))))
        #expect(r.optionHints.contains(AIPresetOptionHint("testAfterCreate", .bool(true))))
    }

    @Test func releaseRoleAddsReproducible() {
        let r = AIPresetRecommender.recommend(role: AIArchiveRole.releasePackage.rawValue)
        #expect(r.kind == .releasePackage)
        #expect(r.optionHints.contains(AIPresetOptionHint("reproducible", .bool(true))))
    }

    @Test func mediaFlagRecommendsMediaStore() {
        let r = AIPresetRecommender.recommend(role: nil, hasMediaHeavyContent: true)
        #expect(r.kind == .mediaStore)
        #expect(r.optionHints.contains(AIPresetOptionHint("compressionLevel", .string("store"))))
    }

    @Test func backupRoleRecommendsBackup() {
        let r = AIPresetRecommender.recommend(role: AIArchiveRole.backupPackage.rawValue)
        #expect(r.kind == .backup)
        #expect(r.optionHints == [AIPresetOptionHint("testAfterCreate", .bool(true))])
    }

    @Test func infersSourceFromMarkersWhenNoRole() {
        let r = AIPresetRecommender.recommend(role: nil, markerFiles: ["Package.swift", "README.md"])
        #expect(r.kind == .sourceArchive)
    }

    @Test func infersMediaFromExtensions() {
        let r = AIPresetRecommender.recommend(role: nil, extensions: ["jpg", "mp4", "mov"])
        #expect(r.kind == .mediaStore)
    }

    @Test func mixedSourceAndMediaPrefersSource() {
        // 同时有源码与媒体扩展 → 偏源码(媒体单独成立才算媒体库)。
        let r = AIPresetRecommender.recommend(role: nil, extensions: ["swift", "png"])
        #expect(r.kind == .sourceArchive)
    }

    @Test func generalKindHasNoHintsAndNoPreset() {
        let r = AIPresetRecommender.recommend(role: nil, extensions: ["bin", "dat"])
        #expect(r.kind == .general)
        #expect(r.optionHints.isEmpty)
        #expect(r.presetID == nil)
    }

    @Test func matchesAvailablePresetByToken() {
        let r = AIPresetRecommender.recommend(
            role: AIArchiveRole.sourcePackage.rawValue,
            availablePresetIDs: ["My Release Build", "my-source-code", "Backups"])
        #expect(r.presetID == "my-source-code")
    }

    @Test func noMatchingPresetStillReturnsHints() {
        let r = AIPresetRecommender.recommend(
            role: AIArchiveRole.sourcePackage.rawValue, availablePresetIDs: ["unrelated-preset"])
        #expect(r.presetID == nil)
        #expect(!r.optionHints.isEmpty)
    }

    @Test func sanitizeRejectsSensitiveOptions() {
        // 防御:即使有人塞进加密/口令 hint,sanitize 也只保留安全白名单内的。
        let dirty = [
            AIPresetOptionHint("excludeJunk", .bool(true)),
            AIPresetOptionHint("password", .string("hunter2")),
            AIPresetOptionHint("encryptionMethod", .string("AES256")),
            AIPresetOptionHint("gpgRecipient", .string("a@b.c")),
        ]
        let clean = AIPresetRecommender.sanitize(dirty)
        #expect(clean == [AIPresetOptionHint("excludeJunk", .bool(true))])
        #expect(!clean.contains { $0.option == "password" })
        #expect(!clean.contains { $0.option == "encryptionMethod" })
    }

    @Test func recommendationOutputIsStable() {
        let a = AIPresetRecommender.recommend(role: AIArchiveRole.releasePackage.rawValue,
                                              markerFiles: ["Package.swift"], availablePresetIDs: ["release-x"])
        let b = AIPresetRecommender.recommend(role: AIArchiveRole.releasePackage.rawValue,
                                              markerFiles: ["Package.swift"], availablePresetIDs: ["release-x"])
        #expect(a == b)
    }

    @Test func codableRoundTrip() throws {
        let r = AIPresetRecommender.recommend(
            role: AIArchiveRole.mediaBundle.rawValue, availablePresetIDs: ["media-vault"])
        let decoded = try JSONDecoder().decode(AIPresetRecommendation.self, from: JSONEncoder().encode(r))
        #expect(decoded == r)
    }
}

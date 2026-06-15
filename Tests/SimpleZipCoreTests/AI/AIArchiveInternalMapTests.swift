//
//  AIArchiveInternalMapTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 归档内部地图确定性派生(白皮书 Feat 13)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIArchiveInternalMapTests {
    private func profile(tags: [String], markers: [String], exts: [(String, Int)],
                         encrypted: Int = 0) -> ArchiveProfile {
        ArchiveProfile(
            semanticTags: tags, markerFiles: markers,
            dominantExtensions: exts.map { .init(ext: $0.0, count: $0.1) },
            structure: .init(topLevelShape: "single_root_folder", topLevelNames: [],
                             entryCount: 100, fileCount: 90, directoryCount: 10, encryptedEntryCount: encrypted),
            riskHints: [], omissions: [])
    }

    @Test func sourcePackageMapsSourceSection() {
        let p = profile(tags: ["source-archive", "swift-project"], markers: ["Package.swift", "README.md"],
                        exts: [("swift", 420)])
        let map = AIArchiveMapBuilder.build(profile: p, samplePaths: ["Sources/App/Main.swift", "README.md"])
        let tokens = map.sections.map(\.titleToken)
        #expect(tokens.contains("source"))
        #expect(tokens.contains("documentation"))
        #expect(map.suggestedLens == AILens.source.rawValue)
    }

    @Test func localizationDetectedFromPaths() {
        let p = profile(tags: ["localized-app"], markers: [], exts: [("strings", 12)])
        let map = AIArchiveMapBuilder.build(profile: p, samplePaths: ["Resources/zh-Hans.lproj/Localizable.strings"])
        #expect(map.sections.map(\.titleToken).contains("localization"))
    }

    @Test func releaseMarkersSuggestReleaseLens() {
        let p = profile(tags: ["release-artifact"], markers: ["SHA256SUMS", "signature.asc"], exts: [("dmg", 1)])
        let map = AIArchiveMapBuilder.build(profile: p, samplePaths: ["SHA256SUMS", "SimpleZip.dmg"])
        #expect(map.sections.map(\.titleToken).contains("release-verification"))
        #expect(map.suggestedLens == AILens.release.rawValue)
    }

    @Test func encryptedEntriesProduceOmissionNotGuess() {
        let p = profile(tags: [], markers: [], exts: [("bin", 3)], encrypted: 7)
        let map = AIArchiveMapBuilder.build(profile: p, samplePaths: [])
        #expect(map.omissions.contains { $0.type == "encrypted_entry_names" && $0.count == 7 })
    }

    @Test func emptyProfileYieldsEmptyMap() {
        let p = profile(tags: [], markers: [], exts: [])
        let map = AIArchiveMapBuilder.build(profile: p, samplePaths: [])
        #expect(map.isEmpty)
        #expect(map.suggestedLens == nil)
    }

    @Test func deterministicAndCodable() throws {
        let p = profile(tags: ["source-archive"], markers: ["Package.swift"], exts: [("swift", 10)])
        let a = AIArchiveMapBuilder.build(profile: p, samplePaths: ["Sources/x.swift"])
        let b = AIArchiveMapBuilder.build(profile: p, samplePaths: ["Sources/x.swift"])
        #expect(a == b)
        let data = try JSONEncoder().encode(a)
        #expect(try JSONDecoder().decode(AIArchiveInternalMap.self, from: data) == a)
    }
}

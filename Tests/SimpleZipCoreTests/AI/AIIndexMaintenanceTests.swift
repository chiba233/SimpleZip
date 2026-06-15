//
//  AIIndexMaintenanceTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 索引维护员确定性判定(白皮书 Feat 21)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIIndexMaintenanceTests {
    @Test func everyActionTokenStable() {
        for a in AIIndexMaintenanceAction.allCases { #expect(!a.rawValue.isEmpty) }
    }

    @Test func healthyIndexHasNoFindings() {
        let facts = AIIndexMaintenanceFacts(archiveCacheCount: 100, staleArchiveCacheCount: 0,
                                            spotlightArchiveCount: 100, lastBackgroundRunSecondsAgo: 600)
        #expect(AIIndexMaintenanceAnalyzer.analyze(facts).isEmpty)
    }

    @Test func staleCacheSuggestsPrune() {
        let facts = AIIndexMaintenanceFacts(archiveCacheCount: 120, staleArchiveCacheCount: 18,
                                            spotlightArchiveCount: 120, lastBackgroundRunSecondsAgo: 60)
        let f = AIIndexMaintenanceAnalyzer.analyze(facts)
        #expect(f.contains { $0.code == "stale-cache" && $0.action == .pruneStaleCache })
    }

    @Test func spotlightDriftSuggestsReindex() {
        let facts = AIIndexMaintenanceFacts(archiveCacheCount: 100, staleArchiveCacheCount: 0,
                                            spotlightArchiveCount: 80, lastBackgroundRunSecondsAgo: 60)
        let f = AIIndexMaintenanceAnalyzer.analyze(facts)
        #expect(f.contains { $0.code == "spotlight-drift" && $0.action == .reindexSpotlight })
    }

    @Test func smallDriftIsToleratedBelowThreshold() {
        let facts = AIIndexMaintenanceFacts(archiveCacheCount: 100, staleArchiveCacheCount: 0,
                                            spotlightArchiveCount: 98, lastBackgroundRunSecondsAgo: 60)
        #expect(!AIIndexMaintenanceAnalyzer.analyze(facts).contains { $0.code == "spotlight-drift" })
    }

    @Test func spotlightDisabledSuppressesDrift() {
        let facts = AIIndexMaintenanceFacts(spotlightIndexingEnabled: false, archiveCacheCount: 100,
                                            spotlightArchiveCount: 0, lastBackgroundRunSecondsAgo: 60)
        #expect(!AIIndexMaintenanceAnalyzer.analyze(facts).contains { $0.code == "spotlight-drift" })
    }

    @Test func neverRanSuggestsFirstRunOnlyWhenCacheEnabled() {
        let enabled = AIIndexMaintenanceFacts(archiveListingCacheEnabled: true, archiveCacheCount: 0,
                                              spotlightArchiveCount: 0, lastBackgroundRunSecondsAgo: nil)
        #expect(AIIndexMaintenanceAnalyzer.analyze(enabled).contains { $0.code == "never-ran" })
        let disabled = AIIndexMaintenanceFacts(archiveListingCacheEnabled: false, lastBackgroundRunSecondsAgo: nil)
        #expect(!AIIndexMaintenanceAnalyzer.analyze(disabled).contains { $0.code == "never-ran" })
    }

    @Test func deterministicAndCodable() throws {
        let facts = AIIndexMaintenanceFacts(archiveCacheCount: 100, staleArchiveCacheCount: 5,
                                            spotlightArchiveCount: 80, lastBackgroundRunSecondsAgo: 60)
        let a = AIIndexMaintenanceAnalyzer.analyze(facts)
        #expect(a == AIIndexMaintenanceAnalyzer.analyze(facts))
        let data = try JSONEncoder().encode(facts)
        #expect(try JSONDecoder().decode(AIIndexMaintenanceFacts.self, from: data) == facts)
    }
}

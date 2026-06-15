//
//  AISchemaMigrationTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 持久化 Schema 迁移决策(工程补充十三)。
//

import Foundation
import Testing
@testable import SimpleZipCore

private struct DummyVersioned: AISchemaVersioned, Equatable {
    static var currentSchemaVersion: Int { 3 }
    let schemaVersion: Int
    let title: String
}

@Suite struct AISchemaMigrationTests {
    @Test func sameVersionUsesAsIs() {
        #expect(AISchemaMigrator.decide(storedVersion: 3, currentVersion: 3, isDerivedCache: true) == .useAsIs)
        #expect(AISchemaMigrator.decide(storedVersion: 3, currentVersion: 3, isDerivedCache: false) == .useAsIs)
    }

    @Test func olderDerivedCacheRebuilds() {
        #expect(AISchemaMigrator.decide(storedVersion: 1, currentVersion: 3, isDerivedCache: true) == .discardAndRebuild)
    }

    @Test func olderUserDataPreservesShell() {
        #expect(AISchemaMigrator.decide(storedVersion: 1, currentVersion: 3, isDerivedCache: false) == .preserveUserShell)
    }

    @Test func newerVersionAlsoHandledByCategory() {
        // 降级打开读到更新版本:派生丢弃重建,用户数据保壳。
        #expect(AISchemaMigrator.decide(storedVersion: 9, currentVersion: 3, isDerivedCache: true) == .discardAndRebuild)
        #expect(AISchemaMigrator.decide(storedVersion: 9, currentVersion: 3, isDerivedCache: false) == .preserveUserShell)
    }

    @Test func decideForVersionedValue() {
        let old = DummyVersioned(schemaVersion: 1, title: "My Workspace")
        #expect(AISchemaMigrator.decide(for: old, isDerivedCache: false) == .preserveUserShell)
        let current = DummyVersioned(schemaVersion: 3, title: "x")
        #expect(AISchemaMigrator.decide(for: current, isDerivedCache: true) == .useAsIs)
    }

    @Test func everyDecisionTokenStable() {
        let all: [AISchemaMigrationDecision] = [.useAsIs, .discardAndRebuild, .preserveUserShell]
        for d in all { #expect(!d.rawValue.isEmpty) }
    }

    @Test func resultTypeCarriesValues() {
        let r = AISchemaMigrationResult.migrated(DummyVersioned(schemaVersion: 3, title: "t"))
        if case let .migrated(v) = r { #expect(v.title == "t") } else { Issue.record("wrong case") }
    }
}

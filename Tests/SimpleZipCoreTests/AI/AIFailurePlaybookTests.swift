//
//  AIFailurePlaybookTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:失败修复手册 —— 标签优先级 + 固定流程(白皮书 Feat 4)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIFailurePlaybookTests {
    @Test func everyTagHasNonEmptyPlaybook() {
        for tag in AIDiagnosticTag.allCases {
            let pb = AIFailurePlaybookLibrary.playbook(for: tag)
            #expect(pb.tag == tag)
            #expect(!pb.headlineKey.isEmpty)
            #expect(!pb.stepKeys.isEmpty)
            #expect(!pb.suggestedAction.isEmpty)
        }
    }

    @Test func priorityListCoversAllTags() {
        #expect(Set(AIFailurePlaybookLibrary.priority) == Set(AIDiagnosticTag.allCases))
    }

    @Test func picksHighestPriorityTagWhenSeveralPresent() {
        // needsPassword 优先于 destinationConflict。
        let pb = AIFailurePlaybookLibrary.playbook(for: [.destinationConflict, .needsPassword])
        #expect(pb?.tag == .needsPassword)
    }

    @Test func missingVolumeBeatsPermission() {
        let pb = AIFailurePlaybookLibrary.playbook(for: [.permissionDenied, .missingVolume])
        #expect(pb?.tag == .missingVolume)
        #expect(pb?.suggestedAction == "locate-missing-volume")
    }

    @Test func emptyTagsYieldNoPlaybook() {
        #expect(AIFailurePlaybookLibrary.playbook(for: []) == nil)
    }

    @Test func integratesWithClassifier() {
        // 端到端:从真实失败文本分类出标签,再取手册。
        let tags = AIDiagnosticsClassifier.classify(
            message: "Extraction failed",
            errorLines: ["ERROR: Missing volume : release.7z.002"])
        let pb = AIFailurePlaybookLibrary.playbook(for: tags)
        #expect(pb?.tag == .missingVolume)
    }

    @Test func playbookRoundTripsThroughCodable() throws {
        let pb = AIFailurePlaybookLibrary.playbook(for: .checksumMismatch)
        let data = try JSONEncoder().encode(pb)
        #expect(try JSONDecoder().decode(AIFailurePlaybook.self, from: data) == pb)
    }
}

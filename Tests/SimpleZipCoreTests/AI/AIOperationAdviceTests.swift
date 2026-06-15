//
//  AIOperationAdviceTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:创建/解压 Operation Advice Cards 确定性规则引擎(白皮书「Operation Advice Cards」)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIOperationAdviceTests {

    // MARK: - 创建

    @Test func createNoSignalsYieldsNoCards() {
        let f = AICreateAdviceFacts(inputFileCount: 10, totalBytes: 1000, format: "zip",
                                    destinationLocationKind: "downloads")
        #expect(AIOperationAdviceRuleEngine.createCards(from: f).isEmpty)
    }

    @Test func createOutputExistsSuggestsRename() {
        let f = AICreateAdviceFacts(inputFileCount: 10, totalBytes: 1000, outputExists: true,
                                    format: "zip", destinationLocationKind: "downloads")
        let cards = AIOperationAdviceRuleEngine.createCards(from: f)
        #expect(cards.contains { $0.id == "rename-output" && $0.primaryActionID == "renameOutput" })
    }

    @Test func createFlagsSymlinkPackageVolumesExcludes() {
        let f = AICreateAdviceFacts(
            inputFileCount: 100, totalBytes: 9_000_000, excludedCount: 4, symlinkCount: 2,
            packageCount: 1, estimatedVolumeCount: 3, format: "7z", destinationLocationKind: "desktop")
        let ids = Set(AIOperationAdviceRuleEngine.createCards(from: f).map(\.id))
        #expect(ids.isSuperset(of: ["warn-symlinks", "warn-package", "warn-volumes", "review-excludes"]))
    }

    @Test func createSingleVolumeNotFlagged() {
        let f = AICreateAdviceFacts(inputFileCount: 5, totalBytes: 100, estimatedVolumeCount: 1,
                                    format: "zip", destinationLocationKind: "downloads")
        #expect(!AIOperationAdviceRuleEngine.createCards(from: f).contains { $0.id == "warn-volumes" })
    }

    // MARK: - 解压

    @Test func extractSuspiciousPathOpensSecurityReportAsWarning() {
        let f = AIExtractAdviceFacts(fileCount: 100, totalBytes: 5000, suspiciousEntryCount: 1,
                                     destinationLocationKind: "downloads")
        let cards = AIOperationAdviceRuleEngine.extractCards(from: f)
        let sec = cards.first { $0.id == "review-security" }
        #expect(sec?.severity == .warning)
        #expect(sec?.primaryActionID == "openSecurityReport")
    }

    @Test func extractSymlinkSuggestsSkipOnlyWhenNotAlreadySkipping() {
        let on = AIExtractAdviceFacts(fileCount: 10, totalBytes: 100, symlinkCount: 3,
                                      skipSymlinks: false, destinationLocationKind: "downloads")
        #expect(AIOperationAdviceRuleEngine.extractCards(from: on).contains { $0.id == "skip-symlinks" })
        let off = AIExtractAdviceFacts(fileCount: 10, totalBytes: 100, symlinkCount: 3,
                                       skipSymlinks: true, destinationLocationKind: "downloads")
        #expect(!AIOperationAdviceRuleEngine.extractCards(from: off).contains { $0.id == "skip-symlinks" })
    }

    @Test func extractOverwriteSuggestsAutoRename() {
        let f = AIExtractAdviceFacts(fileCount: 10, totalBytes: 100, overwriteCount: 5,
                                     autoRenameConflicts: false, destinationLocationKind: "downloads")
        let card = AIOperationAdviceRuleEngine.extractCards(from: f).first { $0.id == "auto-rename" }
        #expect(card?.optionPatchIDs == ["enableAutoRenameConflicts"])
    }

    @Test func extractSingleRootSuggestsStrip() {
        let f = AIExtractAdviceFacts(fileCount: 10, totalBytes: 100,
                                     detectedSingleRootFolder: "SimpleZip-main",
                                     stripSingleRootFolder: false, destinationLocationKind: "downloads")
        #expect(AIOperationAdviceRuleEngine.extractCards(from: f).contains { $0.id == "strip-root" })
    }

    @Test func extractWarningsSortBeforeSuggestions() {
        // 同时有 suspicious(warning) 和 single-root(suggestion):warning 排前。
        let f = AIExtractAdviceFacts(fileCount: 10, totalBytes: 100, suspiciousEntryCount: 1,
                                     detectedSingleRootFolder: "root", destinationLocationKind: "downloads")
        let cards = AIOperationAdviceRuleEngine.extractCards(from: f)
        #expect(cards.first?.severity == .warning)
        #expect(cards.first?.id == "review-security")
    }

    // MARK: - 模型输出校验

    @Test func sanitizeStripsInventedActionsAndPatches() {
        let plan = AIOperationAdvicePlan(scope: .extract, cards: [
            AIOperationAdviceCard(id: "c1", severity: .warning, title: "Polished",
                                  primaryActionID: "deleteEverything",        // 非法,应置 nil
                                  optionPatchIDs: ["enableSkipSymlinks", "rmRF"]), // rmRF 非法应剔除
        ])
        let sanitized = AIOperationAdviceRuleEngine.sanitize(plan)
        let card = sanitized.cards[0]
        #expect(card.primaryActionID == nil)
        #expect(card.optionPatchIDs == ["enableSkipSymlinks"])
        #expect(card.title == "Polished") // 模型润色文案保留
    }

    @Test func allowedActionsAreScoped() {
        #expect(AIOperationAdviceRuleEngine.allowedActions(scope: .create).contains("renameOutput"))
        #expect(!AIOperationAdviceRuleEngine.allowedActions(scope: .create).contains("openSecurityReport"))
        #expect(AIOperationAdviceRuleEngine.allowedActions(scope: .extract).contains("openSecurityReport"))
        #expect(!AIOperationAdviceRuleEngine.allowedActions(scope: .extract).contains("renameOutput"))
    }

    @Test func planCodableRoundTrip() throws {
        let plan = AIOperationAdviceRuleEngine.extractPlan(from:
            AIExtractAdviceFacts(fileCount: 10, totalBytes: 100, suspiciousEntryCount: 2,
                                 destinationLocationKind: "downloads"))
        let decoded = try JSONDecoder().decode(AIOperationAdvicePlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded == plan)
    }
}

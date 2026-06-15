//
//  AITaskPlanTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 任务规划 + 批处理规划器(白皮书 Feat 22 / 建议二十二)。动作走 catalog;itemID 校验真实存在;
//  requiresUserReview 恒 true(模型不能绕过确认);空组丢弃。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AITaskPlanTests {
    @Test func requiresUserReviewAlwaysTrue() {
        #expect(AITaskPlan(steps: []).requiresUserReview)
        #expect(AIBatchPlan(groups: []).requiresUserReview)
    }

    @Test func requiresUserReviewIgnoresModelJSON() throws {
        // 模型试图传 requiresUserReview:false 绕过确认 —— 必须被忽略(恒 true)。
        let json = Data(#"{"steps":[],"warnings":[],"requiresUserReview":false}"#.utf8)
        let plan = try JSONDecoder().decode(AITaskPlan.self, from: json)
        #expect(plan.requiresUserReview)
    }

    @Test func sanitizeFiltersInventedStepActions() {
        let dirty = AITaskPlan(steps: [
            AITaskPlanStep(actionID: "runTest"),
            AITaskPlanStep(actionID: "rm -rf /"),
            AITaskPlanStep(actionID: "runReleaseInspection"),
        ])
        let clean = AITaskPlanSanitizer.sanitize(dirty)
        #expect(clean.steps.map(\.actionID) == ["runTest", "runReleaseInspection"])
    }

    @Test func sanitizeNormalizesStepSelectionQuery() {
        let dirty = AITaskPlan(steps: [
            AITaskPlanStep(actionID: "selectByRole",
                           selectionQuery: AISelectionQuery(semanticTags: ["release-artifact", "made-up-tag"])),
        ])
        let clean = AITaskPlanSanitizer.sanitize(dirty)
        #expect(clean.steps.first?.selectionQuery?.semanticTags == ["release-artifact"])
    }

    @Test func sanitizeBatchFiltersInvalidItemIDs() {
        let dirty = AIBatchPlan(groups: [
            AIBatchGroup(itemIDs: ["file-1", "ghost-99"], recommendedActionIDs: ["runTest"]),
        ])
        let clean = AITaskPlanSanitizer.sanitizeBatch(dirty, validItemIDs: ["file-1", "file-2"])
        #expect(clean.groups.first?.itemIDs == ["file-1"])
    }

    @Test func sanitizeBatchFiltersInventedActions() {
        let dirty = AIBatchPlan(groups: [
            AIBatchGroup(itemIDs: ["file-1"], recommendedActionIDs: ["runTest", "deleteEverything"]),
        ])
        let clean = AITaskPlanSanitizer.sanitizeBatch(dirty, validItemIDs: ["file-1"])
        #expect(clean.groups.first?.recommendedActionIDs == ["runTest"])
    }

    @Test func sanitizeBatchDropsGroupsWithNoValidItems() {
        let dirty = AIBatchPlan(groups: [
            AIBatchGroup(titleSeed: "ghosts", itemIDs: ["ghost-1", "ghost-2"]),
            AIBatchGroup(titleSeed: "real", itemIDs: ["file-1"], recommendedActionIDs: ["open"]),
        ])
        let clean = AITaskPlanSanitizer.sanitizeBatch(dirty, validItemIDs: ["file-1"])
        #expect(clean.groups.count == 1)
        #expect(clean.groups.first?.titleSeed == "real")
    }

    @Test func codableRoundTripPlan() throws {
        let plan = AITaskPlan(steps: [
            AITaskPlanStep(actionID: "selectByRole", target: .selection,
                           selectionQuery: AISelectionQuery(semanticTags: ["release-artifact"]), note: "发布包"),
            AITaskPlanStep(actionID: "runTest", target: .selection),
        ], warnings: ["non-archive-skipped"])
        let decoded = try JSONDecoder().decode(AITaskPlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded == plan)
    }

    @Test func codableRoundTripBatch() throws {
        let plan = AIBatchPlan(groups: [
            AIBatchGroup(titleSeed: "release", itemIDs: ["file-1"],
                         recommendedActionIDs: ["runTest", "openReport"], reason: "目录含 release"),
        ], warnings: ["readme-not-archive"])
        let decoded = try JSONDecoder().decode(AIBatchPlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded == plan)
    }
}

//
//  AIBudgetTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 上下文预算 —— 候选截断 + 省略说明 + 样本 / 文本裁剪。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIBudgetTests {
    @Test func capUnderBudgetKeepsAllAndNoOmission() {
        let budget = AIBudget(maxItems: 5, maxTextChars: 100, maxSamplesPerGroup: 3)
        let (kept, omission) = budget.cap([1, 2, 3], type: "tasks")
        #expect(kept == [1, 2, 3])
        #expect(omission == nil)
    }

    @Test func capOverBudgetTruncatesAndReportsOmission() {
        let budget = AIBudget(maxItems: 2, maxTextChars: 100, maxSamplesPerGroup: 3)
        let (kept, omission) = budget.cap([1, 2, 3, 4, 5], type: "tasks")
        #expect(kept == [1, 2])
        #expect(omission?.type == "tasks")
        #expect(omission?.count == 3)
        #expect(omission?.policy == "budget")
    }

    @Test func sampleCapsToGroupBudget() {
        let budget = AIBudget(maxItems: 80, maxTextChars: 100, maxSamplesPerGroup: 2)
        #expect(budget.sample(["a", "b", "c", "d"]) == ["a", "b"])
    }

    @Test func clampTextTruncatesLongStrings() {
        let budget = AIBudget(maxItems: 1, maxTextChars: 5, maxSamplesPerGroup: 1)
        #expect(budget.clampText("hello") == "hello")
        #expect(budget.clampText("hello world") == "hello…")
    }

    @Test func clampTextCountsGraphemesNotBytes() {
        let budget = AIBudget(maxItems: 1, maxTextChars: 2, maxSamplesPerGroup: 1)
        #expect(budget.clampText("中文路径") == "中文…")
    }

    @Test func initClampsNonPositiveToOne() {
        let budget = AIBudget(maxItems: 0, maxTextChars: -5, maxSamplesPerGroup: 0)
        #expect(budget.maxItems == 1)
        #expect(budget.maxTextChars == 1)
        #expect(budget.maxSamplesPerGroup == 1)
    }

    @Test func presetsMatchRoadmapTable() {
        #expect(AIBudget.activityFilter.maxItems == 80)
        #expect(AIBudget.activityFilter.maxTextChars == 800)
        #expect(AIBudget.archiveMemory.maxSamplesPerGroup == 20)
        #expect(AIBudget.workspaceTheme.maxItems == 30)
        #expect(AIBudget.workspaceTree.maxItems == 80)
    }
}

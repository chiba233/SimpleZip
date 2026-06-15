//
//  AIDataLifecycleTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 数据保留 / 开关 / 清空策略(白皮书工程补充三)。保留表、关开关→omission、清空级联。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIDataLifecycleTests {
    @Test func promptFactsNeverPersist() {
        let p = AIDataLifecycle.retentionPolicy(for: .promptFacts)
        #expect(!p.persists)
    }

    @Test func contextDebugBounded() {
        let p = AIDataLifecycle.retentionPolicy(for: .contextDebug)
        #expect(p.persists)
        #expect(p.maxAgeDays == 1)
        #expect(p.maxCount == 20)
    }

    @Test func derivedIndexesFollowOtherCache() {
        for c in [AIDataCategory.activityIndex, .archiveMemory, .archiveProfile, .markerSummary] {
            #expect(AIDataLifecycle.retentionPolicy(for: c).followsOtherCache)
        }
    }

    @Test func feedbackAndHabitWindows() {
        #expect(AIDataLifecycle.retentionPolicy(for: .feedbackEvent).maxAgeDays == 30)
        #expect(AIDataLifecycle.retentionPolicy(for: .habitSummary).maxAgeDays == 90)
    }

    @Test func userWorkspaceKeptUntilDeleted() {
        let p = AIDataLifecycle.retentionPolicy(for: .userWorkspace)
        #expect(p.persists)
        #expect(p.maxAgeDays == nil)
        #expect(p.maxCount == nil)
    }

    @Test func everyCategoryHasPolicy() {
        // 全覆盖,无遗漏(switch 必须穷尽)。
        for c in AIDataCategory.allCases {
            _ = AIDataLifecycle.retentionPolicy(for: c)
        }
    }

    @Test func disabledSwitchMapsToOmissionWithReason() {
        let o = AIDataLifecycle.omission(forDisabled: .activityHistory)
        #expect(o.type == "activity_history")
        #expect(o.policy == "disabled_by_user")
    }

    @Test func everySwitchHasDistinctOmissionType() {
        let types = AIDataSwitch.allCases.map { AIDataLifecycle.omission(forDisabled: $0).type }
        #expect(Set(types).count == types.count) // 无重复
        #expect(types.allSatisfy { !$0.isEmpty })
    }

    @Test func clearArchiveCacheCascade() {
        let cleared = AIDataLifecycle.categoriesCleared(by: .archiveListingCache)
        #expect(cleared.contains(.archiveMemory))
        #expect(cleared.contains(.archiveProfile))
        #expect(!cleared.contains(.feedbackEvent)) // 学习数据不受归档缓存清空影响
    }

    @Test func clearLearningDataCascade() {
        let cleared = AIDataLifecycle.categoriesCleared(by: .learningData)
        #expect(cleared == [.habitSummary, .feedbackEvent, .recommendedTheme])
    }

    @Test func disableAIDoesNotClearDerivedCaches() {
        // 关总开关不清已有派生缓存(只是 UI 不展示)。
        #expect(AIDataLifecycle.categoriesCleared(by: .disableAI).isEmpty)
    }

    @Test func userWorkspaceClearDoesNotTouchArchiveCaches() {
        let cleared = AIDataLifecycle.categoriesCleared(by: .userWorkspace)
        #expect(cleared.contains(.userWorkspace))
        #expect(!cleared.contains(.archiveMemory))
        #expect(!cleared.contains(.archiveProfile))
    }

    @Test func codableRoundTrip() throws {
        let p = AIDataLifecycle.retentionPolicy(for: .workspaceTreeCache)
        let decoded = try JSONDecoder().decode(AIRetentionPolicy.self, from: JSONEncoder().encode(p))
        #expect(decoded == p)
    }
}

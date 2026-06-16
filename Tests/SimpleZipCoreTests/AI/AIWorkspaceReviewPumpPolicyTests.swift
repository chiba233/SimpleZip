//
//  AIWorkspaceReviewPumpPolicyTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80/#89:动态 AI 文件夹隐藏竞争池的复核泵策略。
//

import Testing
@testable import SimpleZipCore

@Suite struct AIWorkspaceReviewPumpPolicyTests {
    @Test func hiddenPoolTargetKeepsPushingPastTheVisibleMinimum() {
        let policy = AIWorkspaceReviewPumpPolicy(displayLimit: 4, hiddenCandidateCount: 18)
        #expect(policy.approvedTarget == 8)
    }

    @Test func smallPoolsStillTryToFillABasicVisibleSet() {
        #expect(AIWorkspaceReviewPumpPolicy(displayLimit: 4, hiddenCandidateCount: 3).approvedTarget == 2)
        #expect(AIWorkspaceReviewPumpPolicy(displayLimit: 4, hiddenCandidateCount: 1).approvedTarget == 1)
    }

    @Test func targetScalesWithConfiguredDisplayLimit() {
        #expect(AIWorkspaceReviewPumpPolicy(displayLimit: 1, hiddenCandidateCount: 18).approvedTarget == 2)
        #expect(AIWorkspaceReviewPumpPolicy(displayLimit: 8, hiddenCandidateCount: 18).approvedTarget == 9)
    }

    @Test func retryBudgetScalesWithConfiguredDisplayLimit() {
        #expect(AIWorkspaceReviewPumpPolicy(displayLimit: 1, hiddenCandidateCount: 18).maxAttemptsPerTheme == 2)
        #expect(AIWorkspaceReviewPumpPolicy(displayLimit: 4, hiddenCandidateCount: 18).maxAttemptsPerTheme == 5)
        #expect(AIWorkspaceReviewPumpPolicy(displayLimit: 8, hiddenCandidateCount: 18).maxAttemptsPerTheme == 5)
        #expect(AIWorkspaceReviewPumpPolicy(displayLimit: 8, hiddenCandidateCount: 18,
                                            activityLevel: .aggressive).maxAttemptsPerTheme == 6)
    }

    @Test func candidateLimitScalesWithDisplayLimitAndActivityLevel() {
        #expect(AIWorkspaceReviewPumpPolicy(displayLimit: 4, hiddenCandidateCount: 0,
                                            activityLevel: .powerSaver).candidateLimit == 4)
        #expect(AIWorkspaceReviewPumpPolicy(displayLimit: 4, hiddenCandidateCount: 0,
                                            activityLevel: .balanced).candidateLimit == 8)
        #expect(AIWorkspaceReviewPumpPolicy(displayLimit: 4, hiddenCandidateCount: 0,
                                            activityLevel: .aggressive).candidateLimit == 12)
    }

    @Test func reviewPumpGetsLazyAfterConfiguredWatermark() {
        let normal = AIWorkspaceReviewPumpPolicy(displayLimit: 8, hiddenCandidateCount: 18,
                                                 activityLevel: .balanced)
        #expect(normal.lazyWatermark == 3)
        #expect(!normal.isLazy(approvedCount: 2))
        #expect(normal.isLazy(approvedCount: 3))
        #expect(normal.reviewDelaySeconds(approvedCount: 2) == 0.35)
        #expect(normal.reviewDelaySeconds(approvedCount: 3) == 12)

        let max = AIWorkspaceReviewPumpPolicy(displayLimit: 8, hiddenCandidateCount: 18,
                                              activityLevel: .aggressive)
        #expect(max.lazyWatermark == 4)
        #expect(!max.isLazy(approvedCount: 3))
        #expect(max.isLazy(approvedCount: 4))
        #expect(max.reviewDelaySeconds(approvedCount: 4) == 6)
    }

    @Test func noHiddenCandidatesNeedNoReviews() {
        #expect(AIWorkspaceReviewPumpPolicy(displayLimit: 4, hiddenCandidateCount: 0).approvedTarget == 0)
    }
}

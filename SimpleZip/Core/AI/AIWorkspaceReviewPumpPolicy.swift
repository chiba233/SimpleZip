//
//  AIWorkspaceReviewPumpPolicy.swift
//  SimpleZip
//
//  0.4.5 #80/#89:动态 AI 文件夹隐藏竞争池的复核泵策略。
//

import Foundation

/// 隐藏候选池的复核目标。未复核候选不能上屏,但模型复核不能一轮失败就放弃:
/// 先保证基础可见数量,再让隐藏池至少形成一批已通过的竞争者。
nonisolated struct AIWorkspaceReviewPumpPolicy: Codable, Equatable, Sendable {
    let displayLimit: Int
    let hiddenCandidateCount: Int
    let activityLevel: AIBackgroundActivityLevel

    init(displayLimit: Int, hiddenCandidateCount: Int, activityLevel: AIBackgroundActivityLevel = .balanced) {
        self.displayLimit = max(1, displayLimit)
        self.hiddenCandidateCount = max(0, hiddenCandidateCount)
        self.activityLevel = activityLevel
    }

    var candidateLimit: Int {
        switch activityLevel {
        case .off, .powerSaver:
            return displayLimit
        case .balanced:
            return displayLimit * 2
        case .aggressive:
            return displayLimit * 3
        }
    }

    var minimumVisibleTarget: Int {
        min(2, min(displayLimit, hiddenCandidateCount))
    }

    var maxAttemptsPerTheme: Int {
        switch activityLevel {
        case .off:
            return 0
        case .powerSaver:
            return 2
        case .balanced:
            return max(2, min(5, displayLimit + 1))
        case .aggressive:
            return max(2, min(6, displayLimit + 2))
        }
    }

    var lazyWatermark: Int {
        guard hiddenCandidateCount > 0 else { return 0 }
        let fractionTarget: Int
        switch activityLevel {
        case .off:
            fractionTarget = 0
        case .powerSaver:
            fractionTarget = 1
        case .balanced:
            fractionTarget = Int(ceil(Double(displayLimit) / 3.0))
        case .aggressive:
            fractionTarget = Int(ceil(Double(displayLimit) / 2.0))
        }
        return min(hiddenCandidateCount, min(displayLimit, max(minimumVisibleTarget, fractionTarget)))
    }

    func isLazy(approvedCount: Int) -> Bool {
        lazyWatermark > 0 && approvedCount >= lazyWatermark
    }

    func reviewDelaySeconds(approvedCount: Int) -> Double {
        guard isLazy(approvedCount: approvedCount) else { return 0.35 }
        switch activityLevel {
        case .off:
            return .infinity
        case .powerSaver:
            return 60
        case .balanced:
            return 12
        case .aggressive:
            return 6
        }
    }

    func attemptPenalty(approvedCount: Int) -> Double {
        guard isLazy(approvedCount: approvedCount) else { return 1.5 }
        switch activityLevel {
        case .off:
            return .infinity
        case .powerSaver:
            return 5
        case .balanced:
            return 3.5
        case .aggressive:
            return 2.5
        }
    }

    var approvedTarget: Int {
        guard hiddenCandidateCount > 0, activityLevel != .off else { return 0 }
        let halfHidden = max(minimumVisibleTarget, hiddenCandidateCount / 2)
        let competitionBudget = max(minimumVisibleTarget, displayLimit * 2)
        return min(hiddenCandidateCount, min(halfHidden, competitionBudget))
    }
}

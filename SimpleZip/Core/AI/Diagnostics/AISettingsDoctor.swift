//
//  AISettingsDoctor.swift
//  SimpleZip
//
//  0.4.5 #80:AI 设置医生(白皮书 Feat 19)。把现有设置状态 + 用户意图合并,给出配置建议。模型只负责理解意图、
//  写一句回答并**从适用动作集合里选**;真正的设置修改仍走原生 Settings pane,由用户确认。
//
//  安全/边界:① 动作必须落在 `applicableActions(for:)`(按当前状态算出的、不是 no-op 的集合)里,模型发明或
//  无效的动作被 `sanitize` 剔除;② 全部动作都是 AI / 后台 / Spotlight 偏好或「打开某设置页」,**不碰加密 / 口令 /
//  GPG**;③ 不直接执行 —— 只产建议 id。纯函数 + 确定性,SwiftPM 可断言。
//

import Foundation

/// 设置医生关心的状态快照(低敏布尔 + 后台档位)。复用 `AIBackgroundActivityLevel`。
nonisolated struct AISettingsState: Codable, Equatable, Sendable {
    let aiEnabled: Bool
    let backgroundActivity: AIBackgroundActivityLevel
    let archivePreRead: Bool
    let folderPreIndex: Bool
    let spotlightIndexing: Bool

    init(aiEnabled: Bool, backgroundActivity: AIBackgroundActivityLevel,
         archivePreRead: Bool = false, folderPreIndex: Bool = false, spotlightIndexing: Bool = false) {
        self.aiEnabled = aiEnabled
        self.backgroundActivity = backgroundActivity
        self.archivePreRead = archivePreRead
        self.folderPreIndex = folderPreIndex
        self.spotlightIndexing = spotlightIndexing
    }
}

/// 喂给模型的设置医生事实。
nonisolated struct AISettingsDoctorFacts: Codable, Equatable, Sendable {
    let userIntent: String
    let state: AISettingsState

    init(userIntent: String, state: AISettingsState) {
        self.userIntent = userIntent
        self.state = state
    }
}

/// 设置医生回答。`answer` 模型润色(nil = 兜底);`actionIDs` 受 `applicableActions` 钳制。
nonisolated struct AISettingsDoctorAnswer: Codable, Equatable, Sendable {
    let answer: String?
    let actionIDs: [String]

    init(answer: String? = nil, actionIDs: [String] = []) {
        self.answer = answer
        self.actionIDs = actionIDs
    }
}

nonisolated enum AISettingsDoctor {
    /// 后台档位 → 设置动作 id。
    static func backgroundAction(for level: AIBackgroundActivityLevel) -> String {
        switch level {
        case .off: return "setBackgroundOff"
        case .powerSaver: return "setBackgroundPowerSaver"
        case .balanced: return "setBackgroundBalanced"
        case .aggressive: return "setBackgroundAggressive"
        }
    }

    /// 按当前状态算出「适用」(非 no-op)的动作集合 —— 模型只能从中选。
    static func applicableActions(for state: AISettingsState) -> Set<String> {
        var actions: Set<String> = ["openAISettings", "openPrivacyData"]

        if !state.aiEnabled {
            // AI 关闭时,唯一有意义的状态改动是开启它;其余偏好建议留到开启后。
            actions.insert("enableAI")
            return actions
        }

        // 后台档位:提供「非当前」的其它档位。
        for level in AIBackgroundActivityLevel.allCases where level != state.backgroundActivity {
            actions.insert(backgroundAction(for: level))
        }
        actions.insert(state.archivePreRead ? "disableArchivePreRead" : "enableArchivePreRead")
        actions.insert(state.folderPreIndex ? "disableFolderPreIndex" : "enableFolderPreIndex")
        actions.insert(state.spotlightIndexing ? "disableSpotlightIndexing" : "enableSpotlightIndexing")
        return actions
    }

    /// 钳制模型给的动作:只留当前状态下「适用」的(剔除 no-op / 发明的),保序去重。
    static func sanitize(_ actions: [String], for state: AISettingsState) -> [String] {
        let applicable = applicableActions(for: state)
        var seen = Set<String>()
        var out: [String] = []
        for a in actions where applicable.contains(a) && seen.insert(a).inserted { out.append(a) }
        return out
    }

    /// 无模型兜底:总能打开 AI 设置页(不猜意图)。
    static func deterministicAnswer(for facts: AISettingsDoctorFacts) -> AISettingsDoctorAnswer {
        AISettingsDoctorAnswer(answer: nil, actionIDs: ["openAISettings"])
    }
}

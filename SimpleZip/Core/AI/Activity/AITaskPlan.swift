//
//  AITaskPlan.swift
//  SimpleZip
//
//  0.4.5 #80:AI 命令排练 / 任务规划 + 批处理规划器(白皮书 Feat 22 / 建议二十二)。模型输出的**不是执行命令**,
//  而是任务计划(有序步骤)或批处理分组(把选择项分组 + 推荐动作)。App 展示计划,用户确认后逐步调用**现有**动作。
//
//  安全红线:① 动作 id 必须落在 `AITaskActionCatalog` 内(模型不能输出 shell / 发明动作),`sanitize` 剔除越界的;
//  ② 分组里的 itemID 必须校验为真实存在的选择项(模型不能凭空引用),`sanitizeBatch` 据 `validItemIDs` 过滤;
//  ③ `requiresUserReview` 恒 `true`(计算属性,模型无法influence)—— 绝不绕过确认。纯值 + 确定性,SwiftPM 可断言。
//

import Foundation

/// 计划 / 分组里允许出现的动作 id 全集(白皮书 action catalog)。模型只能从中选。
nonisolated enum AITaskActionCatalog {
    static let all: Set<String> = [
        "selectByRole", "runTest", "runReleaseInspection", "openReport", "open",
        "searchInside", "locateMainVolume", "convert", "extract", "compare",
        "runChecksum", "openSecurityReport"
    ]
}

/// 步骤作用目标(稳定英文 token)。
nonisolated enum AITaskTarget: String, Codable, CaseIterable, Equatable, Sendable {
    case selection   // 作用于当前选择 / 上一步结果
    case each        // 逐项
    case none        // 无目标(如打开报告)
}

/// 一个计划步骤。`selectionQuery` 复用 `AISelectionQuery`(如 selectByRole 步骤);`note` 为模型理由。
nonisolated struct AITaskPlanStep: Codable, Equatable, Sendable {
    let actionID: String
    let target: AITaskTarget
    let selectionQuery: AISelectionQuery?
    let note: String?

    init(actionID: String, target: AITaskTarget = .selection,
         selectionQuery: AISelectionQuery? = nil, note: String? = nil) {
        self.actionID = actionID
        self.target = target
        self.selectionQuery = selectionQuery
        self.note = note
    }
}

/// 有序任务计划。`requiresUserReview` 是**计算属性恒 true** —— 模型 JSON 里的同名字段被忽略,无法绕过确认。
nonisolated struct AITaskPlan: Codable, Equatable, Sendable {
    let steps: [AITaskPlanStep]
    let warnings: [String]

    /// 始终需要用户审阅后才执行。
    var requiresUserReview: Bool { true }

    init(steps: [AITaskPlanStep], warnings: [String] = []) {
        self.steps = steps
        self.warnings = warnings
    }

    // requiresUserReview 不参与编解码(它恒 true,不接受模型输入)。
    private enum CodingKeys: String, CodingKey { case steps, warnings }
}

/// 批处理分组里的一组。`titleSeed` / `reason` 模型润色;`itemIDs` 必须是真实选择项;`recommendedActionIDs` 受 catalog 钳制。
nonisolated struct AIBatchGroup: Codable, Equatable, Sendable {
    let titleSeed: String?
    let itemIDs: [String]
    let recommendedActionIDs: [String]
    let reason: String?

    init(titleSeed: String? = nil, itemIDs: [String],
         recommendedActionIDs: [String] = [], reason: String? = nil) {
        self.titleSeed = titleSeed
        self.itemIDs = itemIDs
        self.recommendedActionIDs = recommendedActionIDs
        self.reason = reason
    }
}

/// 批处理分组计划。`requiresUserReview` 恒 true。
nonisolated struct AIBatchPlan: Codable, Equatable, Sendable {
    let groups: [AIBatchGroup]
    let warnings: [String]

    var requiresUserReview: Bool { true }

    init(groups: [AIBatchGroup], warnings: [String] = []) {
        self.groups = groups
        self.warnings = warnings
    }

    private enum CodingKeys: String, CodingKey { case groups, warnings }
}

nonisolated enum AITaskPlanSanitizer {
    /// 钳制顺序计划:剔除 catalog 外的步骤动作,归一化每步的 selectionQuery,去重 warnings。
    static func sanitize(_ plan: AITaskPlan) -> AITaskPlan {
        let steps = plan.steps
            .filter { AITaskActionCatalog.all.contains($0.actionID) }
            .map { step in
                AITaskPlanStep(actionID: step.actionID, target: step.target,
                               selectionQuery: step.selectionQuery?.normalized(), note: step.note)
            }
        return AITaskPlan(steps: steps, warnings: dedup(plan.warnings))
    }

    /// 钳制批处理分组:itemID 必须是真实选择项,recommendedActionID 必须在 catalog 内,清空后无项的组丢弃。
    static func sanitizeBatch(_ plan: AIBatchPlan, validItemIDs: Set<String>) -> AIBatchPlan {
        let groups = plan.groups
            .map { g in
                AIBatchGroup(
                    titleSeed: g.titleSeed,
                    itemIDs: g.itemIDs.filter(validItemIDs.contains),
                    recommendedActionIDs: g.recommendedActionIDs.filter(AITaskActionCatalog.all.contains),
                    reason: g.reason)
            }
            .filter { !$0.itemIDs.isEmpty }
        return AIBatchPlan(groups: groups, warnings: dedup(plan.warnings))
    }

    private static func dedup(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for x in xs where seen.insert(x).inserted { out.append(x) }
        return out
    }
}

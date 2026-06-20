//
//  AIVirtualFolderModelPlanner.swift
//  SimpleZip
//
//  0.4.5 #80 #89:**AI 文件夹的虚拟目录树由本地模型生成**(白皮书建议四的核心 —— 否则只是「主题推荐 +
//  确定性 bucket」,不配叫 AI 文件夹)。
//
//  分工(白皮书硬约束,在此严格落地):
//   - App 确定性召回候选 + 投影成 prompt-safe 的 `AIVirtualFolderPlanInput`(只含 candidateID / kind / 展示名 /
//     roleTags / source ref 的 kind+id —— **绝不含真实路径 / 内容 / 加密条目名 / 口令**);
//   - 模型**只产薄 plan**:给每个候选起目录名、分组、短理由,只能引用给定的 candidateID,**绝不发明 id、绝不输出路径**;
//   - App 校验 candidateID(`AIVirtualFolderTreeBuilder.build` 丢弃无效 id)→ `mode: .modelAssisted` 建树 → 再套用户覆盖层。
//
//  门控:仅 `AIReportAssistant.isReady`(AI 主开关 + macOS 26 + 模型可用)时调用;不可用 → 调用点退回 `buildDeterministic`。
//  失败不崩:抛错由调用点吞掉、退回确定性树。
//
//  **阶段3:本类型退成薄 XPC 客户端**。每个 pass(拼 prompt + 调模型 + 解析)整条都在「只编进 agent+XPC」的引擎层
//  `AIPassEngine` 跑(过引擎自己的全局串行闸,杜绝 FoundationModels transcript 重叠 trap);本类型只拼 Core 输入 →
//  经 `AIAgentClient.generatePass` 发前台 XPC Service → 收输出,**自己不再 import FoundationModels / 不持有 @Generable**。
//  早先在本文件、现已迁进引擎的一句话/结构化 pass(failureExplanation / chip 排序与命名 / archiveKindGuess / archiveEntryPicks /
//  urlOpen / diskImage / activityReminder / longFileSummary …)及其 @Generable 一并删除,改由各真实调用点经 generatePass 调。
//

import Foundation

@available(macOS 26.0, *)
enum AIVirtualFolderModelPlanner {
    /// **通过后单独生成** AI 建议:给一个已整理好的文件夹里的条目挑「值得的动作」。整条 pass 在 XPC 引擎跑
    /// (AIPassEngine.workspaceNodeSuggestions);App 直接传 Core 候选、收 [AINodeSuggestionPlan]。失败由调用点吞掉。
    static func suggestions(forItems items: [AIVirtualNodePromptCandidate]) async throws -> [AINodeSuggestionPlan] {
        guard !items.isEmpty else { return [] }
        return try await AIAgentClient.generatePass(
            kind: .workspaceNodeSuggestions, input: items, as: [AINodeSuggestionPlan].self)
    }

    /// **文件浏览器「文件折叠组建议」**:模型圈出几组「一组文件 + 一个批量动作」(几个归档→一起测试、一堆发布物→
    /// 一起算哈希…),大多数文件夹一组都没有。整条 pass 在 XPC 引擎跑(AIPassEngine.workspaceFolderGroups);
    /// App 直接传 Core 候选、收 DTO 转回元组(成员 candidateID 列表, 动作 token)。失败 / 空 → []。
    static func folderGroupSuggestions(items: [AIVirtualNodePromptCandidate])
        async throws -> [(memberIDs: [String], actionToken: String)] {
        guard items.count >= 2 else { return [] }
        let out = try await AIAgentClient.generatePass(
            kind: .workspaceFolderGroups, input: items, as: WorkspaceFolderGroupOutput.self)
        return out.groups.map { (memberIDs: $0.memberIDs, actionToken: $0.actionToken) }
    }

    /// **文件夹「整理进新文件夹」建议**(Task 7):模型判断是否有一簇同类文件值得归进新子文件夹 + 起主题名 + 圈成员
    /// (≥3)。整条 pass 在 XPC 引擎跑(AIPassEngine.workspaceOrganize);不值得 / 没明显簇 → 引擎回 nil。失败由调用点吞掉。
    static func organizeSuggestion(items: [AIVirtualNodePromptCandidate]) async throws
        -> (folderName: String, memberIDs: [String])? {
        guard items.count >= 3 else { return nil }
        guard let out = try await AIAgentClient.generatePass(
            kind: .workspaceOrganize, input: items, as: WorkspaceOrganizeOutput?.self) else { return nil }
        return (folderName: out.folderName, memberIDs: out.memberIDs)
    }

    /// **文件浏览器单文件抽屉**的模型驱动建议(②b/②c)。摘要给人看(界面语言);动作只能从词表里挑且适用该 kind,
    /// App 据 token + 路径安全合成动作(模型不拼路径)。整条 pass(含拼动作词表)在 XPC 引擎跑(AIPassEngine.fileSuggestion);
    /// 引擎只回原始 token,**token 词表校验 + AIFileSuggestedAction 拼装留 App**(依赖 Core 的 kind 适用 / openWith 合成)。
    /// `excerpt` 必须**已脱敏**(调用方后台读 + AISensitiveRedactor.redact 后传入)。失败由调用点吞掉。
    static func fileSuggestion(fileName: String, kind: String, roleTags: [String], languageHint: String?,
                               headings: [String], fieldNames: [String], excerpt: String,
                               candidateOpenApps: [(bundleID: String, name: String)] = [],
                               discouragedTokens: [String] = [])
        async throws -> (summary: String, actions: [AIFileSuggestedAction]) {
        let apps = Array(candidateOpenApps.prefix(8))
        let input = FileSuggestionInput(
            fileName: fileName, kind: kind, roleTags: roleTags, languageHint: languageHint,
            headings: headings, fieldNames: fieldNames, excerpt: excerpt,
            candidateOpenApps: apps.map { FileSuggestionInput.AppCandidate(bundleID: $0.bundleID, name: $0.name) },
            discouragedTokens: discouragedTokens)
        let out = try await AIAgentClient.generatePass(
            kind: .fileSuggestion, input: input, as: AIPassFileSuggestionOutput.self)
        var seen = Set<String>()
        let tokens = out.actions.compactMap { raw -> String? in
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard AIVirtualNodeActionDeriver.allowedSuggestionDescriptors
                .contains(where: { $0.id == t && $0.appliesToKinds.contains(kind) }),
                seen.insert(t).inserted else { return nil }
            return t
        }
        var actions = tokens.map { AIFileSuggestedAction(token: $0) }
        // 推荐打开方式(只推非默认 app):模型按序号挑;App 据 bundleId 安全合成动作。
        let n = out.openWithAppNumber
        if !apps.isEmpty, n >= 1, n <= apps.count {
            let app = apps[n - 1]
            actions.append(AIFileSuggestedAction(token: "openWith", payload: app.bundleID, label: app.name))
        }
        return (out.summary, actions)
    }

    /// **动态核查**:对一个已成型文件夹的成员,让模型挑出**明显不扣题**的(保守 —— 拿不准就留)。整条 pass 在 XPC
    /// 引擎跑(AIPassEngine.workspaceVerifyMisfits);App 收要移除的 candidateID 转 Set(据此从虚拟文件夹剔除,不碰磁盘)。
    static func verifyMisfits(theme: String, items: [AIVirtualNodePromptCandidate]) async throws -> Set<String> {
        guard !items.isEmpty else { return [] }
        let ids = try await AIAgentClient.generatePass(
            kind: .workspaceVerifyMisfits,
            input: WorkspaceVerifyMisfitsInput(theme: theme, items: items),
            as: [String].self)
        return Set(ids)
    }

    /// 从 prompt-safe 输入让本地模型生成虚拟目录 plan。整条 pass 在 XPC 引擎跑(AIPassEngine.workspacePlan);返回的
    /// plan 的 candidateID 已在引擎据序号回查,App 仍交 `AIVirtualFolderTreeBuilder.build` 防御性校验。失败退确定性树。
    static func plan(for input: AIVirtualFolderPlanInput) async throws -> AIVirtualFolderPlan {
        return try await AIAgentClient.generatePass(
            kind: .workspacePlan, input: input, as: AIVirtualFolderPlan.self)
    }

    /// **后台复核**:模型既判断候选主题**值不值得作为文件夹出现**(质量优先),又顺带产出 plan。整条 pass 在 XPC 引擎跑
    /// (AIPassEngine.workspaceReview)。attempt/approvedTarget 仅调用点重试语义用、原实现未进 prompt,故不跨 XPC 传。
    static func review(for input: AIVirtualFolderPlanInput, attempt: Int = 1,
                       approvedTarget: Int = 0) async throws -> AIFolderReview {
        return try await AIAgentClient.generatePass(
            kind: .workspaceReview, input: input, as: AIFolderReview.self)
    }
}

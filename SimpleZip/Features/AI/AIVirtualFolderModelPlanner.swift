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
//  失败不崩:抛错由调用点吞掉、退回确定性树。所有生成过全局串行闸(`AIGenerationSerializer`),不与其它 AI 生成重叠。
//

import Foundation
import FoundationModels

/// 模型产出的单个虚拟目录组(扁平一层,可靠性优先 —— 递归 @Generable 易抖)。
@available(macOS 26.0, *)
@Generable
struct GeneratedAIFolderGroup: Sendable {
    @Guide(description: "A short human folder name for this group, by what the items ARE or their shared topic (e.g. a couple of words like 'source code', 'figures', 'drafts'). No path, no slashes, 1-3 words.")
    var title: String
    @Guide(description: "One short phrase on why these belong together. May be empty.")
    var reason: String
    @Guide(description: "The candidateID strings, copied VERBATIM from the provided items list, that belong in this group. Use ONLY ids that appear in the list; never invent or alter an id.")
    var candidateIDs: [String]
}

/// 模型产出的整份虚拟目录 plan。
@available(macOS 26.0, *)
@Generable
struct GeneratedAIFolderPlan: Sendable {
    @Guide(description: "An optional clearer name for the whole folder/workspace. Empty to keep the current title.")
    var workspaceTitle: String
    @Guide(description: "Between 2 and 6 groups organizing the items by meaning. Put every item in exactly one group; prefer a small number of clear, well-named groups over many tiny ones.")
    var groups: [GeneratedAIFolderGroup]
}

@available(macOS 26.0, *)
enum AIVirtualFolderModelPlanner {
    /// 从 prompt-safe 输入让本地模型生成虚拟目录 plan。返回的 plan 的 candidateID 仍可能含界外值 ——
    /// 交给 `AIVirtualFolderTreeBuilder.build` 统一校验丢弃(防御性)。失败抛出,调用点退回确定性树。
    static func plan(for input: AIVirtualFolderPlanInput) async throws -> AIVirtualFolderPlan {
        let instructions = """
        You organize a set of items into a small, sensible folder structure for an archive app's "AI folder". \
        Each item below is one line: "candidateID<TAB>kind<TAB>name<TAB>roleTags". Group the items by what they \
        ARE or their shared topic, and give each group a short, natural folder name (a couple of words). \
        Put every item in exactly one group, prefer a few clear groups over many tiny ones, and base the grouping \
        ONLY on the names, kinds and roleTags given. Copy candidateID values VERBATIM — never invent, alter, drop, \
        or output a file path. The folder's theme hints (if any) tell you what the user cares about; let them guide \
        the names and grouping. Reply only with the structured plan.
        """
        var lines: [String] = []
        let ws = input.workspace
        if let prompt = ws.prompt, !prompt.isEmpty { lines.append("Folder theme: \(prompt)") }
        if !ws.queryTokens.isEmpty { lines.append("Theme hints: \(ws.queryTokens.joined(separator: ", "))") }
        lines.append("Current title: \(ws.title)")
        lines.append("Items (candidateID<TAB>kind<TAB>name<TAB>roleTags):")
        for c in input.candidates.prefix(120) {
            lines.append([c.candidateID, c.kind, c.displayName, c.roleTags.joined(separator: " ")].joined(separator: "\t"))
        }
        let generated = try await AIReportAssistant.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"), as: GeneratedAIFolderPlan.self)

        let title = generated.workspaceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = generated.groups.enumerated().map { index, g in
            AIVirtualFolderGroupPlan(
                id: "model-\(index)",
                title: g.title,
                reason: g.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : g.reason,
                candidateIDs: g.candidateIDs)
        }
        return AIVirtualFolderPlan(workspaceTitle: title.isEmpty ? nil : title, groups: groups)
    }
}

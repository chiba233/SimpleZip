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
    @Guide(description: "True ONLY for the one (at most two) group the user should see expanded first — the most important / most worth their attention right now. Leave the rest false (collapsed). Most groups should be false; never mark everything true.")
    var expandFirst: Bool
}

/// 模型产出的整份虚拟目录 plan。
@available(macOS 26.0, *)
@Generable
struct GeneratedAIFolderPlan: Sendable {
    @Guide(description: "True only if these items genuinely form ONE coherent, useful theme that deserves its own folder — a clear shared purpose, project or topic a person would recognize. False if they merely share a generic word, are an unrelated grab-bag, or are too thin to be worth surfacing. Be strict: quality over quantity.")
    var worthSurfacing: Bool
    @Guide(description: "An optional clearer name for the whole folder/workspace. Empty to keep the current title.")
    var workspaceTitle: String
    @Guide(description: "Between 2 and 6 groups organizing the items that truly belong by meaning. Put each kept item in exactly one group; prefer a small number of clear, well-named groups over many tiny ones.")
    var groups: [GeneratedAIFolderGroup]
}

/// 一次模型复核的结果:是否值得作为文件夹出现 + 它的 plan(命名 / 选成员 / 分组)。
@available(macOS 26.0, *)
struct AIFolderReview: Sendable {
    let worthSurfacing: Bool
    let plan: AIVirtualFolderPlan
}

@available(macOS 26.0, *)
enum AIVirtualFolderModelPlanner {
    /// 命名 + 语言规则(两个 prompt 共用)。修用户报的「文件夹名总出现 AI / AI项目 之类」——禁止把 AI / 文件夹 /
    /// 集合 等元词塞进名字,要按真实主题起名;给人看的字段按界面语言写,candidateID 照抄不翻译。
    static var namingRule: String {
        """
        Write the workspaceTitle, every group title and every reason in \(AIReportAssistant.uiLanguageName) (these \
        are shown to the user). Name everything by its REAL subject — the actual topic, project, or what the items \
        are — exactly as a person would name it. NEVER put meta words like "AI", "assistant", "folder", "collection", \
        "group", "files", "directory", "workspace" or "smart" into any title unless that word is literally part of \
        the real subject. The candidateID values are opaque identifiers — copy them exactly, never translate them.
        """
    }

    /// 从 prompt-safe 输入让本地模型生成虚拟目录 plan。返回的 plan 的 candidateID 仍可能含界外值 ——
    /// 交给 `AIVirtualFolderTreeBuilder.build` 统一校验丢弃(防御性)。失败抛出,调用点退回确定性树。
    static func plan(for input: AIVirtualFolderPlanInput) async throws -> AIVirtualFolderPlan {
        let instructions = """
        You curate and organize a set of related items around a theme. Each item below is one line: \
        "candidateID<TAB>kind<TAB>name<TAB>roleTags". Using the theme and hints, decide which items genuinely \
        BELONG together and SELECT only those — leave out items that don't fit (you are choosing membership, not \
        forced to place everything). Then group the selected items by what they ARE or their shared topic, give \
        each group a short natural name, and propose a clear name for the whole collection. Prefer a few clear \
        groups over many tiny ones, and base everything ONLY on the names, kinds and roleTags given. Copy \
        candidateID values VERBATIM — never invent, alter, or output a file path; simply omit any item that \
        doesn't belong rather than forcing it into a group.

        \(Self.namingRule)
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

        return Self.assemble(generated).plan
    }

    /// **后台复核**:模型既判断这个候选主题**值不值得作为文件夹出现**(质量优先,不保数量),又顺带产出它的 plan
    /// (命名 / 选成员 / 分组)。`worthSurfacing == false` → 调用点不把它升成可见工作区。
    static func review(for input: AIVirtualFolderPlanInput) async throws -> AIFolderReview {
        let instructions = """
        You are the quality gate for an archive app's background "AI folders". Each item below is one line: \
        "candidateID<TAB>kind<TAB>name<TAB>roleTags". First judge whether these items genuinely form ONE coherent, \
        useful theme that a person would recognize as deserving its own folder (a shared project, topic or purpose) — \
        not just items that share a generic word, an unrelated grab-bag, or too thin to matter. Be strict: it is far \
        better to surface nothing than a weak folder. If it IS worth surfacing, also curate it: select only the items \
        that truly belong (omit the rest), group them by meaning with short natural folder names, and propose a clear \
        name for the whole folder.

        Copy candidateID values VERBATIM — never invent, alter, translate, or output a file path. Reply only with \
        the structured plan, including worthSurfacing.

        \(Self.namingRule)
        """
        var lines: [String] = []
        let ws = input.workspace
        if let prompt = ws.prompt, !prompt.isEmpty { lines.append("Folder theme: \(prompt)") }
        if !ws.queryTokens.isEmpty { lines.append("Theme hints: \(ws.queryTokens.joined(separator: ", "))") }
        lines.append("Candidate title: \(ws.title)")
        lines.append("Items (candidateID<TAB>kind<TAB>name<TAB>roleTags):")
        for c in input.candidates.prefix(120) {
            lines.append([c.candidateID, c.kind, c.displayName, c.roleTags.joined(separator: " ")].joined(separator: "\t"))
        }
        let generated = try await AIReportAssistant.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"), as: GeneratedAIFolderPlan.self)
        return Self.assemble(generated)
    }

    private static func assemble(_ generated: GeneratedAIFolderPlan) -> AIFolderReview {
        let title = generated.workspaceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = generated.groups.enumerated().map { index, g in
            AIVirtualFolderGroupPlan(
                id: "model-\(index)",
                title: g.title,
                reason: g.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : g.reason,
                candidateIDs: g.candidateIDs,
                prominent: g.expandFirst)   // AI 注意力:这组该不该默认展开
        }
        let plan = AIVirtualFolderPlan(workspaceTitle: title.isEmpty ? nil : title, groups: groups)
        return AIFolderReview(worthSurfacing: generated.worthSurfacing, plan: plan)
    }
}

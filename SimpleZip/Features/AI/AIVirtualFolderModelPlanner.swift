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
/// **最简字段**:小模型对这套门控生成单次失败率极高(实测 ~90%),去掉 reason 自由文本等一切非必需输出。
@available(macOS 26.0, *)
@Generable
struct GeneratedAIFolderGroup: Sendable {
    @Guide(description: "A short human folder name for this group, by what the items ARE or their shared topic (e.g. a couple of words like 'source code', 'figures', 'drafts'). No path, no slashes, 1-3 words.")
    var title: String
    @Guide(description: "The item NUMBERS (the leftmost column of the items list, e.g. \"3\", \"7\") that belong in this group. Use only numbers that actually appear in the list; never invent one.")
    var candidateIDs: [String]
    @Guide(description: "True ONLY for the one (at most two) group the user should see expanded first — the most important / most worth their attention right now. Leave the rest false (collapsed). Most groups should be false; never mark everything true.")
    var expandFirst: Bool
}

/// 模型产出的整份虚拟目录 plan。**门控只产「值不值得 + 命名 + 分组」三件**;AI 建议改成通过后单独生成
/// (嵌套 suggestions 数组会显著拉高单次生成失败率,而门控可靠性是 AI 文件夹的命脉)。
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

/// 模型给单个条目挑的一条 AI 建议(**通过后单独生成**,不进门控 schema —— 嵌套数组会拖垮门控可靠性)。扁平 2 字段。
@available(macOS 26.0, *)
@Generable
struct GeneratedNodeSuggestion: Sendable {
    @Guide(description: "The item NUMBER (the leftmost column of the items list) this suggestion is for.")
    var targetID: String
    @Guide(description: "ONE action token from the allowed-actions list (e.g. hash, compress, test, inspect, convert). Use a token whose 'applies to' kinds include this item's kind.")
    var action: String
}

@available(macOS 26.0, *)
@Generable
struct GeneratedSuggestionSet: Sendable {
    @Guide(description: "A FEW per-item action suggestions — only where there is a clear, specific reason for that item. Most items get NONE. Empty if nothing stands out.")
    var suggestions: [GeneratedNodeSuggestion]
}

@available(macOS 26.0, *)
enum AIVirtualFolderModelPlanner {
    /// 命名 + 语言规则(两个 prompt 共用)。**语言放最前 + 强制**(修用户报的「文件夹名经常语言不一致」):给人看的
    /// workspaceTitle / 分组名必须用界面语言;禁止 AI / 文件夹 / 集合 等元词塞进名字,要按真实主题起名。
    static var namingRule: String {
        let lang = AIReportAssistant.uiLanguageName
        return """
        LANGUAGE — MANDATORY: write the workspaceTitle and EVERY group title in \(lang). Never use any other \
        language for them, not even partially. Name everything by its REAL subject — the actual topic, project, or \
        what the items are — exactly as a person would name it in \(lang). NEVER put meta words like "AI", \
        "assistant", "folder", "collection", "group", "files", "directory", "workspace" or "smart" into any title \
        unless that word is literally part of the real subject. The item numbers are plain integers — use them \
        exactly as given, never translate or alter them.
        """
    }

    /// 可建议动作词表(单独生成建议时喂模型)。和 `allowedSuggestionDescriptors` 同源;**绝不让模型拼路径**,
    /// 路径由 App 按 token + 目标条目回查。
    static var actionVocabularyRule: String {
        let lines = AIVirtualNodeActionDeriver.allowedSuggestionDescriptors.map {
            "  - \($0.id) (applies to: \($0.appliesToKinds.joined(separator: " / "))): \($0.userVisibleLabel)"
        }
        return "Allowed action tokens (use the token verbatim):\n" + lines.joined(separator: "\n")
    }

    /// **通过后单独生成** AI 建议:给一个已整理好的文件夹里的条目挑「值得的动作」(扁平简单 schema,可靠)。
    /// 模型按序号引用条目、按 token 选动作;App 回译 + 校验词表。失败 / 空 → 返回 []。
    static func suggestions(forItems items: [AIVirtualNodePromptCandidate]) async throws -> [AINodeSuggestionPlan] {
        guard !items.isEmpty else { return [] }
        let cands = Array(items.prefix(40))
        let instructions = """
        The items below are already grouped into one folder. Optionally suggest a useful next action for a FEW of \
        them — ONLY where there is a clear, specific reason for that item (e.g. an untested release archive → test; \
        a big stray folder → compress). MOST items get NONE; never suggest an action just because it is possible. \
        Refer to items by their NUMBER, never output a path.

        \(Self.actionVocabularyRule)
        """
        var lines = ["Items (number<TAB>kind<TAB>name) — refer to items by their number:"]
        for (i, c) in cands.enumerated() {
            lines.append(["\(i + 1)", c.kind, c.displayName].joined(separator: "\t"))
        }
        let generated = try await AIReportAssistant.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedSuggestionSet.self, maxAttempts: 8)
        var seen = Set<String>()
        return generated.suggestions.compactMap { s -> AINodeSuggestionPlan? in
            let token = s.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard AIVirtualNodeActionDeriver.allowedSuggestionDescriptors.contains(where: { $0.id == token }),
                  let target = realID(s.targetID, in: cands),
                  seen.insert(target + "|" + token).inserted   // 同目标同 token 去重
            else { return nil }
            return AINodeSuggestionPlan(targetCandidateID: target, actionToken: token)
        }
    }

    /// 把用户对这个工作区的累积调教(固定 / 排除 / 喜欢 / 不喜欢 / 分组命名)展开成几行 prompt 提示(架构债 #4:
    /// 自循环喂进模型)。携带名字 / 来源目录 / 角色 / 用户起的组名 —— **路径不是隐私红线**(见隐私口径);空则返回空。
    static func hintLines(_ hints: AIWorkspaceLearningHints?) -> [String] {
        guard let h = hints, !h.isEmpty else { return [] }
        var lines: [String] = []
        if !h.userGroupTitles.isEmpty {
            lines.append("Group names the user has chosen here (reuse and honor these names/themes when grouping): "
                + h.userGroupTitles.prefix(12).joined(separator: ", "))
        }
        if !h.keptItemNames.isEmpty {
            lines.append("Items the user explicitly KEEPS here (name and location — favor selecting items like these): "
                + h.keptItemNames.prefix(24).joined(separator: ", "))
        }
        if !h.removedItemNames.isEmpty {
            lines.append("Items the user REMOVED from here (name and location — do NOT bring back items like these): "
                + h.removedItemNames.prefix(24).joined(separator: ", "))
        }
        if !h.preferredRoleTags.isEmpty {
            lines.append("Kinds of item the user likes here: " + h.preferredRoleTags.prefix(12).joined(separator: ", "))
        }
        if !h.rejectedRoleTags.isEmpty {
            lines.append("Kinds of item the user dislikes here: " + h.rejectedRoleTags.prefix(12).joined(separator: ", "))
        }
        return lines
    }

    /// 从 prompt-safe 输入让本地模型生成虚拟目录 plan。返回的 plan 的 candidateID 仍可能含界外值 ——
    /// 交给 `AIVirtualFolderTreeBuilder.build` 统一校验丢弃(防御性)。失败抛出,调用点退回确定性树。
    static func plan(for input: AIVirtualFolderPlanInput) async throws -> AIVirtualFolderPlan {
        let instructions = """
        You curate and organize a set of related items around a theme. Each item below is one line: \
        "number<TAB>kind<TAB>name<TAB>roleTags", where number is a small integer in the leftmost column. Using the \
        theme and hints, decide which items genuinely BELONG together and SELECT only those — leave out items that \
        don't fit (you are choosing membership, not forced to place everything). Then group the selected items by \
        what they ARE or their shared topic, give each group a short natural name, and propose a clear name for the \
        whole collection. Prefer a few clear groups over many tiny ones, and base everything ONLY on the names, kinds \
        and roleTags given. Refer to each item by its NUMBER (the leftmost column) — never output a file path; simply \
        omit any item that doesn't belong rather than forcing it into a group.

        If the input states items the user KEEPS or REMOVED, kinds they like/dislike, or group names they chose, \
        treat these as strong guidance learned from this user: favor items like the ones they keep, leave out items \
        like the ones they removed, and reuse the group names/themes they picked.

        \(Self.namingRule)
        """
        let cands = Array(input.candidates.prefix(40))   // 短 prompt 更稳(单次生成失败率随长度飙升)
        var lines: [String] = []
        let ws = input.workspace
        if let prompt = ws.prompt, !prompt.isEmpty { lines.append("Folder theme: \(prompt)") }
        if !ws.queryTokens.isEmpty { lines.append("Theme hints: \(ws.queryTokens.joined(separator: ", "))") }
        lines.append("Current title: \(ws.title)")
        lines.append(contentsOf: Self.hintLines(input.learningHints))
        lines.append("Items (number<TAB>kind<TAB>name<TAB>roleTags) — refer to items by their number:")
        for (i, c) in cands.enumerated() {
            lines.append(["\(i + 1)", c.kind, c.displayName, c.roleTags.joined(separator: " ")].joined(separator: "\t"))
        }
        let generated = try await AIReportAssistant.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"), as: GeneratedAIFolderPlan.self,
            maxAttempts: 12)   // 「模型不行时间来凑」:连试 12 代 + 极简 schema + 短 prompt 一起压报错

        return Self.assemble(generated, candidates: cands).plan
    }

    /// **后台复核**:模型既判断这个候选主题**值不值得作为文件夹出现**(质量优先,不保数量),又顺带产出它的 plan
    /// (命名 / 选成员 / 分组)。`worthSurfacing == false` → 调用点不把它升成可见工作区。
    static func review(for input: AIVirtualFolderPlanInput, attempt: Int = 1,
                       approvedTarget: Int = 0) async throws -> AIFolderReview {
        let instructions = """
        You are the quality judge for a background "AI folder". Each item below is one line: \
        "number<TAB>kind<TAB>name<TAB>roleTags", where number is a small integer in the leftmost column. These items \
        were grouped only because they share a name token or a common task/archive — but a shared token is often \
        COINCIDENTAL (many unrelated files just happen to contain a common word like "report", "final", "image", \
        "v2" or a date). Your job is to judge whether they form a theme a PERSON would actually keep as ONE folder: \
        a real shared project, topic, dataset, deliverable or purpose. Set worthSurfacing = true when there is a \
        clear, recognizable theme with at least two items that genuinely belong together; then curate it — keep the \
        items that fit, drop the ones that only coincidentally matched, group them by meaning with short natural \
        folder names, and propose a clear name. Set worthSurfacing = false when the items only share a generic word \
        with no real connection, when barely one or two actually relate, or when it is a loose mix you would not \
        bother making a folder for. Be a real judge: a confident yes for solid themes, a clear no for generic or \
        thin ones — do not rubber-stamp, but do not demand perfection either.

        Refer to items by their NUMBER (the leftmost column) — never invent a number, output a file path, or \
        translate names. Reply only with the structured plan, including worthSurfacing.

        If the input states items the user KEEPS or REMOVED, kinds they like/dislike, or group names they chose, \
        treat these as strong guidance: a theme the user has actively curated is more worth surfacing, and you \
        should honor what they keep, leave out, and how they name groups.

        \(Self.namingRule)
        """
        let cands = Array(input.candidates.prefix(40))   // 短 prompt 更稳(单次生成失败率随长度飙升)
        var lines: [String] = []
        let ws = input.workspace
        if let prompt = ws.prompt, !prompt.isEmpty { lines.append("Folder theme: \(prompt)") }
        if !ws.queryTokens.isEmpty { lines.append("Theme hints: \(ws.queryTokens.joined(separator: ", "))") }
        lines.append("Candidate title: \(ws.title)")
        lines.append(contentsOf: Self.hintLines(input.learningHints))
        lines.append("Items (number<TAB>kind<TAB>name<TAB>roleTags) — refer to items by their number:")
        for (i, c) in cands.enumerated() {
            lines.append(["\(i + 1)", c.kind, c.displayName, c.roleTags.joined(separator: " ")].joined(separator: "\t"))
        }
        let generated = try await AIReportAssistant.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"), as: GeneratedAIFolderPlan.self,
            maxAttempts: 12)   // 「模型不行时间来凑」:连试 12 代 + 极简 schema + 短 prompt 一起压报错
        return Self.assemble(generated, candidates: cands)
    }

    /// 模型输出按**序号**引用条目(小模型照抄长 opaque candidateID 极易出错 → 一个都对不上 → 永远判否)。
    /// 这里把序号翻译回真实 candidateID;`candidates` 必须与喂 prompt 时同一份(同 `prefix(120)`、同序)。
    private static func assemble(_ generated: GeneratedAIFolderPlan,
                                 candidates: [AIVirtualNodePromptCandidate]) -> AIFolderReview {
        let title = generated.workspaceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = generated.groups.enumerated().map { index, g in
            AIVirtualFolderGroupPlan(
                id: "model-\(index)",
                title: g.title,
                candidateIDs: g.candidateIDs.compactMap { realID($0, in: candidates) },
                prominent: g.expandFirst)   // AI 注意力:这组该不该默认展开
        }
        // 门控不再产 AI 建议(suggestions 留空 → 通过后单独生成);最简 schema 提可靠性。
        let plan = AIVirtualFolderPlan(workspaceTitle: title.isEmpty ? nil : title, groups: groups)
        return AIFolderReview(worthSurfacing: generated.worthSurfacing, plan: plan)
    }

    /// 把模型返回的「序号 token」翻译回真实 candidateID。容忍 "3" / "#3" / "item 3" / "3." 等 —— 抽第一个整数;
    /// 越界 / 非数字 → nil(丢弃,builder 再做白名单校验)。
    private static func realID(_ token: String, in candidates: [AIVirtualNodePromptCandidate]) -> String? {
        guard let n = firstInt(in: token), n >= 1, n <= candidates.count else { return nil }
        return candidates[n - 1].candidateID
    }

    private static func firstInt(in s: String) -> Int? {
        var digits = ""
        for ch in s {
            if ch.isNumber { digits.append(ch) } else if !digits.isEmpty { break }
        }
        return Int(digits)
    }
}

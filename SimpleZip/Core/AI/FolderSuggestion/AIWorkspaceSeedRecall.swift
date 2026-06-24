//
//  AIWorkspaceSeedRecall.swift
//  SimpleZip
//
//  0.4.5 #80 #89:从**用户种子**召回一个工作区的成员(白皮书建议四的「闭环」)。
//
//  用户工作区(或被「我很喜欢 / 手动加入 / 描述」喂过的工作区)不该是空壳 —— 它的成员从全局候选池按种子召回:
//    成员 = (固定的 pinned 引用)∪(语义命中主题提示词 themePrompts 的候选)−(排除的 excluded 引用)。
//  这样用户的修改(喜欢→pin、不喜欢→exclude、描述/改名→themePrompts)**真的改变下次召回到的成员**,而不只是
//  当前显示层覆盖。语义命中复用主题引擎同款 token 逻辑(名字 token 重叠 / CJK 子串),位置不参与。
//
//  纯值 + 确定性,SwiftPM 可断言。
//

import Foundation

nonisolated enum AIWorkspaceSeedRecall {
    /// 从候选池按种子召回成员。`pinned` 永远在(除非也在 excluded —— 种子内部已保证互斥);`excluded` 永远不在;
    /// 其余靠主题提示词语义命中。无提示词且无固定时只返回固定集(可能为空)。
    static func members(in pool: [AIVirtualNodeCandidate], seed: AIWorkspaceUserSeed) -> [AIVirtualNodeCandidate] {
        let pinned = Set(seed.pinnedSourceRefs)
        let excluded = Set(seed.excludedSourceRefs)
        let promptTokens = tokenize(seed.themePrompts)
        return pool.filter { candidate in
            let refs = candidate.sourceRefs
            if refs.contains(where: { excluded.contains($0) }) { return false }      // 排除优先
            if refs.contains(where: { pinned.contains($0) }) { return true }          // 固定必在
            guard !promptTokens.isEmpty else { return false }                         // 无提示词 → 只认固定
            let candidateTokens = tokensFor(candidate)
            if !candidateTokens.isDisjoint(with: promptTokens) { return true }        // 精确 token 命中
            return cjkSubstringMatch(candidateTokens, promptTokens)                   // CJK 子串命中
        }
    }

    // MARK: - token(与 AIWorkspaceThemeEngine 同款低敏分词)

    /// 把主题提示词(用户描述 / prompt / 分组标题)拆成召回 token。
    private static func tokenize(_ prompts: [String]) -> Set<String> {
        var tokens = Set<String>()
        for prompt in prompts { tokens.formUnion(nameTokens(prompt)) }
        return tokens
    }

    private static func tokensFor(_ candidate: AIVirtualNodeCandidate) -> Set<String> {
        var tokens = nameTokens(candidate.displayName)
        for raw in candidate.semanticTokens {
            let t = raw.lowercased()
            guard t.count >= 2, t.contains(where: { !$0.isNumber }) else { continue }
            tokens.insert(t)
        }
        return tokens
    }

    /// 按非字母数字切、去扩展名、小写、丢纯数字 / <2 字符;CJK 复合词整体保留(无分隔)。
    private static func nameTokens(_ text: String) -> Set<String> {
        let base = ((text as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        var tokens = Set<String>()
        var current = ""
        func flush() {
            defer { current = "" }
            guard current.count >= 2, current.contains(where: { !$0.isNumber }) else { return }
            tokens.insert(current)
        }
        for ch in base {
            if ch.isLetter || ch.isNumber { current.append(ch) } else { flush() }
        }
        flush()
        return tokens
    }

    /// CJK 子串命中:一边某 CJK token(len≥2)是另一边某 token 的子串(中文「论文」⊂「论文修订意见」)。
    private static func cjkSubstringMatch(_ a: Set<String>, _ b: Set<String>) -> Bool {
        func anyContained(_ small: Set<String>, in big: Set<String>) -> Bool {
            for s in small where s.count >= 2 && containsCJK(s) {
                if big.contains(where: { $0 != s && ($0.contains(s) || s.contains($0)) }) { return true }
            }
            return false
        }
        return anyContained(a, in: b) || anyContained(b, in: a)
    }

    private static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { sc in
            (0x4E00...0x9FFF).contains(sc.value) || (0x3040...0x30FF).contains(sc.value) || (0xAC00...0xD7A3).contains(sc.value)
        }
    }
}

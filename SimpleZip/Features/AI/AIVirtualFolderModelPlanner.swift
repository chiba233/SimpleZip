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

/// **文件浏览器单文件抽屉**的模型产出(②b/②c)。给一个具体文件出 {一句话摘要 + 几个建议动作 token}。
/// 扁平 2 字段(可靠优先);摘要给人看、动作从词表里挑。**拒绝假AI**:没有这个产出文件浏览器就空抽屉。
@available(macOS 26.0, *)
@Generable
struct GeneratedFileSuggestion: Sendable {
    @Guide(description: "ONE short, concrete sentence saying what THIS specific file actually is or is about — its real subject or purpose, the way the owner would describe it. Be specific to the content; do NOT just restate the file name, and do NOT write a generic line like 'a text document'. In the required language.")
    var summary: String
    @Guide(description: "A FEW action tokens from the allowed-actions list, ONLY where an action is clearly the right next step for THIS file. MOST files get NONE — empty is the correct default. Use each token verbatim; never invent one.")
    var actions: [String]
    @Guide(description: "If a list of alternative apps is given, the NUMBER of the ONE app that is CLEARLY a better fit for THIS file than the system default (e.g. a code editor for source/config/logs, a spreadsheet app for CSV/TSV data, a dedicated viewer). Use 0 when no list is given, or when no listed app is clearly better — 0 is the correct default for most files.")
    var openWithAppNumber: Int
}

/// **文件浏览器「文件折叠组建议」**的模型产出。模型把当前文件夹里的文件圈成几组「一组 + 一个批量动作」
/// (比如几个归档 → 一起测试;一堆发布物 → 一起算哈希)。**不是真分组引擎**,就是 AI 建议的折叠呈现:
/// 折叠行写「某文件 等 N 个 · 推荐X」,展开 = 那几个文件 + 末尾一条动作行。扁平 2 字段(可靠优先)。
@available(macOS 26.0, *)
@Generable
struct GeneratedFileGroupSuggestion: Sendable {
    @Guide(description: "The item NUMBERS (leftmost column) of the files that belong in THIS group — files the user would clearly want to apply the SAME batch action to together. At least 2 numbers.")
    var fileNumbers: [String]
    @Guide(description: "ONE action token from the allowed-actions list to apply to the whole group (e.g. compress, hash, test). Use a token whose 'applies to' kinds fit these files.")
    var action: String
}

@available(macOS 26.0, *)
@Generable
struct GeneratedFolderGroupSet: Sendable {
    @Guide(description: "A FEW groups of files in this folder that would CLEARLY benefit from the same batch action — ONLY where it is obviously useful. MOST folders need NONE; empty is the correct default. Never force unrelated files into a group.")
    var groups: [GeneratedFileGroupSuggestion]
}

/// **文件浏览器「磁盘镜像安装建议」**的模型产出(推荐打开方式 backlog 第2项)。给一个内含 App 的 `.dmg`,
/// 模型出 {一句话定性 + 是否建议安装}。扁平 2 字段(可靠优先)。**拒绝假AI**:确定性只负责「这个 dmg 里有 .app」,
/// 是否冒出建议 + 措辞由模型定。
@available(macOS 26.0, *)
@Generable
struct GeneratedDiskImageSuggestion: Sendable {
    @Guide(description: "ONE short, concrete sentence telling the owner what this disk image is: that it is the installer for the app(s) given to you, to be dragged into Applications to install. Use the app name(s) you were given; never invent or assume an app name. In the required language.")
    var summary: String
    @Guide(description: "True if you should actively suggest the user install the app from this disk image (drag it into Applications). For a normal app-installer disk image this is usually true; false only if it clearly is not something to install.")
    var suggestInstall: Bool
}

/// **「文件有活动」一句话提醒**的模型产出(backlog 第3项)。单字段,可靠。
@available(macOS 26.0, *)
@Generable
struct GeneratedActivityReminder: Sendable {
    @Guide(description: "ONE short, natural sentence reminding the owner of the recent action they took on this file and roughly when, so they know it has recent activity and can jump to it. Use ONLY the action and timeframe you were given; never invent extra detail. In the required language.")
    var reminder: String
}

/// **压缩包「你可能需要的文件」**的模型产出(backlog 第4项)。模型从包内文件清单里挑**少数几个**用户最可能想
/// 单独取出 / 预览的(按序号),大多数包一个都不挑。单字段,可靠。**拒绝假AI**:确定性只列出包里有什么,挑哪个由模型定。
@available(macOS 26.0, *)
@Generable
struct GeneratedArchiveEntryPicks: Sendable {
    @Guide(description: "The item NUMBERS of a FEW files inside this archive the user would most likely want to pull out or preview on their own — ONLY where a file CLEARLY stands out (e.g. a README, the main document, a config, an installer, the one obviously-important file). MOST archives need NONE; an empty list is the correct, common answer. Use only numbers that appear in the list; never invent one.")
    var pickedNumbers: [String]
}

/// **归档行内「这是什么包」**的模型产出。单字段,可靠。
@available(macOS 26.0, *)
@Generable
struct GeneratedArchiveKindGuess: Sendable {
    @Guide(description: "ONE short, concrete sentence describing what kind of archive this appears to be, based only on the listed paths and folder structure. Use the required language. Do not name or copy a specific product unless it is explicitly present in the archive name or entries.")
    var summary: String
}

/// **文本内真实 URL 打开建议**的模型产出。模型只能选 App 给的候选编号,不能输出 / 发明 URL。
@available(macOS 26.0, *)
@Generable
struct GeneratedURLSuggestion: Sendable {
    @Guide(description: "The NUMBER of the one URL that is genuinely worth showing as an 'open webpage' suggestion for this file. Use 0 when none is clearly useful. Choose only from the numbered URL list; never invent, rewrite, or output a URL.")
    var urlNumber: Int
}

/// 动态核查产出:**明显不扣题**、该从文件夹移除的条目序号(保守 —— 拿不准就不列)。扁平单字段,可靠。
@available(macOS 26.0, *)
@Generable
struct GeneratedVerification: Sendable {
    @Guide(description: "The item NUMBERS that CLEARLY do not belong to this folder's theme and should be removed. Only include items you are confident don't fit; when in doubt, leave it OUT of this list (keep it). Empty is fine — most items usually fit.")
    var removeNumbers: [String]
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
        The items below are already grouped into one folder. Suggest a useful next action for a FEW of them — ONLY \
        where there is a clear, specific reason for THAT SPECIFIC ITEM (e.g. an untested release archive → "test"; \
        a large stray folder → "compress"; an unverified signed container → "verify"). MOST items get NONE — empty \
        is the correct default. Never suggest an action just because it is possible; suggest only when it is clearly \
        the right next step for THIS item right now. Prioritize items that most obviously need attention. Refer to \
        items by their NUMBER, never output a path.

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

    /// **文件浏览器「文件折叠组建议」**的模型驱动产出(拒绝假AI)。给当前文件夹里的文件,让端上模型圈出几组
    /// 「一组文件 + 一个批量动作」(几个归档→一起测试、一堆发布物→一起算哈希…);大多数文件夹一组都没有。
    /// 模型按序号引用文件、按 token 选动作;App 回译成 (成员 candidateID 列表, 动作 token)。失败 / 空 → []。
    static func folderGroupSuggestions(items: [AIVirtualNodePromptCandidate])
        async throws -> [(memberIDs: [String], actionToken: String)] {
        guard items.count >= 2 else { return [] }
        let cands = Array(items.prefix(60))
        let instructions = """
        The items below are the files in ONE folder the user is looking at. Propose a FEW GROUPS of files that the \
        user would clearly want to apply the SAME batch action to together — e.g. several archives → "test"; many \
        distributable / release files → "hash"; a pile of large stray files → "compress". ONLY propose a group when \
        it is obviously useful; MOST folders need NONE — an empty list is the correct, common answer. Each group \
        needs at least 2 files. Never invent a number, never output a path; refer to files by their NUMBER only.

        \(Self.actionVocabularyRule)
        """
        var lines = ["Files (number<TAB>kind<TAB>name<TAB>roleTags) — refer to files by their number:"]
        for (i, c) in cands.enumerated() {
            lines.append(["\(i + 1)", c.kind, c.displayName, c.roleTags.joined(separator: " ")].joined(separator: "\t"))
        }
        let generated = try await AIReportAssistant.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedFolderGroupSet.self, maxAttempts: 8)
        var usedSignatures = Set<String>()
        return generated.groups.compactMap { g -> (memberIDs: [String], actionToken: String)? in
            let token = g.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard AIVirtualNodeActionDeriver.allowedSuggestionDescriptors.contains(where: { $0.id == token }) else { return nil }
            // 序号 → 真实 candidateID,去重;至少 2 个成员才算一组。
            var seen = Set<String>()
            let ids = g.fileNumbers.compactMap { realID($0, in: cands) }.filter { seen.insert($0).inserted }
            guard ids.count >= 2 else { return nil }
            // 同一批成员 + 同动作只留一组(模型偶发重复)。
            let signature = token + "|" + ids.sorted().joined(separator: ",")
            guard usedSignatures.insert(signature).inserted else { return nil }
            return (ids, token)
        }
    }

    /// **文件浏览器单文件抽屉**的模型驱动建议(②b/②c,拒绝假AI)。给一个具体文件(名字 + 角色 + 脱敏内容摘录 +
    /// 结构信号)让端上模型出**一句话摘要 + 几个建议动作 token**。摘要给人看(强制界面语言);动作只能从词表里挑、
    /// 且必须适用该 kind,App 据 token + 路径安全合成动作(模型不拼路径)。失败抛出由调用点吞掉。
    /// `excerpt` 必须是**已脱敏**的头部文本(调用方在后台线程读 + `AISensitiveRedactor.redact` 后传入)。
    static func fileSuggestion(fileName: String, kind: String, roleTags: [String], languageHint: String?,
                               headings: [String], fieldNames: [String], excerpt: String,
                               candidateOpenApps: [(bundleID: String, name: String)] = [],
                               discouragedTokens: [String] = [])
        async throws -> (summary: String, actions: [AIFileSuggestedAction]) {
        let lang = AIReportAssistant.uiLanguageName
        let apps = Array(candidateOpenApps.prefix(8))
        let discouraged = Array(Set(discouragedTokens.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })).sorted().prefix(12)
        let openWithRule = apps.isEmpty ? "" : """


        You are also given a list of OTHER apps installed that can open this file — the user's DEFAULT \
        double-click app is intentionally NOT in the list. Set openWithAppNumber to the number of an app ONLY \
        when it is CLEARLY a better fit for THIS file than the default; otherwise set it to 0. Default to 0 — \
        most files should just use their default app, so recommending a different app must be clearly worth it.
        """
        let feedbackHint = discouraged.isEmpty ? "" : """


        The user has repeatedly ignored these suggestion types here; only include them if clearly valuable: \
        \(discouraged.joined(separator: ", ")).
        """
        let instructions = """
        LANGUAGE — MANDATORY: write the summary in \(lang). Never use any other language for it, not even partially.

        You are describing ONE file to the person who owns it, inside a file manager. You are given the file's name, \
        its role, a few structural signals, and a redacted excerpt of its actual content. From the CONTENT, write \
        ONE concrete, specific sentence about what this file really is or is about — the kind of thing a person \
        would say to remind themselves what it is. Do not restate the file name, do not be generic, do not mention \
        that text was redacted. If the excerpt is too thin to say anything specific, summarize from the name and \
        role as best you can, still in one concrete sentence.

        Then suggest a FEW next actions, but ONLY where an action is clearly the right next step for THIS file. Most \
        files need NONE — empty is the correct default. Never suggest an action just because it is possible.\(openWithRule)\(feedbackHint)

        \(Self.actionVocabularyRule)
        """
        var lines: [String] = ["File name: \(fileName)", "Kind: \(kind)"]
        if !roleTags.isEmpty { lines.append("Role: \(roleTags.joined(separator: ", "))") }
        if let languageHint, !languageHint.isEmpty { lines.append("Format: \(languageHint)") }
        if !headings.isEmpty { lines.append("Headings: \(headings.prefix(8).joined(separator: " | "))") }
        if !fieldNames.isEmpty { lines.append("Top-level fields: \(fieldNames.prefix(12).joined(separator: ", "))") }
        let trimmedExcerpt = String(excerpt.prefix(1_400)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExcerpt.isEmpty { lines.append("Content excerpt (redacted):\n\(trimmedExcerpt)") }
        if !apps.isEmpty {
            lines.append("Other apps that can open this file (the default double-click app is NOT listed) — refer to an app by its number:")
            for (i, a) in apps.enumerated() { lines.append("\(i + 1)\t\(a.name)") }
        }
        let generated = try await AIReportAssistant.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedFileSuggestion.self, maxAttempts: 8)
        let summary = generated.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let tokens = generated.actions.compactMap { raw -> String? in
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard AIVirtualNodeActionDeriver.allowedSuggestionDescriptors
                .contains(where: { $0.id == t && $0.appliesToKinds.contains(kind) }),
                seen.insert(t).inserted else { return nil }
            return t
        }
        var actions = tokens.map { AIFileSuggestedAction(token: $0) }
        // 推荐打开方式(只推非默认 app):模型按序号挑一个明显更合适的非默认 App;App 据 bundleId 安全合成动作。
        let n = generated.openWithAppNumber
        if !apps.isEmpty, n >= 1, n <= apps.count {
            let app = apps[n - 1]
            actions.append(AIFileSuggestedAction(token: "openWith", payload: app.bundleID, label: app.name))
        }
        return (summary, actions)
    }

    /// **磁盘镜像安装建议**(推荐打开方式 backlog 第2项,拒绝假AI)。给一个内含 App 的 `.dmg`(名字 + 7zz 只读
    /// peek 出来的内部 .app 名),让端上模型出**一句话定性 + 是否建议安装**。App 据此在抽屉显示「安装 X」,点击打开
    /// (挂载)这个 dmg 让用户把 App 拖进「应用程序」(只读导航,绝不自动拷进 /Applications)。失败抛出由调用点吞掉。
    static func diskImageInstallSuggestion(dmgName: String, appNames: [String])
        async throws -> (summary: String, suggest: Bool) {
        let lang = AIReportAssistant.uiLanguageName
        let instructions = """
        LANGUAGE — MANDATORY: write the summary in \(lang). Never use any other language for it, not even partially.

        The user has a disk image (.dmg) that contains the macOS app(s) listed below. Write ONE concrete, specific \
        sentence telling them what this is — the kind of reminder a person would give themselves (e.g. the installer \
        for that app, to be dragged into Applications). Do not be generic. Then decide suggestInstall: true if \
        actively suggesting they install the app (drag it into Applications) is a useful next step, false if not.
        """
        let prompt = "Disk image: \(dmgName)\nApp(s) inside: \(appNames.prefix(4).joined(separator: ", "))"
        let generated = try await AIReportAssistant.generateStructured(
            instructions: instructions, prompt: prompt,
            as: GeneratedDiskImageSuggestion.self, maxAttempts: 8)
        return (generated.summary.trimmingCharacters(in: .whitespacesAndNewlines), generated.suggestInstall)
    }

    /// **「文件有活动」一句话提醒**(backlog 第3项,拒绝假AI)。一个文件被某任务产出(精确按产物路径匹配),让端上
    /// 模型用一句自然话提醒用户「最近对它做过什么 + 大致何时」,好跳活动中心看。**动作描述 + 时间文本由 App 给**
    /// (时间换算在代码做,模型不算时间);模型只把它们组织成界面语言的一句话。失败抛出由调用点吞掉。
    static func activityReminder(fileName: String, actionText: String, whenText: String) async throws -> String {
        let lang = AIReportAssistant.uiLanguageName
        let instructions = """
        LANGUAGE — MANDATORY: write the reminder in \(lang). Never use any other language for it, not even partially.

        Inside a file manager, the owner recently ran an operation that produced ONE file. Write ONE short, natural \
        sentence reminding them of that recent activity — what they did and roughly when — so they can jump to it in \
        the activity history. Use ONLY the action and timeframe you are given; be concise and concrete; do not invent \
        any extra detail and do not restate the file name verbatim.
        """
        let prompt = "File: \(fileName)\nRecent action: \(actionText)\nWhen: \(whenText)"
        let generated = try await AIReportAssistant.generateStructured(
            instructions: instructions, prompt: prompt, as: GeneratedActivityReminder.self, maxAttempts: 8)
        return generated.reminder.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// **压缩包「你可能需要的文件」**(backlog 第4项,拒绝假AI)。给一个归档的内部文件清单(只读清单缓存,不解压),
    /// 让端上模型挑**少数几个**用户最可能想单独取出 / 预览的(按序号)。返回挑中的 **1 基序号**(去重、合法、封顶 4);
    /// App 据序号回查真实条目路径(模型只挑不拼路径)。失败 / 空 → []。
    static func archiveEntryPicks(archiveName: String, entryPaths: [String]) async throws -> [Int] {
        guard !entryPaths.isEmpty else { return [] }
        let cands = Array(entryPaths.prefix(60))
        let instructions = """
        Below are the files inside ONE archive the user has. Pick a FEW (by number) that the user would most likely \
        want to pull out or preview on their own — ONLY where a file CLEARLY stands out (a README / the main document \
        / a config / an installer / the one obviously-important file). MOST archives need NONE; an empty list is the \
        correct, common answer. Never invent a number; refer to files only by their number.
        """
        var lines = ["Archive: \(archiveName)", "Files (number<TAB>path) — refer to files by their number:"]
        for (i, p) in cands.enumerated() { lines.append("\(i + 1)\t\(p)") }
        let generated = try await AIReportAssistant.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedArchiveEntryPicks.self, maxAttempts: 8)
        var seen = Set<Int>()
        return generated.pickedNumbers
            .compactMap { firstInt(in: $0) }
            .filter { $0 >= 1 && $0 <= cands.count && seen.insert($0).inserted }
            .prefix(4)
            .map { $0 }
    }

    /// **归档行内「这是什么包」**(拒绝假AI)。给一个归档的**非加密条目清单缓存**(文件/目录名 + 结构,不解压),
    /// 让端上模型据结构写一句定性。失败抛出由调用点吞掉;空摘要由调用点标记为已评估但不显示。
    static func archiveKindGuess(archiveName: String, entryNames: [(name: String, isDirectory: Bool)])
        async throws -> String {
        guard !entryNames.isEmpty else { return "" }
        let lang = AIReportAssistant.uiLanguageName
        let instructions = """
        LANGUAGE — MANDATORY: write the summary in \(lang). Never use any other language for it, not even partially.

        You are looking at the file and folder names inside ONE archive. Based only on those names and their folder \
        structure, write ONE short, concrete sentence describing what kind of archive this appears to be. Do not \
        claim certainty; say it appears to be something. Do not invent contents that are not supported by the paths. \
        Avoid naming a specific product or app unless that name is explicitly present in the archive name or entries.
        """
        var lines = ["Archive: \(archiveName)", "Entries (number<TAB>type<TAB>path):"]
        for (i, entry) in entryNames.enumerated() {
            let kind = entry.isDirectory ? "directory" : "file"
            lines.append("\(i + 1)\t\(kind)\t\(entry.name)")
        }
        let generated = try await AIReportAssistant.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedArchiveKindGuess.self, maxAttempts: 8)
        return generated.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// **文本里真实 URL 的打开建议**(拒绝假AI)。App 先从已脱敏预读文本里正则抽出真实 http(s) URL;模型只判断
    /// 其中哪一个值得展示,返回编号。失败 / 0 → 不写任何建议。模型不得输出或改写 URL。
    static func urlOpenSuggestion(fileName: String, roleTags: [String], urls: [String]) async throws -> Int? {
        guard !urls.isEmpty else { return nil }
        let cands = Array(urls.prefix(12))
        let instructions = """
        You are deciding whether a file manager should show an "open webpage" suggestion for ONE text file. The App \
        has already extracted REAL URLs from the file. Choose the ONE URL that is clearly useful for the owner to \
        open from this file — for example an official project page, release page, documentation, issue, download, \
        or other central reference. Use 0 if the URLs look incidental, tracking-like, too generic, or not worth \
        surfacing. Be strict: most files need no URL suggestion. Choose only by NUMBER from the list. Never invent, \
        rewrite, normalize, or output any URL. Do not mention or recommend any specific browser or app.
        """
        var lines = ["File: \(fileName)"]
        if !roleTags.isEmpty { lines.append("Role: \(roleTags.joined(separator: ", "))") }
        lines.append("Extracted URLs (number<TAB>url) — choose only by number:")
        for (i, url) in cands.enumerated() { lines.append("\(i + 1)\t\(url)") }
        let generated = try await AIReportAssistant.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedURLSuggestion.self, maxAttempts: 8)
        guard generated.urlNumber >= 1, generated.urlNumber <= cands.count else { return nil }
        return generated.urlNumber - 1
    }

    /// **文件「查看更长总结」**(backlog B,按需现算)。双击抽屉摘要行时弹窗实时生成 —— 比一句话短摘要更深:
    /// 一两句定性 + 几行要点。复用自由文本 `generate`(非结构化,产物给人读 / 可编辑)。红线照旧:只读**已脱敏**头部。
    static func longFileSummary(fileName: String, roleTags: [String], languageHint: String?,
                               headings: [String], excerpt: String) async throws -> String {
        let lang = AIReportAssistant.uiLanguageName
        let instructions = """
        LANGUAGE — MANDATORY: write the whole summary in \(lang). Never use any other language, not even partially.

        You are summarizing ONE file for the person who owns it, in more depth than a single line. From the CONTENT, \
        write a SHORT but substantive summary: one or two sentences on what this file really is, then a few concise \
        lines on its key points or structure. Be concrete and specific to THIS file's actual content — do not be \
        generic, do not restate the file name, do not mention that anything was redacted. If the excerpt is thin, \
        say what you reasonably can from the name and role. Keep it well under 200 words.
        """
        var lines = ["File name: \(fileName)"]
        if !roleTags.isEmpty { lines.append("Role: \(roleTags.joined(separator: ", "))") }
        if let languageHint, !languageHint.isEmpty { lines.append("Format: \(languageHint)") }
        if !headings.isEmpty { lines.append("Headings: \(headings.prefix(12).joined(separator: " | "))") }
        let trimmed = String(excerpt.prefix(3_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { lines.append("Content excerpt (redacted):\n\(trimmed)") }
        return try await AIReportAssistant.generate(instructions: instructions, prompt: lines.joined(separator: "\n"))
    }

    /// **动态核查**:对一个已成型文件夹的成员,让模型挑出**明显不扣题**的(保守 —— 拿不准就留)。返回要移除的
    /// 真实 candidateID 集合(App 据此从虚拟文件夹剔除,**不碰磁盘**)。失败 / 全扣题 → 返回空。
    static func verifyMisfits(theme: String, items: [AIVirtualNodePromptCandidate]) async throws -> Set<String> {
        guard !items.isEmpty else { return [] }
        let cands = Array(items.prefix(40))
        let instructions = """
        A folder collects items around ONE theme. Below is its theme and its current items (one per line: \
        "number<TAB>kind<TAB>name<TAB>roleTags"). List ONLY the NUMBERS of items that CLEARLY AND OBVIOUSLY do not \
        belong to this theme — items whose kind, name, AND roleTags all point away from the theme topic. Be \
        conservative: when in doubt, KEEP the item (do not list it). An empty list is correct most of the time — \
        most items usually fit. Never output a path; never remove an item just because its name is ambiguous.
        """
        var lines = ["Theme: \(theme)", "Items (number<TAB>kind<TAB>name<TAB>roleTags):"]
        for (i, c) in cands.enumerated() {
            lines.append(["\(i + 1)", c.kind, c.displayName, c.roleTags.joined(separator: " ")].joined(separator: "\t"))
        }
        let generated = try await AIReportAssistant.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedVerification.self, maxAttempts: 8)
        return Set(generated.removeNumbers.compactMap { realID($0, in: cands) })
    }

    /// 把用户对这个工作区的累积调教(固定 / 排除 / 喜欢 / 不喜欢 / 分组命名)展开成几行 prompt 提示(架构债 #4:
    /// 自循环喂进模型)。携带名字 / 来源目录 / 角色 / 用户起的组名 —— **路径不是隐私红线**(见隐私口径);空则返回空。
    static func hintLines(_ hints: AIWorkspaceLearningHints?) -> [String] {
        guard let h = hints, !h.isEmpty else { return [] }
        var lines: [String] = []
        if !h.removedItemNames.isEmpty {
            lines.append("Items the user REMOVED from here (name and location — do NOT bring back items like these): "
                + h.removedItemNames.prefix(24).joined(separator: ", "))
        }
        if !h.keptItemNames.isEmpty {
            lines.append("Items the user explicitly KEEPS here (name and location — favor selecting items like these): "
                + h.keptItemNames.prefix(24).joined(separator: ", "))
        }
        if !h.userGroupTitles.isEmpty {
            lines.append("Group names the user has chosen here (reuse and honor these names/themes when grouping): "
                + h.userGroupTitles.prefix(12).joined(separator: ", "))
        }
        if !h.rejectedRoleTags.isEmpty {
            lines.append("Kinds of item the user dislikes here: " + h.rejectedRoleTags.prefix(12).joined(separator: ", "))
        }
        if !h.preferredRoleTags.isEmpty {
            lines.append("Kinds of item the user likes here: " + h.preferredRoleTags.prefix(12).joined(separator: ", "))
        }
        return lines
    }

    /// 从 prompt-safe 输入让本地模型生成虚拟目录 plan。返回的 plan 的 candidateID 仍可能含界外值 ——
    /// 交给 `AIVirtualFolderTreeBuilder.build` 统一校验丢弃(防御性)。失败抛出,调用点退回确定性树。
    static func plan(for input: AIVirtualFolderPlanInput) async throws -> AIVirtualFolderPlan {
        let instructions = """
        \(Self.namingRule)

        You curate and organize a set of related items around a theme. Each item below is one line: \
        "number<TAB>kind<TAB>name<TAB>roleTags", where number is a small integer in the leftmost column. Using the \
        theme and hints, decide which items genuinely BELONG together and SELECT only those — leave out items that \
        don't fit (you are choosing membership, not forced to place everything). Then group the selected items by \
        what they ARE or their shared topic, give each group a short name (1–3 words), and propose a clear name for \
        the whole collection. Aim for 2–4 groups; prefer a small number of clear, well-named groups over many tiny \
        ones. Base everything ONLY on the names, kinds and roleTags given. Refer to each item by its NUMBER (the \
        leftmost column) — never output a file path; simply omit any item that doesn't belong rather than forcing it \
        into a group.

        If the input states items the user KEEPS or REMOVED, kinds they like/dislike, or group names they chose, \
        treat these as strong guidance: favor items like the ones they keep, leave out items like the ones they \
        removed, and reuse the group names/themes they picked. The item numbers are plain integers — use them \
        exactly as given, never translate them.
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
        \(Self.namingRule)

        You are a STRICT quality judge for a background "AI folder". Each item below is one line: \
        "number<TAB>kind<TAB>name<TAB>roleTags", where number is a small integer in the leftmost column. These items \
        were grouped only because they share a name token or a common task/archive — but a shared token is USUALLY \
        COINCIDENTAL (many unrelated files share a common word like "report", "final", "v2", "data" or a date). \
        Most such groups are NOT worth a folder.

        Set worthSurfacing = true ONLY when ALL of the following hold:
          (a) At least THREE items CLEARLY belong together for a real reason beyond a shared word
          (b) The theme is specific enough that a person would deliberately name and keep this folder
          (c) The items form a recognizable project, topic, dataset, or deliverable — not a loose grab-bag

        Set worthSurfacing = false when: fewer than three items truly relate; they merely share a generic/common \
        word; the theme is vague or weak; or it is a coincidental match. Be strict and skeptical: rejecting a \
        borderline theme is always safer than approving it.

        If you DO approve (worthSurfacing = true): curate the items — keep those that fit, drop the ones that only \
        coincidentally matched; group by meaning with short names (1–3 words); propose a clear name for the folder. \
        If you REJECT (worthSurfacing = false): set groups to [] and workspaceTitle to "".

        Refer to items by their NUMBER (the leftmost column) — never invent a number, output a file path, or \
        translate names. The item numbers are plain integers — use them exactly as given. Reply only with the \
        structured plan, including worthSurfacing.

        If the input states items the user KEEPS or REMOVED, kinds they like/dislike, or group names they chose, \
        treat these as strong guidance: a theme the user has actively curated is more worth surfacing, and you \
        should honor what they keep, leave out, and how they name groups.
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

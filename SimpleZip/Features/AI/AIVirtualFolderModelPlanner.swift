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
    @Guide(description: "A FEW action tokens from the allowed-actions list, ONLY where an action is clearly the right next step for THIS file (e.g. a finished deliverable someone would share can warrant 'hash'; a large document to send can warrant 'compress'). Empty is correct when nothing clearly fits. Use each token verbatim; never invent one.")
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

/// **文件夹「整理进新文件夹」建议**的模型产出(Task 7)。模型看当前文件夹的文件清单,**只有**当其中明显有一簇
/// 同类文件值得归进一个新子文件夹时,才给 {值不值得 + 主题文件夹名 + 成员序号}。**拒绝假AI**:确定性只提供候选
/// 文件清单,是否建议 / 起什么名 / 圈哪些全由模型定;不值得就 worthOrganizing=false。扁平 3 字段(可靠优先)。
@available(macOS 26.0, *)
@Generable
struct GeneratedOrganizeSuggestion: Sendable {
    @Guide(description: "True ONLY if a CLEAR subset of these files obviously belongs together and tidying just that subset into one new sub-folder would plainly help (e.g. a pile of screenshots, a set of invoices, the photos from one trip). False if the folder is already tidy, the files are unrelated, or any grouping would be arbitrary — most folders should be false. Be strict.")
    var worthOrganizing: Bool
    @Guide(description: "A short, human folder name for the cluster, by what the files ARE or their shared topic (e.g. 'Screenshots', 'Invoices', 'Trip Photos'). 1-3 words, in the required language. No path, no slashes, no meta words like 'folder', 'files', 'AI' or 'group'.")
    var folderName: String
    @Guide(description: "The item NUMBERS (leftmost column) of the files that clearly share the theme and should move into the new folder — at least 3. Use only numbers that appear in the list; never invent one. Include ONLY files that truly fit; leave the rest out.")
    var fileNumbers: [String]
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
    @Guide(description: "A FEW action tokens worth proactively suggesting for THIS archive, or empty. Allowed tokens only: 'test' (verify the archive is not corrupt — a safe read-only check that works on ANY supported archive format, so it fits essentially any archive worth keeping intact), 'security' (scan entries for unsafe / suspicious paths before extracting — applies to ANY archive, offer it broadly, especially for downloads or archives with executables), 'inspect' (a release-readiness / contents inspection — for any archive that is software or a package meant to be shipped: an app, a disk image, an installer, executables, a bin/ or dist/ tree, or a versioned release), 'hash' (compute a checksum — like inspect, for that same kind of release package or distributable: an app, disk image, installer, executables, bin/ or dist/ tree, or versioned release, that someone might share and verify), 'convert' (ONLY when the current format is clearly suboptimal for the likely next step, e.g. a .tar.gz better repacked as .7z — never just because conversion is possible). test and security are NOT limited to release packages; inspect and hash are for release packages / distributables. Use each token verbatim; never invent one.")
    var actions: [String]
}

/// **活动中心「建议筛选」chip 的排序/精选**模型产出(建议六 v2 模块⑤)。模型只按**编号**挑出最有用的几个并排序,
/// 绝不发明 filter —— App 安全枚举候选 chip,这里只对它们排序。扁平单字段(短序号,可靠优先;见短序号教训)。
@available(macOS 26.0, *)
@Generable
struct GeneratedChipRanking: Sendable {
    @Guide(description: "The chip NUMBERS (the leftmost column of the chip list) in priority order — MOST USEFUL FIRST. Include ONLY the chips genuinely worth showing to the user; drop redundant, near-duplicate or low-value ones. Prefer chips that surface actionable failures the user likely cares about. Use only numbers that appear in the list; never invent one.")
    var orderedNumbers: [String]
}

/// **活动中心「真建议」聚集命名**模型产出(建议六 v2 真建议 chip)。App 已确定性发现真实失败聚集,模型只在这些
/// 真实聚集上**择优 + 起自然语言名**(不发明聚集)。扁平单字段 [String](避嵌套 schema;短序号教训),每条
/// "<编号>: <名字>" —— 编号引用候选列表,名字是界面语言的短标签。
@available(macOS 26.0, *)
@Generable
struct GeneratedClusterNaming: Sendable {
    @Guide(description: "The clusters worth showing, each as \"<number>: <name>\" — <number> is the cluster's number from the list, <name> is a SHORT, concrete natural-language label a user recognizes (in the UI language), e.g. \"Finder extractions that failed\". Include ONLY clusters genuinely worth showing; drop redundant or low-value ones. Use only numbers from the list; never invent one. At most 6 entries.")
    var labeledClusters: [String]
}

/// **文本内真实 URL 打开建议**的模型产出。模型只能选 App 给的候选编号,不能输出 / 发明 URL。
@available(macOS 26.0, *)
@Generable
struct GeneratedURLSuggestion: Sendable {
    @Guide(description: "The NUMBER of the one URL that is genuinely worth showing as an 'open webpage' suggestion for this file. Use 0 when none is clearly useful. Choose only from the numbered URL list; never invent, rewrite, or output a URL.")
    var urlNumber: Int
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
            as: GeneratedFolderGroupSet.self, maxAttempts: 3)
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

    /// **文件夹「整理进新文件夹」建议**的模型驱动产出(Task 7,拒绝假AI)。给当前文件夹里的文件,让端上模型判断
    /// 是否有一簇同类文件值得归进一个新子文件夹,并起主题名 + 圈成员。大多数文件夹返回 nil(不值得 / 没明显簇)。
    /// 模型按序号引用文件;App 回译成 (主题名, 成员 candidateID 列表)。至少 3 个成员才成立。**不值得 → nil**;
    /// 模型失败 → 抛出由调用点吞掉(下轮可重试)。`maxAttempts:3` 与其它扁平后台 pass 一致(队列收敛 `4fd1fcad`)。
    static func organizeSuggestion(items: [AIVirtualNodePromptCandidate]) async throws
        -> (folderName: String, memberIDs: [String])? {
        guard items.count >= 3 else { return nil }
        let cands = Array(items.prefix(80))
        let instructions = """
        The items below are the files currently in ONE folder the user is looking at. If — and ONLY if — a clear \
        SUBSET of them obviously belongs together under a single new sub-folder (e.g. a pile of screenshots, a set \
        of invoices, the photos from one trip), propose tidying just that subset into a new folder you name. This \
        is real, obvious housekeeping the user would thank you for — NOT inventing an organization scheme. MOST \
        folders are already fine: when nothing clearly stands out, set worthOrganizing to false. Never force \
        unrelated files together. Name the folder by the real shared topic in \(AIReportAssistant.uiLanguageName); \
        never use meta words like "folder", "files", "AI" or "group". Refer to files by their NUMBER only; never \
        output a path.
        """
        var lines = ["Files (number<TAB>kind<TAB>name<TAB>roleTags) — refer to files by their number:"]
        for (i, c) in cands.enumerated() {
            lines.append(["\(i + 1)", c.kind, c.displayName, c.roleTags.joined(separator: " ")].joined(separator: "\t"))
        }
        let generated = try await AIReportAssistant.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedOrganizeSuggestion.self, maxAttempts: 3)
        guard generated.worthOrganizing else { return nil }
        let name = generated.folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var seen = Set<String>()
        let ids = generated.fileNumbers.compactMap { realID($0, in: cands) }.filter { seen.insert($0).inserted }
        guard ids.count >= 3 else { return nil }
        return (name, ids)
    }

    /// **活动中心 AI 工作台「现在最值得先处理什么 + 为什么」解读**(建议六 v2,拒绝假AI)。喂当前任务切片的结构化
    /// 事实(数量分布 + 未读失败任务的 **类型 / 来源 / 诊断标签**,**绝不含原始标题 / 路径**)→ 端上模型用界面语言写
    /// 一小段解读。确定性卡片永远是 fallback;模型不可用 / 失败 / 空返 → 调用点退回确定性文案。
    static func activityWorkbenchExplanation(summaryFacts: [String], failedFacts: [String]) async throws -> String {
        let lang = AIReportAssistant.uiLanguageName
        let instructions = """
        LANGUAGE — MANDATORY: write in \(lang). You are the AI panel inside a file-archive app's Activity Center. \
        Given a summary of the current task list and a few of the most important UNSEEN FAILED tasks (only their \
        type, source, and diagnostic tags — never file names or paths), write ONE short, concrete paragraph saying \
        what is most worth dealing with right now and why. Be specific to the failures given; never invent a task; \
        do not list everything; at most 2-3 sentences. If nothing clearly stands out, say the task list looks healthy.
        """
        var lines = ["Task summary (counts): \(summaryFacts.joined(separator: ", "))"]
        if !failedFacts.isEmpty {
            lines.append("Top unseen failed tasks (type / source / diagnostic tags):")
            lines.append(contentsOf: failedFacts.prefix(8))
        }
        return try await AIReportAssistant.generate(instructions: instructions, prompt: lines.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// **活动中心 AI 工作台「失败解释」模块**(建议六 v2 模块①,拒绝假AI)。用户展开某个失败任务时,喂它**已脱敏**的
    /// 类型 / 来源 / 诊断标签 / 失败消息 / 错误行(`AITaskRecord` 里都过了 `AISensitiveRedactor`,**不含原始路径**)→
    /// 端上模型用界面语言写 1-2 句「大概哪里出错、该看什么」。确定性脱敏摘要永远是 fallback;模型不可用 / 失败 / 空返 →
    /// 调用点退回脱敏摘要。**完整解释**走现成的 per-task `AIAssistSheet`(`failureExplanationPrompt`),不在这里。
    static func taskFailureShortExplanation(kind: String, source: String, tags: [String],
                                            failureMessage: String?, errorLines: [String]) async throws -> String {
        let lang = AIReportAssistant.uiLanguageName
        let instructions = """
        LANGUAGE — MANDATORY: write in \(lang). You are the AI panel inside a file-archive app's Activity Center. \
        A task FAILED and the user just opened it. Given the task type, source, diagnostic tags and a redacted \
        failure message / error lines (already stripped of file paths), write ONE or TWO short sentences in plain \
        language: what most likely went wrong and what to check or try next. Be specific to the diagnostics given; \
        never invent details; do not repeat the raw error verbatim; at most 2 sentences.
        """
        var lines = ["Failed task — type: \(kind), source: \(source), tags: \(tags.isEmpty ? "none" : tags.joined(separator: "+"))"]
        if let failureMessage, !failureMessage.isEmpty {
            lines.append("Redacted failure message: \(failureMessage)")
        }
        if !errorLines.isEmpty {
            lines.append("Redacted error lines:")
            lines.append(contentsOf: errorLines.prefix(6))
        }
        return try await AIReportAssistant.generate(instructions: instructions, prompt: lines.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// **活动中心「建议筛选」chip 的模型排序/精选**(建议六 v2 模块⑤,拒绝假AI)。**App 安全枚举候选 chip**(每个 chip
    /// 都是预定义的安全 filter);模型只**按编号挑出最值得展示的几个并排序**(最有用在前),绝不发明新 filter。喂 编号 +
    /// 英文语义描述(chip 选什么)+ 匹配数;返回**有序编号子集**(1-based,引用候选列表);调用点回译成 chip id。
    /// 候选 < 2 不必排;不可用 / 失败 / 空返 → 调用点退回确定性顺序。短序号(非长 chip id)保证小模型可靠。
    static func rankWorkbenchFilterChips(candidates: [(label: String, matches: Int)]) async throws -> [Int] {
        guard candidates.count >= 2 else { return [] }
        let capped = Array(candidates.prefix(20))
        let instructions = """
        You are ranking SUGGESTED FILTER chips for a file-archive app's Activity Center (output is not user-facing \
        text — return chip numbers only). Each chip is a safe, predefined filter over the user's task list. Given the \
        chips (number, what they select, how many tasks match), return the chip NUMBERS in priority order — MOST \
        USEFUL FIRST — keeping ONLY the chips genuinely worth showing and dropping redundant or low-value ones. Prefer \
        chips that surface actionable failures the user likely cares about; avoid near-duplicates. Refer to chips by \
        their NUMBER only; never invent a number.
        """
        var lines = ["Chips (number<TAB>selects<TAB>matchCount):"]
        for (i, c) in capped.enumerated() {
            lines.append(["\(i + 1)", c.label, "\(c.matches)"].joined(separator: "\t"))
        }
        let generated = try await AIReportAssistant.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedChipRanking.self, maxAttempts: 3)
        var seen = Set<Int>()
        return generated.orderedNumbers
            .compactMap { firstInt(in: $0) }
            .filter { $0 >= 1 && $0 <= capped.count && seen.insert($0).inserted }
    }

    /// **活动中心「真建议」聚集命名/择优**(建议六 v2,拒绝假AI)。App 确定性发现的**真实失败聚集**(任意维度交叉)
    /// 喂给模型 编号 + 维度描述 + 命中数;模型挑最值得展示的几个、用界面语言起短名字。返回 `[(候选编号, 名字)]`
    /// (1-based 引用候选列表);编号越界 / 名字空 → 丢弃。**模型不发明聚集**(只在给定真实聚集里选 + 命名)。
    static func nameWorkbenchClusters(candidates: [(facts: [String], matches: Int)]) async throws -> [(index: Int, name: String)] {
        guard !candidates.isEmpty else { return [] }
        let capped = Array(candidates.prefix(20))
        let lang = AIReportAssistant.uiLanguageName
        let instructions = """
        LANGUAGE — MANDATORY: write the names in \(lang). You are labeling SUGGESTED FILTERS for a file-archive \
        app's Activity Center. Each candidate is a REAL cluster of tasks the app already found by crossing \
        source / type / diagnostic / time dimensions — some are failure groups, some are common operation groups \
        (e.g. all compress tasks, tasks from Downloads). You do NOT invent clusters, only label the ones given, \
        and the dimensions tell you what each one selects (a "status=failed" dimension means it's a failure group; \
        no status means all states). Pick the few MOST worth showing and give each a SHORT, concrete name the user \
        would recognize. Drop redundant or low-value ones. Refer to clusters by their NUMBER only; never invent a number.
        """
        var lines = ["Clusters (number<TAB>dimensions<TAB>matchCount):"]
        for (i, c) in capped.enumerated() {
            lines.append(["\(i + 1)", c.facts.joined(separator: "+"), "\(c.matches)"].joined(separator: "\t"))
        }
        let generated = try await AIReportAssistant.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedClusterNaming.self, maxAttempts: 3)
        var seen = Set<Int>()
        var out: [(index: Int, name: String)] = []
        for entry in generated.labeledClusters {
            guard let n = firstInt(in: entry), n >= 1, n <= capped.count, seen.insert(n).inserted else { continue }
            // "<编号>: <名字>" / "<编号>：<名字>" —— 取分隔符后的名字;无分隔或名字空则跳过(别把编号当名字)。
            guard let sep = entry.range(of: ":") ?? entry.range(of: "：") else { continue }
            let name = entry[sep.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            out.append((n, name))
        }
        return out
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
        // 阶段3:prompt 构建 + 模型在引擎进程跑(actionVocabularyRule 由 App 据 Core 词表拼好传入,XPC Service 无需链 Core);
        // **token 词表校验 + AIFileSuggestedAction 拼装留 App**(依赖 Core 的动作词表 / kind 适用 / openWith 合成)。
        let apps = Array(candidateOpenApps.prefix(8))
        let input = FileSuggestionInput(
            fileName: fileName, kind: kind, roleTags: roleTags, languageHint: languageHint,
            headings: headings, fieldNames: fieldNames, excerpt: excerpt,
            candidateOpenApps: apps.map { FileSuggestionInput.AppCandidate(bundleID: $0.bundleID, name: $0.name) },
            discouragedTokens: discouragedTokens, actionVocabularyRule: Self.actionVocabularyRule)
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
            as: GeneratedDiskImageSuggestion.self, maxAttempts: 3)
        return (generated.summary.trimmingCharacters(in: .whitespacesAndNewlines), generated.suggestInstall)
    }

    /// **「文件有活动」一句话提醒**(backlog 第3项,拒绝假AI)。一个文件被某任务产出(精确按产物路径匹配),让端上
    /// 模型用一句自然话提醒用户「最近对它做过什么 + 大致何时」,好跳活动中心看。**动作描述 + 时间文本由 App 给**
    /// (时间换算在代码做,模型不算时间);模型只把它们组织成界面语言的一句话。失败抛出由调用点吞掉。
    // activityReminder 已迁进 agent+XPC 引擎(AIPassEngine.activityReminder),连 @Generable GeneratedActivityReminder
    // 一起搬走;App 经 AIAgentClient.generatePass(.activityReminder) 调。

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
            as: GeneratedArchiveEntryPicks.self, maxAttempts: 3)
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
        async throws -> (summary: String, toolTokens: [String]) {
        guard !entryNames.isEmpty else { return ("", []) }
        let lang = AIReportAssistant.uiLanguageName
        let instructions = """
        LANGUAGE — MANDATORY: write the summary in \(lang). Never use any other language for it, not even partially.

        You are looking at the file and folder names inside ONE archive. Based only on those names and their folder \
        structure, write ONE short, concrete sentence describing what kind of archive this appears to be. Do not \
        claim certainty; say it appears to be something. Do not invent contents that are not supported by the paths. \
        Avoid naming a specific product or app unless that name is explicitly present in the archive name or entries.

        Then suggest proactive action tokens for this archive (verbatim, from this exact list). test and security are \
        SAFE, read-only checks that work on EVERY supported archive format — they are NOT limited to release packages, \
        so do not withhold them just because this is an ordinary archive. inspect and hash apply to release packages / \
        distributables (defined below).
        test — verify the archive is not corrupt. It works on any supported format, so it fits essentially ANY archive \
        worth keeping intact (a download, a backup, a release — anything the user would not want silently corrupted).
        security — scan the entries for unsafe or suspicious paths before extracting (parent-directory escapes, \
        absolute paths, executables, scripts). Checking before extraction is sensible for almost ANY archive, so offer \
        it broadly — especially for anything downloaded or containing executables.
        inspect — a release-readiness / contents inspection. Fits ANY archive that is software or a package meant to \
        be shipped: an app, a disk image (.dmg), an installer (.pkg / .msi / .exe), executables, a bin/ or dist/ tree, \
        or a versioned release.
        hash — compute a checksum. Like inspect, offer it for that same kind of release package or distributable (an \
        app, a disk image, an installer, executables, a bin/ or dist/ tree, a versioned release) — the things someone \
        would share and another person might verify.
        convert — ONLY when the current format is clearly suboptimal for the user's likely next step (e.g. a .tar.gz \
        that would repack smaller as .7z, or an old .zip to repack). Never suggest merely because conversion is possible.
        Return an empty list only for a trivial, throwaway archive where even a quick safe check would add nothing.
        """
        // 🔴 防崩溃:端上模型上下文有限,大归档上千条目会撑爆 → FoundationModels 修剪 transcript 时**越界 trap**
        // (用户实测崩溃栈;心跳让本 pass 真跑后暴露)。按「条目数 + 字符预算」双重封顶挑代表性条目、单条路径也截断
        // —— 定性一个包不需要喂全清单(其它 pass 早已封顶:excerpt 1400 / urls 12 / entryPaths 50 / candidates 60)。
        var lines = ["Archive: \(archiveName)", "Entries (number<TAB>type<TAB>path):"]
        var promptBudget = 6_000
        for (i, entry) in entryNames.enumerated() {
            if i >= 200 || promptBudget <= 0 { break }
            let kind = entry.isDirectory ? "directory" : "file"
            let name = String(entry.name.prefix(160))
            lines.append("\(i + 1)\t\(kind)\t\(name)")
            promptBudget -= name.count + 12
        }
        let generated = try await AIReportAssistant.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedArchiveKindGuess.self, maxAttempts: 3)
        // 只接受适用归档的工具 token(去重);其余忽略 —— 模型选,代码不拼。
        let allowed: Set<String> = ["inspect", "test", "hash", "convert", "security"]
        var seen = Set<String>()
        let tokens = generated.actions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { allowed.contains($0) && seen.insert($0).inserted }
        return (generated.summary.trimmingCharacters(in: .whitespacesAndNewlines), tokens)
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
            as: GeneratedURLSuggestion.self, maxAttempts: 3)
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
        // 阶段3:整条 pass(拼 prompt + 模型 + 序号回查 candidateID)在 XPC 引擎跑(AIPassEngine.workspaceVerifyMisfits);
        // App 拼 Core 输入 DTO、收要移除的 candidateID 列表转 Set。失败抛出由调用点吞掉(退回不剔除)。
        let ids = try await AIAgentClient.generatePass(
            kind: .workspaceVerifyMisfits,
            input: WorkspaceVerifyMisfitsInput(theme: theme, items: items),
            as: [String].self)
        return Set(ids)
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

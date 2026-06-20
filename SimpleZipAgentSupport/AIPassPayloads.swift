//
//  AIPassPayloads.swift
//  SimpleZipAgentSupport(App + SimpleZipAIAgent + SimpleZipAIXPCService 三 target 共编)
//
//  独立 AI 进程改造 · 阶段3 · **AI pass 跨进程的 Codable DTO + 种类标识**。
//
//  阶段3 把「整条模型 pass(拼 prompt + 调模型 + 解析结果)」搬进只编进 agent+XPC 的引擎层(AIPassEngine),
//  App 退成薄客户端:拼输入 DTO → 经 XPC `generate(kind:inputJSON:...)` 调 → 收输出 DTO。这些 DTO 必须三 target
//  共享(App 拼/引擎解码输入;引擎产/App 解码输出)→ 放这里。早期 pass 只用基本类型(与 AIAgentConfiguration 同层);
//  workspace pass(AI 文件夹/建议)直接吃 **Core 的 Codable 富类型**(AIVirtualNodePromptCandidate / AIVirtualFolderPlanInput
//  等)—— 三 target 现都把 SimpleZip/Core 当 synced 源直编、Core 类型同 module 可见,故 DTO 可引用它们而无需镜像一套
//  基本类型(A2:不为跨进程白造 DTO 镜像)。@Generable 结构化类型仍留引擎层(FoundationModels,不跨 XPC)。
//
//  语言:pass 输出语言原取 App 的 `AIReportAssistant.uiLanguageName`;引擎在 agent/XPC 进程里没有 App locale,
//  故**界面语言由调用方(App)随每次 generate 传入** `languageName`,引擎据此拼 prompt —— 引擎本身 locale 无关。
//

import Foundation

/// AI pass 种类(XPC `generate(kind:)` 派发用)。App 与引擎按 rawValue 对齐;新增 pass = 加一个 case。
public enum AIPassKind: String, Sendable {
    /// 活动中心失败任务「失败解释」(纯文本,输入脱敏诊断,输出一两句解释)。
    case taskFailureShortExplanation
    /// 活动中心「需要处理」AI 解读(纯文本,输入任务计数 + 脱敏失败事实,输出一小段「现在最该处理什么」)。
    case activityWorkbenchExplanation
    /// 文件「查看更长总结」实时按需现算(纯文本,输入名/角色/语言/标题/脱敏摘录,输出一小段更长总结)。
    case longFileSummary
    /// 通用「报告解释 / 文档起草」散文生成(纯文本)。所有报告类 AI —— 发布检查 / 安全分级 / 验签 / 空间分析 /
    /// 元数据 / 救援 / 近似重复 / 创建·解压速览 / VERIFY·Release 起草 / 自动化点子… —— 经 `AIReportAssistant.generate`
    /// 这一个中心方法,共用此 pass(输入是 App 拼好的 instructions+prompt,回复语言由引擎据 languageName 注入)。
    case reportText
    /// 文件「有活动」提醒(结构化,输入名/动作/时间,输出一句提醒短语)。
    case activityReminder
    /// 活动中心「建议筛选」chip 模型排序(结构化,输入 chip 候选,输出有序编号子集)。
    case rankWorkbenchFilterChips
    /// 活动中心「真建议」聚集命名(结构化,输入真实聚集候选,输出 [编号:名字])。
    case nameWorkbenchClusters
    /// 压缩包「你可能需要的文件」(结构化,输入包名 + 条目路径,输出挑中的 1 基序号)。
    case archiveEntryPicks
    /// 归档「这是什么包」定性(结构化,输入包名 + 条目名/类型,输出一句定性 + 工具 token)。
    case archiveKindGuess
    /// 文本里真实 URL「打开网页」(结构化,输入名/角色/URL 列表,输出选中 0 基下标或 -1)。
    case urlOpenSuggestion
    /// 磁盘镜像「安装到应用程序」(结构化,输入 dmg 名 + 内含 App 名,输出一句定性 + 是否建议安装)。
    case diskImageInstallSuggestion
    /// 文件浏览器单文件抽屉建议(结构化,输入名/类型/角色/结构/脱敏摘录/候选App,输出一句摘要 + 动作 token + 推荐App编号)。
    case fileSuggestion
    /// AI 文件夹/建议「核查不扣题成员」(结构化,输入主题 + 候选条目,输出要移除的 candidateID 列表)。
    /// 吃 Core 富类型 AIVirtualNodePromptCandidate —— XPC Service 已链 Core,引擎可直接跨 XPC 解码。
    case workspaceVerifyMisfits
    /// AI 文件夹/建议「单条目动作建议」(结构化,输入候选条目,输出每条 = candidateID + 动作 token)。
    case workspaceNodeSuggestions
    /// 文件浏览器「文件折叠组建议」(结构化,输入文件候选,输出几组「成员 + 批量动作 token」)。
    case workspaceFolderGroups
    /// 文件夹「整理进新文件夹」建议(结构化,输入文件候选,输出主题名 + 成员;不值得 → null)。
    case workspaceOrganize
    /// AI 文件夹「生成虚拟目录 plan」(结构化,输入 AIVirtualFolderPlanInput,输出 AIVirtualFolderPlan)。
    case workspacePlan
    /// AI 文件夹「后台复核(值不值得 + plan)」(结构化,输入 AIVirtualFolderPlanInput,输出 AIFolderReview)。
    case workspaceReview
}

// MARK: - 输入 DTO(App 拼 / 引擎解码)

/// 「失败任务短解释」输入:**已脱敏**的类型 / 来源 / 标签 / 失败消息 / 错误行(App 侧已过 AISensitiveRedactor,
/// 不含原始路径)。引擎据此拼 prompt 调模型。
public nonisolated struct TaskFailureExplanationInput: Codable, Sendable {
    public var kind: String
    public var source: String
    public var tags: [String]
    public var failureMessage: String?
    public var errorLines: [String]
    public init(kind: String, source: String, tags: [String], failureMessage: String?, errorLines: [String]) {
        self.kind = kind
        self.source = source
        self.tags = tags
        self.failureMessage = failureMessage
        self.errorLines = errorLines
    }
}

/// 「需要处理」解读输入:任务计数事实(total/running/unseen-failed…)+ 少量**已脱敏**失败事实(类型/来源/诊断标签,
/// 不含原始标题/路径)。引擎据此拼 prompt 写「现在最该处理什么 + 为什么」。
public nonisolated struct ActivityWorkbenchExplanationInput: Codable, Sendable {
    public var summaryFacts: [String]
    public var failedFacts: [String]
    public init(summaryFacts: [String], failedFacts: [String]) {
        self.summaryFacts = summaryFacts
        self.failedFacts = failedFacts
    }
}

/// 「更长总结」输入:文件名 / 角色标签 / 语言提示 / 标题 + **已脱敏**内容摘录(App 侧已过红线 + AISensitiveRedactor)。
public nonisolated struct LongFileSummaryInput: Codable, Sendable {
    public var fileName: String
    public var roleTags: [String]
    public var languageHint: String?
    public var headings: [String]
    public var excerpt: String
    public init(fileName: String, roleTags: [String], languageHint: String?, headings: [String], excerpt: String) {
        self.fileName = fileName
        self.roleTags = roleTags
        self.languageHint = languageHint
        self.headings = headings
        self.excerpt = excerpt
    }
}

/// 通用「报告文本」输入:App 拼好的 instructions + prompt(报告类只读事实;非加密路径登录用户本可见,
/// prompt 永不含加密内容 / GPG 密文 / 口令 / 解密明文 —— 脱敏责任在 App 拼 prompt 时)。引擎据 languageName 注入回复语言。
public nonisolated struct ReportTextInput: Codable, Sendable {
    public var instructions: String
    public var prompt: String
    public init(instructions: String, prompt: String) {
        self.instructions = instructions
        self.prompt = prompt
    }
}

/// 「文件有活动」提醒输入:文件名 + 中性英文动作描述 + 粗略时间(都已是确定性派生的安全 token,不含路径)。
public nonisolated struct ActivityReminderInput: Codable, Sendable {
    public var fileName: String
    public var actionText: String
    public var whenText: String
    public init(fileName: String, actionText: String, whenText: String) {
        self.fileName = fileName
        self.actionText = actionText
        self.whenText = whenText
    }
}

/// 「建议筛选」chip 排序输入:每个 chip 候选 = 语义标签 + 命中数。引擎据此让模型按编号排序。
public nonisolated struct WorkbenchChipRankingInput: Codable, Sendable {
    public nonisolated struct Candidate: Codable, Sendable {
        public var label: String
        public var matches: Int
        public init(label: String, matches: Int) { self.label = label; self.matches = matches }
    }
    public var candidates: [Candidate]
    public init(candidates: [Candidate]) { self.candidates = candidates }
}

/// 「真建议」聚集命名输入:每个聚集候选 = 维度描述事实 + 命中数。引擎让模型按编号挑 + 起短名。
public nonisolated struct WorkbenchClusterNamingInput: Codable, Sendable {
    public nonisolated struct Candidate: Codable, Sendable {
        public var facts: [String]
        public var matches: Int
        public init(facts: [String], matches: Int) { self.facts = facts; self.matches = matches }
    }
    public var candidates: [Candidate]
    public init(candidates: [Candidate]) { self.candidates = candidates }
}

/// 压缩包「你可能需要的文件」输入:包名 + 内部文件路径(只读清单缓存,不解压)。
public nonisolated struct ArchiveEntryPicksInput: Codable, Sendable {
    public var archiveName: String
    public var entryPaths: [String]
    public init(archiveName: String, entryPaths: [String]) {
        self.archiveName = archiveName; self.entryPaths = entryPaths
    }
}

/// 归档「这是什么包」输入:包名 + 条目名/类型(非加密清单,不解压)。
public nonisolated struct ArchiveKindGuessInput: Codable, Sendable {
    public nonisolated struct Entry: Codable, Sendable {
        public var name: String
        public var isDirectory: Bool
        public init(name: String, isDirectory: Bool) { self.name = name; self.isDirectory = isDirectory }
    }
    public var archiveName: String
    public var entries: [Entry]
    public init(archiveName: String, entries: [Entry]) { self.archiveName = archiveName; self.entries = entries }
}

/// 文本 URL「打开网页」输入:文件名 + 角色 + App 已抽出的**真实** URL 列表(模型只选编号、不发明/改写 URL)。
public nonisolated struct URLOpenSuggestionInput: Codable, Sendable {
    public var fileName: String
    public var roleTags: [String]
    public var urls: [String]
    public init(fileName: String, roleTags: [String], urls: [String]) {
        self.fileName = fileName; self.roleTags = roleTags; self.urls = urls
    }
}

/// 磁盘镜像「安装到应用程序」输入:dmg 名 + 7zz 只读 peek 出的内部 .app 名。
public nonisolated struct DiskImageSuggestionInput: Codable, Sendable {
    public var dmgName: String
    public var appNames: [String]
    public init(dmgName: String, appNames: [String]) { self.dmgName = dmgName; self.appNames = appNames }
}

/// 文件浏览器单文件抽屉建议输入。`actionVocabularyRule` = App 据 Core 的动作词表拼好的规则串(引擎不依赖 Core
/// 即可拼 prompt → **XPC Service 无需链 Core**);`candidateOpenApps` 仅供模型按编号挑推荐 App(App 据编号回查)。
/// `excerpt` 必须**已脱敏**(调用方后台读 + AISensitiveRedactor)。
public nonisolated struct FileSuggestionInput: Codable, Sendable {
    public nonisolated struct AppCandidate: Codable, Sendable {
        public var bundleID: String
        public var name: String
        public init(bundleID: String, name: String) { self.bundleID = bundleID; self.name = name }
    }
    public var fileName: String
    public var kind: String
    public var roleTags: [String]
    public var languageHint: String?
    public var headings: [String]
    public var fieldNames: [String]
    public var excerpt: String
    public var candidateOpenApps: [AppCandidate]
    public var discouragedTokens: [String]
    public var actionVocabularyRule: String
    public init(fileName: String, kind: String, roleTags: [String], languageHint: String?, headings: [String],
                fieldNames: [String], excerpt: String, candidateOpenApps: [AppCandidate],
                discouragedTokens: [String], actionVocabularyRule: String) {
        self.fileName = fileName; self.kind = kind; self.roleTags = roleTags; self.languageHint = languageHint
        self.headings = headings; self.fieldNames = fieldNames; self.excerpt = excerpt
        self.candidateOpenApps = candidateOpenApps; self.discouragedTokens = discouragedTokens
        self.actionVocabularyRule = actionVocabularyRule
    }
}

/// AI 文件夹/建议「核查不扣题成员」输入:文件夹主题 + 当前候选条目(Core 富类型,引擎据序号回查 candidateID)。
/// **internal(非 public)**:属性用 Core 的 internal 类型 `AIVirtualNodePromptCandidate`,public 不能暴露 internal;
/// 三 target 都把本文件 + SimpleZip/Core 当 synced 源直编、同 module 可见,internal 已足够跨 target 共享。
nonisolated struct WorkspaceVerifyMisfitsInput: Codable, Sendable {
    var theme: String
    var items: [AIVirtualNodePromptCandidate]
    init(theme: String, items: [AIVirtualNodePromptCandidate]) {
        self.theme = theme
        self.items = items
    }
}

// MARK: - 输出 DTO(引擎产 / App 解码)

/// 纯文本 pass 的通用输出(一句话 / 一段解释)。
public nonisolated struct AIPassTextOutput: Codable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

/// 通用「1 基编号列表」输出(引擎已解析 + 去重 + 合法性过滤)。chip 排序 / 包内条目挑选等共用。
public nonisolated struct AIPassIntListOutput: Codable, Sendable {
    public var numbers: [Int]
    public init(numbers: [Int]) { self.numbers = numbers }
}

/// 聚集命名输出:每条 = (1 基编号, 名字)。引擎已解析 + 去重 + 合法性过滤。
public nonisolated struct AIPassClusterNamingOutput: Codable, Sendable {
    public nonisolated struct Entry: Codable, Sendable {
        public var index: Int
        public var name: String
        public init(index: Int, name: String) { self.index = index; self.name = name }
    }
    public var entries: [Entry]
    public init(entries: [Entry]) { self.entries = entries }
}

/// 通用「单个整数」输出(如 URL 选中的 **0 基**下标;-1 = 没选 / 无效)。
public nonisolated struct AIPassIntOutput: Codable, Sendable {
    public var number: Int
    public init(number: Int) { self.number = number }
}

/// 归档定性输出:一句定性 + 适用的工具 token(引擎已过白名单去重)。
public nonisolated struct AIPassArchiveKindOutput: Codable, Sendable {
    public var summary: String
    public var toolTokens: [String]
    public init(summary: String, toolTokens: [String]) { self.summary = summary; self.toolTokens = toolTokens }
}

/// 磁盘镜像建议输出:一句定性 + 是否建议安装。
public nonisolated struct AIPassDiskImageOutput: Codable, Sendable {
    public var summary: String
    public var suggest: Bool
    public init(summary: String, suggest: Bool) { self.summary = summary; self.suggest = suggest }
}

/// 单文件抽屉建议输出:一句摘要 + **原始**动作 token(App 侧再过 Core 词表校验 + kind 适用)+ 推荐 App 编号(0=无)。
public nonisolated struct AIPassFileSuggestionOutput: Codable, Sendable {
    public var summary: String
    public var actions: [String]
    public var openWithAppNumber: Int
    public init(summary: String, actions: [String], openWithAppNumber: Int) {
        self.summary = summary; self.actions = actions; self.openWithAppNumber = openWithAppNumber
    }
}

/// 「文件折叠组建议」输出:每组 = 成员 candidateID 列表 + 批量动作 token(引擎已过词表 + 去重 + ≥2 成员)。
/// 纯基本类型(候选 candidateID 已是 String),故 public —— 不暴露 Core internal 类型。
public nonisolated struct WorkspaceFolderGroupOutput: Codable, Sendable {
    public nonisolated struct Group: Codable, Sendable {
        public var memberIDs: [String]
        public var actionToken: String
        public init(memberIDs: [String], actionToken: String) {
            self.memberIDs = memberIDs
            self.actionToken = actionToken
        }
    }
    public var groups: [Group]
    public init(groups: [Group]) { self.groups = groups }
}

/// 「整理进新文件夹」输出:主题文件夹名 + 成员 candidateID(引擎已过 ≥3 成员)。不值得整理 → 整个为 nil(引擎回 null)。
public nonisolated struct WorkspaceOrganizeOutput: Codable, Sendable {
    public var folderName: String
    public var memberIDs: [String]
    public init(folderName: String, memberIDs: [String]) {
        self.folderName = folderName
        self.memberIDs = memberIDs
    }
}

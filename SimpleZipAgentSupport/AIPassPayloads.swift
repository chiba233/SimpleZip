//
//  AIPassPayloads.swift
//  SimpleZipAgentSupport(App + SimpleZipAIAgent + SimpleZipAIXPCService 三 target 共编)
//
//  独立 AI 进程改造 · 阶段3 · **AI pass 跨进程的 Codable DTO + 种类标识**。
//
//  阶段3 把「整条模型 pass(拼 prompt + 调模型 + 解析结果)」搬进只编进 agent+XPC 的引擎层(AIPassEngine),
//  App 退成薄客户端:拼输入 DTO → 经 XPC `generate(kind:inputJSON:...)` 调 → 收输出 DTO。这些 DTO 必须三 target
//  共享(App 拼/引擎解码输入;引擎产/App 解码输出)→ 放这里,**只用基本类型 Codable**(不依赖 Core / FoundationModels,
//  与 AIAgentConfiguration 同层)。@Generable 结构化类型留在引擎层(FoundationModels,不跨 XPC)。
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
    /// 文件「有活动」提醒(结构化,输入名/动作/时间,输出一句提醒短语)。
    case activityReminder
    /// 活动中心「建议筛选」chip 模型排序(结构化,输入 chip 候选,输出有序编号子集)。
    case rankWorkbenchFilterChips
    /// 活动中心「真建议」聚集命名(结构化,输入真实聚集候选,输出 [编号:名字])。
    case nameWorkbenchClusters
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

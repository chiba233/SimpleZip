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

// MARK: - 输出 DTO(引擎产 / App 解码)

/// 纯文本 pass 的通用输出(一句话 / 一段解释)。
public nonisolated struct AIPassTextOutput: Codable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

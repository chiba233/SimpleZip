//
//  AIBudget.swift
//  SimpleZip
//
//  0.4.5 #80:统一 AI 上下文预算 + 截断策略(对齐路线图「工程补充三:性能预算」)。
//
//  AI 不能拖慢主窗口 / 活动中心 / 归档浏览。任何 builder 在把候选 / 文本喂给模型前,都先按场景预算
//  本地召回、截断、采样,并把「省略了多少 / 为什么」写进 `AIContextOmission`。这样数据量可以很大但可控,
//  不会把 500 条完整日志一次塞进模型。纯值类型,SwiftPM 可断言。
//

import Foundation

nonisolated struct AIBudget: Codable, Equatable, Sendable {
    /// 候选条数上限(任务 / 归档 / 节点 …)。
    let maxItems: Int
    /// 单条文本字符上限(错误行 / 日志尾部 / 单条样本说明)。
    let maxTextChars: Int
    /// 每个分组的真实样本条数上限(suspiciousPaths / largestFiles / samplePaths …)。
    let maxSamplesPerGroup: Int
    /// 整个 prompt 的总字符预算 —— 防止「每条都合法但整体超大」(工程补充十)。
    let maxTotalChars: Int

    init(maxItems: Int, maxTextChars: Int, maxSamplesPerGroup: Int, maxTotalChars: Int = 20_000) {
        self.maxItems = max(1, maxItems)
        self.maxTextChars = max(1, maxTextChars)
        self.maxSamplesPerGroup = max(1, maxSamplesPerGroup)
        self.maxTotalChars = max(1, maxTotalChars)
    }

    // 各场景默认预算(对齐路线图补充三的表;文本预算指单条,不是总量)。
    static let activityFilter = AIBudget(maxItems: 80, maxTextChars: 800, maxSamplesPerGroup: 8)
    static let activityWorkbench = AIBudget(maxItems: 50, maxTextChars: 2000, maxSamplesPerGroup: 8)
    static let archiveMemory = AIBudget(maxItems: 60, maxTextChars: 1200, maxSamplesPerGroup: 20)
    static let archiveProfile = AIBudget(maxItems: 64, maxTextChars: 800, maxSamplesPerGroup: 16)
    static let workspaceTheme = AIBudget(maxItems: 30, maxTextChars: 1200, maxSamplesPerGroup: 8)
    static let workspaceTree = AIBudget(maxItems: 80, maxTextChars: 1200, maxSamplesPerGroup: 12)
    static let operationPreview = AIBudget(maxItems: 40, maxTextChars: 1200, maxSamplesPerGroup: 12)
    static let habitSummary = AIBudget(maxItems: 200, maxTextChars: 800, maxSamplesPerGroup: 8)
    // 深度本地上下文(用户开启)的更大预算(更多样本 / 更长文本 / 更高总额)。
    static let archiveProfileDeep = AIBudget(maxItems: 96, maxTextChars: 1600, maxSamplesPerGroup: 24, maxTotalChars: 30_000)
    static let workspaceTreeDeep = AIBudget(maxItems: 120, maxTextChars: 1600, maxSamplesPerGroup: 18, maxTotalChars: 40_000)

    /// 截断候选数组到 `maxItems`。返回保留项 + 可选省略说明(超预算时说明省了多少)。
    func cap<T>(_ items: [T], type: String) -> (kept: [T], omission: AIContextOmission?) {
        guard items.count > maxItems else { return (items, nil) }
        return (Array(items.prefix(maxItems)),
                .truncated(type: type, omitted: items.count - maxItems, reason: "budget"))
    }

    /// 截断一组真实样本到 `maxSamplesPerGroup`(不产省略说明 —— 样本本就「取几个示例」)。
    func sample<T>(_ items: [T]) -> [T] {
        Array(items.prefix(maxSamplesPerGroup))
    }

    /// 截断单条文本到 `maxTextChars`(按 grapheme,含中文);超长加省略号。
    func clampText(_ text: String) -> String {
        guard text.count > maxTextChars else { return text }
        return String(text.prefix(maxTextChars)) + "…"
    }

    /// 截断一组文本:先按 `maxItems` 截条数(超额产省略说明),再把每条 `clampText` 到单条上限。
    func capTextArray(_ items: [String], type: String) -> (kept: [String], omission: AIContextOmission?) {
        let (capped, omission) = cap(items, type: type)
        return (capped.map(clampText), omission)
    }

    /// 把整段拼好的 prompt 文本截到 `maxTotalChars`(总额防线;超长加省略号)。
    func clampTotal(_ text: String) -> String {
        guard text.count > maxTotalChars else { return text }
        return String(text.prefix(maxTotalChars)) + "…"
    }

    /// 预算消耗(调试视图用):用了多少 / 上限 / 是否超额。
    func consumption(of text: String) -> (used: Int, limit: Int, withinBudget: Bool) {
        (used: text.count, limit: maxTotalChars, withinBudget: text.count <= maxTotalChars)
    }
}

nonisolated enum AIModelCallTimeout {
    static let defaultDuration: Duration = .seconds(30)

    static func run<T: Sendable>(
        after duration: Duration = defaultDuration,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: duration)
                throw CancellationError()
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }
}

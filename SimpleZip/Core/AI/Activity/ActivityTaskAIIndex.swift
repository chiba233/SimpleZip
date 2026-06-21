//
//  ActivityTaskAIIndex.swift
//  SimpleZip
//
//  0.4.5 #80:活动中心任务的 **AI 索引记录**(路线图建议二「活动中心任务数据集」/ 建议七 筛选 v2 / 建议八)。
//
//  把一个任务压成短小、稳定、可测的 `AITaskRecord`:字段名固定、枚举稳定英文 token、失败消息脱敏、
//  错误行抽取 + 确定性诊断标签、完整路径拆成低敏 token。活动中心筛选 / 工作台直接读这个小表,按 id 回查。
//  `make(...)` 把「格式化 / 脱敏 / 分类」全收进 Core(可单测);App 适配器(从 OperationTask)只传原始字段。
//
//  **红线**:失败消息 / 错误行进记录前一律 `AISensitiveRedactor.redact`;完整路径不进记录,只留文件名 +
//  位置类别 + 路径 token。纯函数 + 确定性,SwiftPM 可断言。
//

import Foundation

nonisolated struct AITaskRecord: Codable, Equatable, Sendable {
    struct Files: Codable, Equatable, Sendable {
        let archiveName: String?
        let archiveExtension: String?
        let inputNames: [String]
        let outputNames: [String]
        let locationKinds: [String]
        let pathTokens: [String]
    }

    struct Diagnostics: Codable, Equatable, Sendable {
        let tags: [String]
        let failureMessage: String?
        let errorLines: [String]
    }

    struct ResultInfo: Codable, Equatable, Sendable {
        let canRerun: Bool
        let canRerunWithChanges: Bool
        let canResumeFromFailure: Bool
        let skippedReason: String?
    }

    /// 任务 id —— AI 输出引用它,App 必须校验存在。
    let id: String
    let category: String
    let kind: String
    let source: String
    let status: String
    let title: String
    let startedAt: String?      // ISO8601
    let finishedAt: String?     // ISO8601
    let durationSeconds: Int?
    let files: Files
    let diagnostics: Diagnostics
    let result: ResultInfo
    // UI 不直接展示但对 AI 筛选有用。
    let failureSeen: Bool
    let awaitedConcurrencySlot: Bool
    let waitedForWriteLock: Bool

    /// 紧凑确定性 JSON 单行(JSONL 用)。
    func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

extension AITaskRecord {
    /// 从原始任务字段构造 AI 记录:失败消息脱敏、错误行抽取 + 诊断标签确定性分类、路径拆低敏 token。
    static func make(
        id: String,
        category: String,
        kind: String,
        source: String,
        status: String,
        title: String,
        startedAt: Date?,
        finishedAt: Date?,
        archivePath: String? = nil,
        inputPaths: [String] = [],
        outputPaths: [String] = [],
        failureMessage: String? = nil,
        rawOutput: String? = nil,
        home: String = NSHomeDirectory(),
        canRerun: Bool = false,
        canRerunWithChanges: Bool = false,
        canResumeFromFailure: Bool = false,
        skippedReason: String? = nil,
        failureSeen: Bool = false,
        awaitedConcurrencySlot: Bool = false,
        waitedForWriteLock: Bool = false,
        encryptedSource: Bool = false,
        extraDiagnosticLines: [String] = [],
        budget: AIBudget = .activityFilter
    ) -> AITaskRecord {
        let outputLines = rawOutput
            .map { AISensitiveRedactor.errorLines(from: $0) }
            .map { $0.map(budget.clampText) } ?? []
        // 数据接全:文件操作等**无后端 rawOutput** 的失败,其逐文件失败原因(transferLog 的 name + detail)
        // 经此作为额外诊断行喂入 —— 同样脱敏 + clamp,既给失败解释补足模型可读的具体上下文(否则只能瞎猜),
        // 又让确定性分类器据此打标签(权限 / 空间 / 冲突…)。cap 到 maxSamplesPerGroup,去重已在 errorLines 里的。
        let extraLines = Array(extraDiagnosticLines
            .map { AISensitiveRedactor.redact($0) }
            .map(budget.clampText)
            .filter { !$0.isEmpty }
            .prefix(budget.maxSamplesPerGroup))
        var errorLines = outputLines
        for line in extraLines where !errorLines.contains(line) { errorLines.append(line) }
        let redactedFailure = failureMessage
            .map { AISensitiveRedactor.redact($0) }
            .map(budget.clampText)
        let tags = AIDiagnosticsClassifier
            .classify(message: failureMessage ?? "", errorLines: errorLines)
            .map(\.rawValue)

        let allPaths = ([archivePath].compactMap { $0 } + inputPaths + outputPaths)
        let locationKinds = Set(allPaths.map {
            AILocationClassifier.classify(directoryPath: ($0 as NSString).deletingLastPathComponent, home: home).kind.rawValue
        }).sorted()
        let pathTokens = Array(Set(allPaths.flatMap { path -> [String] in
            AILocationClassifier.folderNameTokens(path)
                + AILocationClassifier.folderNameTokens((path as NSString).deletingLastPathComponent)
        }).sorted().prefix(budget.maxSamplesPerGroup))

        let archiveName = archivePath
            .map { ($0 as NSString).lastPathComponent }
            .map(AISensitiveRedactor.redactFileNameSecrets)
        let archiveExtension = archivePath
            .map { ($0 as NSString).pathExtension.lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }

        let duration: Int?
        if let started = startedAt, let finished = finishedAt {
            // 审计 #12:finishedAt 早于 startedAt(时钟回拨等)时夹到 0,不出负数。
            duration = max(0, Int(finished.timeIntervalSince(started).rounded()))
        } else {
            duration = nil
        }

        // 审计 #1(CRITICAL):标题之前裸传进 AI JSON —— 会泄漏加密归档条目名 / secret 形态文件名。
        // 非加密源:过 redact(抓 key=value secret 形态)+ clamp;加密源:整体降级成不含名字的通用标签
        // (redact 抓不到普通条目名,而加密归档条目名是硬红线;语义信息已在 category/kind/status 字段里)。
        let safeTitle = encryptedSource
            ? "\(kind) on encrypted archive"
            : budget.clampText(AISensitiveRedactor.redact(title))

        return AITaskRecord(
            id: id,
            category: category,
            kind: kind,
            source: source,
            status: status,
            title: safeTitle,
            startedAt: startedAt.map(Self.iso),
            finishedAt: finishedAt.map(Self.iso),
            durationSeconds: duration,
            files: Files(
                archiveName: archiveName,
                archiveExtension: archiveExtension,
                inputNames: inputPaths.map { AISensitiveRedactor.redactFileNameSecrets(($0 as NSString).lastPathComponent) },
                outputNames: outputPaths.map { AISensitiveRedactor.redactFileNameSecrets(($0 as NSString).lastPathComponent) },
                locationKinds: locationKinds,
                pathTokens: pathTokens
            ),
            diagnostics: Diagnostics(
                tags: tags,
                failureMessage: redactedFailure,
                errorLines: errorLines
            ),
            result: ResultInfo(
                canRerun: canRerun,
                canRerunWithChanges: canRerunWithChanges,
                canResumeFromFailure: canResumeFromFailure,
                skippedReason: skippedReason
            ),
            failureSeen: failureSeen,
            awaitedConcurrencySlot: awaitedConcurrencySlot,
            waitedForWriteLock: waitedForWriteLock
        )
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

nonisolated enum ActivityTaskAIIndex {
    /// 把任务记录集格式化成紧凑 JSONL(一行一个任务),按预算截断并返回省略说明。
    static func jsonl(_ records: [AITaskRecord],
                      budget: AIBudget = .activityFilter) -> (text: String, omission: AIContextOmission?) {
        let (kept, omission) = budget.cap(records, type: "tasks")
        let lines = kept.compactMap { try? $0.jsonLine() }
        return (lines.joined(separator: "\n"), omission)
    }
}

//
//  ReportExport.swift
//  SimpleZip
//
//  0.4.4 F2:统一报告导出底座。各报告(diff / 发布检查 / 安全 / 空间分析 / szs 验证…)以前
//  要么只能看不能导,要么各自手写导出;现在统一过一个协议:Markdown / JSON / 摘要 / GitHub Issue
//  四种输出,元数据(生成时间 / 版本 / 后端)一处拼装。纯 Core,SwiftPM 可测。
//

import Foundation

/// 报告导出时随附的环境元数据。App 侧拼一次(版本 / 后端要跑进程,异步取),所有格式共用。
public struct ReportMetadata: Codable, Equatable {
    public let generatedAt: Date
    /// 报告对象的路径(归档 / 文件夹);没有明确对象的报告(如批量)可为 nil。
    public let targetPath: String?
    public let appVersion: String
    public let macOSVersion: String
    public let backendVersion: String

    public init(
        generatedAt: Date,
        targetPath: String?,
        appVersion: String,
        macOSVersion: String,
        backendVersion: String
    ) {
        self.generatedAt = generatedAt
        self.targetPath = targetPath
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.backendVersion = backendVersion
    }
}

/// 可导出的报告。`metadata` 一律可选 —— 传 nil 时输出必须与历史版本字节一致
/// (既有导出契约/测试不被破坏);带 metadata 时在各自格式里追加环境信息。
public protocol ReportExportable {
    /// 报告标题(导出文件名 / issue 标题用)。
    var reportTitle: String { get }
    /// 报告对象路径(无明确对象的报告返回 nil)。
    var reportTargetPath: String? { get }
    /// 一行纯文本摘要(「复制摘要」用)。
    var reportSummaryLine: String { get }
    func reportMarkdown(metadata: ReportMetadata?) -> String
    func reportJSON(metadata: ReportMetadata?) throws -> String
}

public enum ReportExport {
    /// 元数据的 Markdown 页脚(各报告 Markdown 复用,保持同一格式)。
    public static func markdownFooter(_ metadata: ReportMetadata) -> String {
        var lines = ["", "---", ""]
        var parts = ["SimpleZip \(metadata.appVersion)", "7-Zip \(metadata.backendVersion)", isoString(metadata.generatedAt)]
        if let targetPath = metadata.targetPath, !targetPath.isEmpty {
            parts.append(targetPath)
        }
        lines.append("_" + parts.joined(separator: " · ") + "_")
        return lines.joined(separator: "\n")
    }

    /// 可直接粘贴 GitHub Issue 的正文:环境表(与诊断包同一布局)+ 摘要 + 折叠的完整报告。
    /// 与 OperationDiagnosticsReporter.makeGitHubIssueMarkdown 的环境表保持同款表头格式。
    public static func gitHubIssueBody(
        title: String,
        summaryLine: String,
        reportMarkdown: String,
        metadata: ReportMetadata
    ) -> String {
        var lines: [String] = []
        lines.append("### Environment")
        lines.append("")
        lines.append("| | |")
        lines.append("|---|---|")
        lines.append("| SimpleZip | \(metadata.appVersion) |")
        lines.append("| macOS | \(metadata.macOSVersion) |")
        lines.append("| 7-Zip backend | \(metadata.backendVersion) |")
        lines.append("")
        lines.append("### \(title)")
        lines.append("")
        lines.append(summaryLine)
        lines.append("")
        lines.append("<details><summary>Full report</summary>")
        lines.append("")
        lines.append(reportMarkdown)
        lines.append("")
        lines.append("</details>")
        return lines.joined(separator: "\n")
    }

    /// 统一 JSON 编码器:确定性输出(sortedKeys + ISO8601 日期),所有报告 JSON 同款。
    public static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// 固定 ISO 风格时间(与诊断报告同款 en_US_POSIX,不随用户 locale 变)。
    public static func isoString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter.string(from: date)
    }
}

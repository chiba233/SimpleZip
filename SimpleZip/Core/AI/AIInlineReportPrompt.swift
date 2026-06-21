//
//  AIInlineReportPrompt.swift
//  SimpleZip
//
//  归档抽屉内联「只读报告」一句话解释的**提示词构建器**(原在 App 的 AIReportAssistant;下沉 Core 供 App 前台 +
//  后台 agent 共用 —— pending security / inspect 自动检查在 agent 也要据这份构建 reportText prompt)。
//  纯函数:Core 分析结果(ReleaseInspectionReport / ArchiveRiskScore.Assessment / ArchiveSecurityFinding)→
//  (instructions, prompt)。红线:只解释只读报告、不放行、不下安全判决、不提任何 app / 厂商 / 平台名。
//

import Foundation

nonisolated enum AIInlineReportPrompt {
    /// 发布包检测报告 → 一句话解释的提示词(只用提供的事实,不提任何产品名,不下判决 / 不催行动)。
    static func releaseInspection(for report: ReleaseInspectionReport) -> (instructions: String, prompt: String) {
        let instructions = """
        Explain a read-only archive inspection result in exactly one plain-language sentence. Use only the \
        provided facts. Do not mention any app, vendor, product, marketplace, publishing platform, or \
        specific software name. Do not tell the user to publish, extract, delete, repair, trust, override a \
        warning, or take action. Do not present a security verdict; describe what the checks found.
        """
        var lines: [String] = [
            "Report kind: read-only archive inspection",
            "Listing available: \(report.listable)"
        ]
        if let passed = report.testPassed {
            lines.append("Integrity test passed: \(passed)")
        } else {
            lines.append("Integrity test passed: unknown")
        }
        if let stats = report.stats {
            lines.append("Files: \(stats.fileCount)")
            lines.append("Folders: \(stats.folderCount)")
            lines.append("Total bytes: \(stats.totalBytes)")
            lines.append("Metadata junk entries: \(stats.junkCount)")
            lines.append("Empty folders: \(stats.emptyDirectoryCount)")
            lines.append("Executable entries: \(stats.executableCount)")
            lines.append("Symbolic links: \(stats.symlinkCount)")
        }
        lines.append("Suspicious path finding types: \(report.securityFindings.count)")
        lines.append("Has archive comment: \(report.hasComment)")
        return (instructions, lines.joined(separator: "\n"))
    }

    /// 路径安全报告 → 一句话解释的提示词(规则系统已定级,AI 只解释这份只读报告,不重新定级 / 不催行动)。
    static func pathSafety(
        assessment: ArchiveRiskScore.Assessment,
        findings: [ArchiveSecurityFinding],
        listable: Bool
    ) -> (instructions: String, prompt: String) {
        let instructions = """
        Explain a read-only archive path-safety report in exactly one plain-language sentence. Use only the \
        provided facts. Do not mention any app, vendor, product, marketplace, publishing platform, or \
        specific software name. Do not tell the user to extract, delete, repair, trust, override a warning, \
        or take action. Do not re-grade the report; describe the deterministic rule result and what was \
        found.
        """
        var lines: [String] = [
            "Report kind: read-only path-safety analysis",
            "Listing available: \(listable)",
            "Rule grade: \(assessment.grade.rawValue.uppercased())",
            "Rule level: \(assessment.level.rawValue)"
        ]
        if let dominant = assessment.dominant {
            lines.append("Dominant issue: \(dominant.dimension.rawValue) (\(dominant.count) entries)")
        } else {
            lines.append("Dominant issue: none")
        }
        if findings.isEmpty {
            lines.append("Finding types: none")
        } else {
            lines.append("Finding types:")
            for finding in findings {
                lines.append("- \(finding.kind.rawValue): \(finding.entryPaths.count)")
            }
        }
        return (instructions, lines.joined(separator: "\n"))
    }
}

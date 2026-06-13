//
//  AIReportAssistant.swift
//  SimpleZip
//
//  0.4.4 · macOS 26 AI:FoundationModels 本地模型的统一封装。
//
//  **红线**:只读输入 · 生成文本 · 绝不进安全写入路径 —— 不删文件、不放行危险路径、不忽略签名失败、
//  不自动修复 / 覆盖。AI 只「解释 · 分类 · 建议」,产出落进可编辑文本框由用户审阅后自行使用。
//  全本地推理、不外发;prompt 绝不包含加密归档条目名 / 内容、GPG 密文、口令、解密明文(见隐私口径)。
//
//  可用性跨基线收敛:macOS < 26 恒不可用;26+ 再看系统模型 availability + 用户主开关。
//  任一不满足 → 调用点把入口 disabled / 隐藏,UI 永不因 AI 崩。
//

import Foundation
import FoundationModels

enum AIReportAssistant {
    /// AI 入口是否该出现:用户主开关开 + macOS 26+ + 系统模型 available。
    static var isReady: Bool {
        guard AppPreferences.aiAssistantEnabled else { return false }
        guard #available(macOS 26.0, *) else { return false }
        return SystemLanguageModel.default.isAvailable
    }

    /// macOS 26+ 但模型当前不可用的人话原因(给 disabled 按钮 / 设置说明)。可用时返回空串。
    static var unavailableReason: String {
        guard #available(macOS 26.0, *) else { return L10n.text("ai.unavailable.osTooOld") }
        switch SystemLanguageModel.default.availability {
        case .available:
            return ""
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return L10n.text("ai.unavailable.deviceNotEligible")
            case .appleIntelligenceNotEnabled:
                return L10n.text("ai.unavailable.notEnabled")
            default:
                return L10n.text("ai.unavailable.modelNotReady")
            }
        }
    }

    /// 生成文本。仅 macOS 26+ 调用(调用点已用 `isReady` 守卫)。失败抛出,UI 显示错误文案、不崩。
    @available(macOS 26.0, *)
    static func generate(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt).content
    }
}

/// AI 入口在不可用时被点到的兜底错误(理论上 isReady 已挡住,防御性留一个)。
struct AIAssistError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Prompt 构造(纯字符串组装,只读输入)

extension AIReportAssistant {
    /// 喂给模型时,每类发现取这么多条**真实条目路径**做样本 —— 让 AI 说得出具体的「哪个文件」而不是
    /// 空泛的「可能有些问题,请检查」(用户原话:数据太薄 AI 就是废话文学)。隐私:这些是**未加密**清单
    /// 里的条目路径(头加密的归档根本列不出名字,自然不会进来),非加密路径登录用户本就可见,不必脱敏;
    /// 但 prompt 永不含加密内容 / GPG 密文 / 口令 / 解密明文。见 [[feedback_privacy_only_encrypted]]。
    static func sampleEntries(_ paths: [String], perKind: Int = 5) -> String {
        let samples = paths.prefix(perKind)
        let more = paths.count - samples.count
        let joined = samples.joined(separator: ", ")
        return more > 0 ? "\(joined), +\(more) more" : joined
    }

    /// A:发布检查报告 → 风险总结。给计数 + 关键信号 + **真实样本条目路径**(数据太薄 AI 只会输出空泛
    /// 套话;喂具体条目它才能说出「哪个文件值得注意」)。隐私按 `sampleEntries`(只非加密清单路径)。
    static func riskSummaryPrompt(for report: ReleaseInspectionReport) -> (instructions: String, prompt: String) {
        let instructions = """
        You are a release-engineering assistant for the SimpleZip archive manager. Given an inspection \
        report for an archive that is about to be published, write a short, plain-language risk summary \
        for the person publishing it: first say whether it looks publishable, then a few concise bullet \
        points on anything noteworthy. Be specific and concrete — when an example entry illustrates a \
        point, name it; avoid vague filler. Use only the facts provided — never invent issues. Do not \
        give instructions to delete files or change anything. Reply in the user's language.
        """
        var lines: [String] = ["Archive: \(report.archiveURL.lastPathComponent)"]
        if let stats = report.stats {
            lines.append("Files: \(stats.fileCount), folders: \(stats.folderCount), total bytes: \(stats.totalBytes)")
            lines.append("macOS junk entries: \(stats.junkCount), empty directories: \(stats.emptyDirectoryCount), executables: \(stats.executableCount), symlinks: \(stats.symlinkCount)")
        }
        if let passed = report.testPassed { lines.append("Integrity test passed: \(passed)") }
        if let failure = report.testFailureMessage { lines.append("Integrity test failure: \(failure)") }
        let flaggedPaths = report.securityFindings.reduce(0) { $0 + $1.entryPaths.count }
        lines.append("Suspicious-path finding categories: \(report.securityFindings.count), flagged entries: \(flaggedPaths)")
        lines.append("SHA256SUMS actually written: \(report.wroteChecksums)")
        if let publicKey = report.publicKeyBesideSignature {
            lines.append("Public key sits beside the signature container: \(publicKey)")
        }
        if !report.gateViolations.isEmpty { lines.append("Quality-gate violations: \(report.gateViolations.count)") }
        if !report.bundleFindings.isEmpty { lines.append("App-bundle / disk-image findings: \(report.bundleFindings.count)") }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// D:失败任务 → 大白话解释 + 建议。喂失败消息 + 命令输出尾部(口令本就不进后端输出,安全)。
    static func failureExplanationPrompt(taskTitle: String, failureMessage: String, output: String?) -> (instructions: String, prompt: String) {
        let instructions = """
        You are a helpful assistant for the SimpleZip archive manager. A background task failed. \
        Explain, in plain language for a non-expert, the most likely reason it failed and what the user \
        could try next. Point at the specific error lines from the log when they explain the failure — be \
        concrete, not generic. Base your answer only on the provided error and log; if the cause is \
        unclear, say so. Never tell the user to delete files or run destructive commands. Reply in the \
        user's language.
        """
        var lines: [String] = ["Task: \(taskTitle)", "Error: \(failureMessage)"]
        if let output, !output.isEmpty {
            // 尾部 ~6000 字符:UI 把命令输出折叠,这里给模型更全的日志才能指向具体出错行(口令本就不进后端输出,安全)。
            let tail = output.count > 6000 ? "…(earlier output truncated)\n" + String(output.suffix(6000)) : output
            lines.append("Command output:\n\(tail)")
        }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// B:把已生成的 GitHub Issue Markdown 润色得更易读(已脱敏,直接喂)。
    static func issuePolishPrompt(rawIssue: String) -> (instructions: String, prompt: String) {
        let instructions = """
        You are a developer assistant. Rewrite the following auto-generated GitHub issue so it reads \
        clearly for maintainers: keep every technical fact (versions, environment table, error, logs) \
        and keep all "[REDACTED]" markers untouched, but improve the structure and add a one-line \
        summary at the top. Do not invent details. Reply in the user's language.
        """
        return (instructions, rawIssue)
    }

    /// C:批量体检结果 → 给每个包建议描述标签(只建议、不参与任何安全判定 / 不改状态)。
    static func checkupLabelsPrompt(for report: ArchiveCheckupReport) -> (instructions: String, prompt: String) {
        let instructions = """
        You are an archive-triage assistant for the SimpleZip archive manager. For each archive in this \
        batch checkup, suggest a few short, descriptive labels (e.g. release-artifact, source-archive, \
        backup, installer, corrupted, encrypted, contains-macOS-junk, possible-duplicate, missing-volumes, \
        read-only). Base labels ONLY on the facts given — these are suggestions, not a verdict. Output one \
        line per archive in the form "filename: label, label". Reply in the user's language.
        """
        var lines: [String] = ["Checkup scope: \(report.scopeName)"]
        for row in report.rows {
            var parts: [String] = []
            switch row.testOutcome {
            case .passed: parts.append("integrity test passed")
            case .failed: parts.append("integrity test failed")
            case .needsPassword: parts.append("needs a password")
            case .notListable: parts.append("not listable")
            }
            // 规模 + 真实样本条目(UI 只展示计数;喂给 AI 这些细节,标签才具体不空泛)。
            if row.fileCount > 0 { parts.append("files: \(row.fileCount)") }
            if row.totalBytes > 0 {
                parts.append("size: \(ByteCountFormatter.string(fromByteCount: row.totalBytes, countStyle: .file))")
            }
            if let facts = row.facts {
                parts.append("suspicious paths: \(facts.suspiciousPathCount)")
                parts.append("macOS junk entries: \(facts.junkCount)")
                parts.append("encrypted entries: \(facts.encryptedCount)")
            }
            if !row.suspiciousSamplePaths.isEmpty {
                parts.append("suspicious e.g. \(row.suspiciousSamplePaths.prefix(4).joined(separator: ", "))")
            }
            if !row.junkSampleNames.isEmpty {
                parts.append("junk e.g. \(row.junkSampleNames.prefix(4).joined(separator: ", "))")
            }
            if row.missingVolumeCount > 0 { parts.append("missing volumes: \(row.missingVolumeCount)") }
            if row.readOnlyFormat { parts.append("read-only format") }
            if !row.duplicatePeers.isEmpty { parts.append("structurally identical to \(row.duplicatePeers.count) other(s)") }
            lines.append("\(row.fileName): \(parts.joined(separator: ", "))")
        }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// #51:安全报告 A/B/C → 白话解释。**只解释规则评分,绝不自己判安全 / 不重新定级 / 不放行**
    /// (评分由确定性规则系统给出,AI 只把字母等级和发现类型翻成人话 + 解压时该留意什么)。
    /// 只喂等级 + 每类发现的计数(不放具体条目路径,够解释也更稳)。
    static func securityExplanationPrompt(
        archiveName: String,
        assessment: ArchiveRiskScore.Assessment,
        findings: [ArchiveSecurityFinding]
    ) -> (instructions: String, prompt: String) {
        let instructions = """
        You are a safety assistant for the SimpleZip archive manager. The app already graded this \
        archive's path safety with a deterministic rule system (A = low risk, B = medium, C = high). \
        Explain to a non-expert, in plain language, what the grade means and what each finding type is — \
        and for the risky ones, what to watch for when extracting. Use ONLY the facts given; never invent \
        findings, never tell the user to delete files or override a safety prompt, and do not contradict \
        or re-grade the rule-based score. Keep it short. Reply in the user's language.
        """
        var lines: [String] = [
            "Archive: \(archiveName)",
            "Rule-based grade: \(assessment.grade.rawValue.uppercased()) (\(assessment.level.rawValue) risk)"
        ]
        if let dominant = assessment.dominant {
            lines.append("Most serious issue driving the grade: \(dominant.dimension.rawValue) (\(dominant.count) flagged entries)")
        } else {
            lines.append("No risk-affecting issues found.")
        }
        if findings.isEmpty {
            lines.append("Suspicious-path findings: none.")
        } else {
            // 给 AI 真实样本条目(非加密清单路径),它才能具体指出「哪个文件为什么危险」,而非泛泛而谈。
            lines.append("Suspicious-path findings by type, with example entries (non-encrypted listing paths):")
            for finding in findings {
                lines.append("- \(finding.kind.rawValue) (\(finding.entryPaths.count)): \(sampleEntries(finding.entryPaths))")
            }
        }
        return (instructions, lines.joined(separator: "\n"))
    }
}

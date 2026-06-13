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
    /// A:发布检查报告 → 风险总结。**只给计数 / 布尔等聚合事实,不放具体条目路径**(够总结、也更稳)。
    static func riskSummaryPrompt(for report: ReleaseInspectionReport) -> (instructions: String, prompt: String) {
        let instructions = """
        You are a release-engineering assistant for the SimpleZip archive manager. Given an inspection \
        report for an archive that is about to be published, write a short, plain-language risk summary \
        for the person publishing it: first say whether it looks publishable, then a few concise bullet \
        points on anything noteworthy. Use only the facts provided — never invent issues. Do not give \
        instructions to delete files or change anything. Reply in the user's language.
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
        could try next. Be concise. Base your answer only on the provided error and log; if the cause is \
        unclear, say so. Never tell the user to delete files or run destructive commands. Reply in the \
        user's language.
        """
        var lines: [String] = ["Task: \(taskTitle)", "Error: \(failureMessage)"]
        if let output, !output.isEmpty {
            // 只取尾部 ~2000 字符,够定位、又不撑爆 prompt。
            let tail = output.count > 2000 ? String(output.suffix(2000)) : output
            lines.append("Command output (tail):\n\(tail)")
        }
        return (instructions, lines.joined(separator: "\n"))
    }
}

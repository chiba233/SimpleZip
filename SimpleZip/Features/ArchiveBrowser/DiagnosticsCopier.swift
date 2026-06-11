//
//  DiagnosticsCopier.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// 「复制诊断」按钮背后的胶水：
/// (1) 从 session + ArchiveService + Bundle + ProcessInfo 拼出 reporter 需要的 inputs；
/// (2) 让 Core 的 reporter 出文本；
/// (3) 写进 NSPasteboard。
/// 拆出来单独放是因为 Core 不该 import AppKit / Bundle.main，
/// 但 UI 侧又需要一个简单的「点一下就完事」入口。
@MainActor
enum DiagnosticsCopier {

    /// 把诊断报告复制到系统剪贴板。
    ///
    /// 取版本号要异步（ArchiveService.sevenZipVersion / rarVersion 都跑子进程），
    /// 视图层用 `Task { await copy(...) }` 包一下即可。
    static func copy(session: ArchiveOperationDetailsSession, errorMessage: String?) async {
        let inputs = await makeInputs(session: session, errorMessage: errorMessage)
        let report = OperationDiagnosticsReporter.makeReport(from: inputs)
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }

    /// 0.4.2 #22：导出**单个任务**的诊断包为 `.txt` —— 等价命令行已在输出里、密码已脱敏，
    /// 外加后端版本与文件系统现场。
    /// **同步弹面板 → 异步收集写入**。绝不能反过来在 `MainActor.run`/Task 上下文里跑 `runModal()`：
    /// 模态事件循环会占住主 actor 执行器,所有要 hop 回 MainActor 的工作(含面板回调)排队 →
    /// 整个 app 冻结、点哪都没反应(用户报的卡死)。
    @MainActor
    static func exportReport(session: ArchiveOperationDetailsSession, errorMessage: String?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SimpleZip-task-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let inputs = await makeInputs(session: session, errorMessage: errorMessage)
            let report = OperationDiagnosticsReporter.makeReport(from: inputs)
            try? report.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    /// 0.4.2 #22：文件系统现场 —— 临时卷 / 用户卷的剩余与总空间（磁盘满是后端神秘失败的常见根因）。
    private static func fileSystemSummaryText() -> String {
        func line(_ label: String, _ url: URL) -> String {
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
            let values = try? url.resourceValues(forKeys: keys)
            let free = values?.volumeAvailableCapacityForImportantUsage
                .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
            let total = values?.volumeTotalCapacity
                .map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "?"
            return "\(label): \(free) free of \(total)"
        }
        return [
            line("temp volume", FileManager.default.temporaryDirectory),
            line("home volume", FileManager.default.homeDirectoryForCurrentUser)
        ].joined(separator: "\n")
    }

    // MARK: - 通用诊断报告（不绑定某个失败任务的「遇到问题第一出口」）

    /// 生成一份**通用**诊断报告文本：app / macOS 版本 + 后端版本 + GPG 状态 + 最近任务摘要。
    /// 不绑定具体失败 session —— 用户遇到任何问题时都能一键拿到可贴 Issue 的现场快照（已脱敏）。
    static func makeGeneralReport() async -> String {
        let inputs = await makeGeneralInputs()
        return OperationDiagnosticsReporter.makeReport(from: inputs)
    }

    /// 复制通用诊断报告到剪贴板。
    static func copyGeneralReport() async {
        let report = await makeGeneralReport()
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }

    /// 导出通用诊断报告为 `.txt`（NSSavePanel）。返回写入的 URL；用户取消 → nil。
    /// 同上：先同步弹面板,再异步收集写入(MainActor.run + runModal = 主 actor 死锁)。
    @MainActor
    static func exportGeneralReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SimpleZip-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let report = await makeGeneralReport()
            try? report.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    private static func makeGeneralInputs() async -> OperationDiagnosticsInputs {
        let now = Date()
        let recent = await recentTasksSummary()
        return await OperationDiagnosticsInputs(
            appVersion: appVersionString(),
            appBuild: appBuildString(),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            sevenZipDescription: ArchiveService.sevenZipBackendDescription(),
            sevenZipVersion: ArchiveService.sevenZipVersion(),
            rarDescription: ArchiveService.rarBackendDescription(),
            rarVersion: ArchiveService.rarVersion(),
            title: L10n.text("diagnostics.general.title"),
            startedAt: now,
            finishedAt: now,
            rawOutput: recent,
            errorMessage: nil,
            gpgSection: collectGPGSection(),
            fileSystemSummary: fileSystemSummaryText()
        )
    }

    /// 最近任务摘要（活动中心 active + history，最多 20 条，最新在前）。
    /// 只记 状态 / 类别 / 标题 / 失败原因 —— 给维护者「最近发生了什么」的脉络。失败原因经 reporter 统一脱敏。
    private static func recentTasksSummary() async -> String {
        let tasks: [OperationTask] = await MainActor.run {
            (TaskCenter.shared.active + TaskCenter.shared.history)
                .sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }
        }
        guard !tasks.isEmpty else { return "(no recent tasks)" }
        var lines: [String] = []
        for task in tasks.prefix(20) {
            let (label, reason) = await MainActor.run { () -> (String, String?) in
                switch task.status {
                case .running: return ("RUNNING", nil)
                case .succeeded: return ("OK", nil)
                case .skipped(let why): return ("SKIPPED", why)
                case .cancelled: return ("CANCELLED", nil)
                case .failed(let message): return ("FAILED", message)
                }
            }
            let (kind, title) = await MainActor.run { (task.kind.rawValue, task.title) }
            var line = "[\(label)] \(kind): \(title)"
            if let reason, !reason.isEmpty {
                line += " — \(reason.replacingOccurrences(of: "\n", with: " "))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func appVersionString() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private static func appBuildString() -> String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private static func makeInputs(
        session: ArchiveOperationDetailsSession,
        errorMessage: String?
    ) async -> OperationDiagnosticsInputs {
        // 异步拿版本：bundled 7zz 跑 `-version`，RAR 同理。失败时 ArchiveService 内部会返回友好字符串。
        let sevenZipVersion = await ArchiveService.sevenZipVersion()
        let rarVersion = await ArchiveService.rarVersion()
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "?"
        let appBuild = info?["CFBundleVersion"] as? String ?? "?"
        let macOSVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let gpgSection = await collectGPGSection()
        return OperationDiagnosticsInputs(
            appVersion: appVersion,
            appBuild: appBuild,
            macOSVersion: macOSVersion,
            sevenZipDescription: ArchiveService.sevenZipBackendDescription(),
            sevenZipVersion: sevenZipVersion,
            rarDescription: ArchiveService.rarBackendDescription(),
            rarVersion: rarVersion,
            title: session.title,
            startedAt: session.startedAt,
            finishedAt: session.finishedAt,
            rawOutput: session.rawOutput,
            errorMessage: errorMessage,
            gpgSection: gpgSection,
            fileSystemSummary: fileSystemSummaryText()
        )
    }

    /// GPG 后端 snapshot —— 仅在 `gpgEnabled == true` 时收集，否则报告不出 GPG 段（A4）。
    /// 不收 fingerprint / userID / 公钥本体；只发路径 / 版本 / 计数（隐私约束在 SECURITY.md 有说明）。
    private static func collectGPGSection() async -> GPGDiagnosticsSection? {
        guard AppPreferences.gpgEnabled else { return nil }
        let backendDescription = GPGBackend.backendDescription()
        let version = await GPGBackend.version()
        let pinentryAvailable = GPGBackend.hasPinentryMac()
        let agentAlive = await GPGBackend.gpgAgentAlive()
        let gnupgHome = GPGBackend.gnupgHome()
        // 密钥列表只统计数量，丢弃 fingerprint / userID。listKeys 失败时（gpg 不可用）当作 0 处理。
        let keys = (try? await GPGBackend.listKeys()) ?? []
        let secretCount = keys.filter { $0.hasSecretKey }.count
        return GPGDiagnosticsSection(
            backendDescription: backendDescription,
            version: version,
            pinentryAvailable: pinentryAvailable,
            agentAlive: agentAlive,
            gnupgHome: gnupgHome,
            totalKeyCount: keys.count,
            secretKeyCount: secretCount
        )
    }
}

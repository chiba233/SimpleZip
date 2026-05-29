//
//  DiagnosticsCopier.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import Foundation

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
            gpgSection: gpgSection
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

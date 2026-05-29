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
            errorMessage: errorMessage
        )
    }
}

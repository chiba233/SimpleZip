//
//  RarInstallerService.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/30.
//

import Foundation

/// RAR 本地安装 / 升级流程的共享后端 —— Settings RAR section 和 Welcome 助手两边走同一份实现。
///
/// 不在 `ArchiveService` 里：跟「读 / 解压 / 创建」无关，纯粹是「跑一个 bash 安装脚本 + 读 README/LICENSE」，
/// 算作可选后端的安装管理。也没塞进 `RarBackend` (Core)：Core 不该挂带 L10n 的成品消息字符串。
@MainActor
enum RarInstallerService {
    enum Error: LocalizedError {
        case installResourcesMissing
        case loadFailed(underlying: String)

        var errorDescription: String? {
            switch self {
            case .installResourcesMissing:
                return L10n.text("settings.rar.installFilesMissing")
            case .loadFailed(let underlying):
                return L10n.format("settings.rar.installFailedWithOutput", underlying)
            }
        }
    }

    /// 读 LICENSE / README 文本组装 review payload；资源缺失或读失败时抛 `Error`。
    /// 抛出时调用方直接把 `error.localizedDescription` 写到 install message 上即可。
    static func loadReview(action: RarInstallAction) throws -> RarInstallReview {
        guard let licenseURL = ArchiveService.rarInstallLicenseURL(),
              let readmeURL = ArchiveService.rarInstallReadmeURL() else {
            throw Error.installResourcesMissing
        }
        do {
            let licenseText = try String(contentsOf: licenseURL, encoding: .utf8)
            let readmeText = try String(contentsOf: readmeURL, encoding: .utf8)
            return RarInstallReview(action: action, licenseText: licenseText, readmeText: readmeText)
        } catch {
            throw Error.loadFailed(underlying: error.localizedDescription)
        }
    }

    /// 后台跑 bash 安装脚本，返回最终展示给用户的消息（成功 / 失败都已 L10n format）。
    /// 输出只取尾 4 行 —— 失败时最后几行就是 stderr，太多会撑爆 toast。
    /// 跟原实现一致 *不* 支持取消（脚本一般几秒结束）；如果以后想加 Task handle / 中断，单独提一个改动。
    static func runInstaller(action: RarInstallAction) async -> String {
        guard let installerURL = ArchiveService.rarInstallerScriptURL(),
              FileManager.default.fileExists(atPath: installerURL.path) else {
            return L10n.text("settings.rar.installFilesMissing")
        }

        return await Task.detached { () -> String in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [installerURL.path]
            process.currentDirectoryURL = installerURL.deletingLastPathComponent()
            process.standardOutput = output
            process.standardError = output

            do {
                try process.run()
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let tail = String(decoding: data, as: UTF8.self)
                    .split(separator: "\n")
                    .suffix(4)
                    .joined(separator: "\n")
                if process.terminationStatus == 0 {
                    return action == .install
                        ? L10n.text("settings.rar.installSucceeded")
                        : L10n.text("settings.rar.updateSucceeded")
                }
                return tail.isEmpty
                    ? L10n.text("settings.rar.installFailed")
                    : L10n.format("settings.rar.installFailedWithOutput", tail)
            } catch {
                return L10n.format("settings.rar.installFailedWithOutput", error.localizedDescription)
            }
        }.value
    }
}

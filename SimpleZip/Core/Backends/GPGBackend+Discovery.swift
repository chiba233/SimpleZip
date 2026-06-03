//
//  GPGBackend+Discovery.swift
//  SimpleZip
//
//  0.3.0 架构拆分：从 GPGBackend.swift 按职责切出，纯移动、零行为变更。
//

import Foundation

extension GPGBackend {
    // MARK: - 设备发现

    /// 当前应该用哪份 gpg 可执行 —— 按常见 macOS 安装路径依次找候选。
    /// 全部失败 → 抛 `ArchiveError.missingGPG`（新错误类型，下面注释里给出）。
    static func resolve() throws -> String {
        if let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return tool
        }
        throw ArchiveError.missingGPG
    }

    /// 仅可用性判定（不要错误信息）。给 Settings GPG pane 的状态徽章 / HealthChecker 用。
    static func isAvailable() -> Bool {
        (try? resolve()) != nil
    }

    /// 「来源 + 路径」一行 —— 在 Settings → GPG section 显示。
    static func backendDescription() -> String {
        if let tool = try? resolve() {
            return L10n.format("settings.gpg.resolvedPath", tool)
        }
        return L10n.text("settings.gpg.notFound")
    }

    /// 跑 `gpg --version`，取首行作为版本展示。
    /// 找不到 gpg 直接返回 notFound 文案。
    static func version() async -> String {
        guard let tool = try? resolve() else {
            return L10n.text("settings.gpg.notFound")
        }
        do {
            let output = try await BackendProcessRunner.runAndCapture(tool, arguments: ["--version"])
            let firstLine = output
                .split(separator: "\n")
                .map(String.init)
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                ?? tool
            return L10n.format("settings.gpg.resolvedVersion", firstLine)
        } catch {
            return L10n.format("settings.gpg.resolvedVersion", tool)
        }
    }

    /// `GNUPGHOME` 环境变量。用户自定义私钥目录时常见（如指向外置硬盘 / 容器卷）。
    /// 返回 nil 表示走 gpg 默认（`~/.gnupg`）。诊断报告用 ——「为什么 SimpleZip 看不到我的密钥」的高频根因。
    static func gnupgHome() -> String? {
        ProcessInfo.processInfo.environment["GNUPGHOME"]
    }

    /// 尝试启动 gpg-agent —— 幂等，已运行就 no-op。
    /// `gpgconf --launch gpg-agent` 跑在 gpg 的同目录下（brew gnupg 安装会把 gpgconf 跟 gpg 放一起）。
    /// 失败也不抛错：gpg 自己后续也会 spawn agent，这里只是抢在前面把 pinentry 通道建好。
    static func ensureGPGAgentLaunched(near gpgTool: String) async {
        let dir = URL(fileURLWithPath: gpgTool).deletingLastPathComponent()
        let gpgconf = dir.appendingPathComponent("gpgconf").path
        guard FileManager.default.isExecutableFile(atPath: gpgconf) else { return }
        _ = try? await BackendProcessRunner.runAndCapture(
            gpgconf,
            arguments: ["--launch", "gpg-agent"]
        )
    }

    /// `gpg-agent` 是否活着 —— `gpg-connect-agent /bye` 退出码 0 = 活、非 0 = 没启动 / 出错。
    /// 走 `gpg-connect-agent`（跟 gpg 同目录），不是直接 ping socket，因为后者要知道 socket 路径。
    /// 诊断报告用；签名 / 解密真要 agent 时 gpg 自己会拉起它，所以「死」也不一定致命，给 warning 级。
    static func gpgAgentAlive() async -> Bool {
        guard let tool = try? resolve() else { return false }
        let agent = URL(fileURLWithPath: tool).deletingLastPathComponent()
            .appendingPathComponent("gpg-connect-agent").path
        guard FileManager.default.isExecutableFile(atPath: agent) else { return false }
        do {
            _ = try await BackendProcessRunner.runAndCapture(agent, arguments: ["/bye"])
            return true
        } catch {
            return false
        }
    }

    /// 同时是否检测到 `pinentry-mac` —— 没装的话签名 / 解密会卡在 passphrase prompt。
    /// 给 Settings GPG pane 显示警告用。
    static func hasPinentryMac() -> Bool {
        let pinentryCandidates = [
            "/opt/homebrew/bin/pinentry-mac",
            "/usr/local/bin/pinentry-mac",
            "/opt/homebrew/MacGPG2/libexec/pinentry-mac.app/Contents/MacOS/pinentry-mac",
            ArchiveService.envPath(for: "pinentry-mac")
        ].compactMap { $0 }
        return pinentryCandidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
    // MARK: - 候选路径

    /// GPG 在 macOS 上的典型安装位置：
    /// - Homebrew (Apple Silicon: `/opt/homebrew/bin/gpg`，Intel: `/usr/local/bin/gpg`)
    /// - GPGTools (`/usr/local/MacGPG2/bin/gpg` 或 `/opt/homebrew/MacGPG2/bin/gpg`，老版本可能装在这里)
    /// - $PATH 兜底
    private static var candidates: [String] {
        ArchiveService.uniqueExistingCandidatePaths(
            [
                "/opt/homebrew/bin/gpg",
                "/opt/homebrew/bin/gpg2",
                "/usr/local/bin/gpg",
                "/usr/local/bin/gpg2",
                "/opt/homebrew/MacGPG2/bin/gpg",
                "/usr/local/MacGPG2/bin/gpg",
                ArchiveService.envPath(for: "gpg"),
                ArchiveService.envPath(for: "gpg2")
            ].compactMap { $0 }
        )
    }
}

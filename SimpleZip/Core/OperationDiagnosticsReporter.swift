//
//  OperationDiagnosticsReporter.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

/// 用户点「复制诊断」时，UI 层填好这个结构再交给 reporter 格式化。
///
/// 把所有要拼到报告里的数据集中到一个值类型里，让 Core 的格式化函数可以纯靠输入 + 字符串
/// 处理，没有 IO 副作用 —— 这样 SwiftPM 测试可以用准备好的固定输入做精确字符串断言。
public struct OperationDiagnosticsInputs {
    public let appVersion: String
    public let appBuild: String
    public let macOSVersion: String
    public let sevenZipDescription: String
    public let sevenZipVersion: String
    public let rarDescription: String
    public let rarVersion: String
    public let title: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let rawOutput: String
    public let errorMessage: String?
    /// 截取报告里 rawOutput 的最后这么多字符，避免几 MB 的输出贴进 Issue。
    public let outputTailCharacterLimit: Int
    /// 可选 GPG 后端 snapshot —— 用户 `gpgEnabled == true` 时填，否则 nil（报告不会出现 GPG 段）。
    public let gpgSection: GPGDiagnosticsSection?
    /// 0.4.2 #22：文件系统现场（临时卷 / 用户卷剩余空间）—— 磁盘满是后端神秘失败的常见根因。
    public let fileSystemSummary: String?

    public init(
        appVersion: String,
        appBuild: String,
        macOSVersion: String,
        sevenZipDescription: String,
        sevenZipVersion: String,
        rarDescription: String,
        rarVersion: String,
        title: String,
        startedAt: Date,
        finishedAt: Date?,
        rawOutput: String,
        errorMessage: String?,
        outputTailCharacterLimit: Int = 4000,
        gpgSection: GPGDiagnosticsSection? = nil,
        fileSystemSummary: String? = nil
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.macOSVersion = macOSVersion
        self.sevenZipDescription = sevenZipDescription
        self.sevenZipVersion = sevenZipVersion
        self.rarDescription = rarDescription
        self.rarVersion = rarVersion
        self.title = title
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.rawOutput = rawOutput
        self.errorMessage = errorMessage
        self.outputTailCharacterLimit = outputTailCharacterLimit
        self.fileSystemSummary = fileSystemSummary
        self.gpgSection = gpgSection
    }
}

/// GPG 后端诊断 snapshot —— 仅当用户启用了 GPG 集成时被填充。
///
/// **隐私约束**：只携带「路径 / 版本 / 计数」级数据；不带任何 fingerprint / userID / email / 公钥本体；
/// 不读 `~/.gnupg/` 任何文件。用户复制诊断贴 Issue 时不会泄露密钥身份信息。
public struct GPGDiagnosticsSection {
    /// `GPGBackend.backendDescription()` 输出（路径或 "not found" 文案）。
    public let backendDescription: String
    /// `GPGBackend.version()` 输出（gpg --version 首行）。
    public let version: String
    /// 是否检测到 `pinentry-mac`（缺会让解密 / 解锁私钥卡住）。
    public let pinentryAvailable: Bool
    /// `gpg-connect-agent /bye` 退出码 0 = true。
    public let agentAlive: Bool
    /// `$GNUPGHOME` envvar 值；nil = 走默认 `~/.gnupg`。
    public let gnupgHome: String?
    /// keyring 里公钥总数（含私钥的也计入）。
    public let totalKeyCount: Int
    /// 含私钥的密钥数（本机或卡上 stub —— v1 不区分硬件 / 软件，等 #26 落地后再拆）。
    public let secretKeyCount: Int

    public init(
        backendDescription: String,
        version: String,
        pinentryAvailable: Bool,
        agentAlive: Bool,
        gnupgHome: String?,
        totalKeyCount: Int,
        secretKeyCount: Int
    ) {
        self.backendDescription = backendDescription
        self.version = version
        self.pinentryAvailable = pinentryAvailable
        self.agentAlive = agentAlive
        self.gnupgHome = gnupgHome
        self.totalKeyCount = totalKeyCount
        self.secretKeyCount = secretKeyCount
    }
}

/// 拼诊断报告 + 抹掉密码痕迹。
///
/// 设计动机：用户来报「解压失败 / 创建失败」时往往只描述「不行」。
/// 让用户一键复制出包含 backend 路径 / 版本 / 命令输出尾段 / app + macOS 版本的报告，
/// 维护者读一次就能猜中根因。同时对 `-p<...>` / `-hp<...>` 这类命令行密码片段做脱敏 ——
/// 防止用户不假思索贴到公开 issue 里把密码也露出去。
public enum OperationDiagnosticsReporter {

    /// 对外入口：给一份 inputs，返回一段已经脱敏 + 截尾的纯文本，可以直接 setString 到剪贴板。
    public static func makeReport(from inputs: OperationDiagnosticsInputs) -> String {
        var lines: [String] = []
        lines.append("SimpleZip diagnostics")
        lines.append("=====================")
        lines.append("")
        lines.append("App version: \(inputs.appVersion) (build \(inputs.appBuild))")
        lines.append("macOS:       \(inputs.macOSVersion)")
        lines.append("")
        lines.append("Operation:   \(inputs.title)")
        lines.append("Started:     \(format(date: inputs.startedAt))")
        if let finished = inputs.finishedAt {
            let duration = finished.timeIntervalSince(inputs.startedAt)
            lines.append("Finished:    \(format(date: finished)) (\(format(durationSeconds: duration)))")
        } else {
            lines.append("Finished:    still running")
        }
        if let error = inputs.errorMessage, !error.isEmpty {
            lines.append("")
            lines.append("Error:")
            for errorLine in error.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("  \(sanitize(String(errorLine)))")
            }
        }
        lines.append("")
        lines.append("Backends:")
        lines.append("  7-Zip:  \(inputs.sevenZipDescription)")
        lines.append("          \(inputs.sevenZipVersion)")
        lines.append("  RAR:    \(inputs.rarDescription)")
        lines.append("          \(inputs.rarVersion)")
        if let gpg = inputs.gpgSection {
            lines.append("  GPG:    \(gpg.backendDescription)")
            lines.append("          \(gpg.version)")
            lines.append("          pinentry-mac: \(gpg.pinentryAvailable ? "ok" : "missing")")
            lines.append("          gpg-agent:    \(gpg.agentAlive ? "alive" : "not running")")
            lines.append("          GNUPGHOME:    \(gpg.gnupgHome ?? "(default ~/.gnupg)")")
            lines.append("          keys:         \(gpg.totalKeyCount) total, \(gpg.secretKeyCount) with secret key")
        }
        if let fileSystem = inputs.fileSystemSummary, !fileSystem.isEmpty {
            lines.append("")
            lines.append("File system:")
            for fsLine in fileSystem.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("  \(fsLine)")
            }
        }
        lines.append("")
        lines.append("Command output (sanitized, last \(inputs.outputTailCharacterLimit) chars):")
        lines.append("-----")
        lines.append(sanitize(tail(of: inputs.rawOutput, characterLimit: inputs.outputTailCharacterLimit)))
        lines.append("-----")
        return lines.joined(separator: "\n")
    }

    /// 暴露给测试 + 用于单独脱敏一段错误文本时调用。
    /// 规则只针对「命令行风格」的密码携带方式：
    ///   `-p<value>` / `-hp<value>` 形式 —— 7zz / rar 把密码塞 stdin 而不是 argv，
    ///   所以「正常」运行里不会出现这种串；但如果用户在自定义 raw 参数里手填了密码、
    ///   或第三方 CLI 把密码 echo 回了 stdout，就会被捕到。
    /// 抹掉规则：把值替换成 `[REDACTED]`，保留参数前缀方便排错。
    public static func sanitize(_ text: String) -> String {
        let pattern = #"(?<![A-Za-z0-9])(-h?p)([^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "$1[REDACTED]"
        )
    }

    // MARK: - 私有辅助

    /// 取字符串末尾不超过 `characterLimit` 个字符；超过时在前面加 `... (truncated)\n`。
    /// 这里用 Swift String 而不是 UTF-8 字节，因为命令输出里可能有中文 —— 按 grapheme cluster 截断更稳。
    private static func tail(of text: String, characterLimit: Int) -> String {
        guard text.count > characterLimit else {
            return text
        }
        let suffix = String(text.suffix(characterLimit))
        return "... (truncated)\n" + suffix
    }

    /// 用固定 ISO 风格格式 —— iOS / macOS locale 影响 `.long` 输出，
    /// 同一段诊断在不同用户机子上看着不一样会影响沟通效率，所以这里固定。
    private static func format(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter.string(from: date)
    }

    private static func format(durationSeconds: TimeInterval) -> String {
        if durationSeconds < 1 {
            return String(format: "%.0f ms", durationSeconds * 1000)
        }
        if durationSeconds < 60 {
            return String(format: "%.1f s", durationSeconds)
        }
        let minutes = Int(durationSeconds / 60)
        let seconds = Int(durationSeconds.truncatingRemainder(dividingBy: 60))
        return "\(minutes) min \(seconds) s"
    }
}

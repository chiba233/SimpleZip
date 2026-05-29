//
//  GPGBackend.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/29.
//

import Foundation

/// GnuPG CLI 后端 —— 探测 / 元信息 / 后续会承担「列出密钥 / 导入公钥 / 签名压缩包 / 验签」等动作。
///
/// 跟其它 backend (7zz / RAR / NativeZip / DMG) 的关键差别：
/// - **不**内置 gpg 二进制 —— GnuPG 是 GPL，本身不复杂，但依赖链（libgpg-error / libgcrypt / libassuan /
///   libksba / npth / pinentry-mac …）多到本地脚本编译不现实；让用户走 `brew install gnupg` 或者装
///   GPGTools 的官方签名 macOS 安装包是唯一合理选择。
/// - 私钥 / passphrase 全交给 `gpg-agent` + `pinentry-mac` —— SimpleZip 自己**不**碰 passphrase
///   （安全敏感且容易写错）。只要用户的 brew gnupg 安装包带了 pinentry-mac（默认就带）就行。
///
/// 设计动机：跟其它 backend 一样，让上层（Settings GPG pane / 创建对话框 / 验签流程）只调本 namespace 的
/// 静态方法，不用关心 gpg 路径在哪、版本怎么解析、子进程怎么跑。
///
/// **GPG 功能全可选**：`AppPreferences.gpgEnabled` 主开关关闭时，调用方应该完全跳过本 backend ——
/// 但本 backend 自己的方法仍然能正常工作（探测后端可用性等纯查询行为不依赖主开关）。
enum GPGBackend {

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

    // MARK: - 密钥管理

    /// 列出 keyring 里所有公钥 —— 用 `gpg --list-keys --with-colons --fingerprint` 拿机器可读输出。
    /// 同时跑一次 `--list-secret-keys` 标记哪些有私钥（能签名 / 解密）。
    static func listKeys() async throws -> [GPGKey] {
        let tool = try resolve()
        let publicOutput = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: ["--list-keys", "--with-colons", "--fingerprint"]
        )
        let secretOutput = (try? await BackendProcessRunner.runAndCapture(
            tool,
            arguments: ["--list-secret-keys", "--with-colons", "--fingerprint"]
        )) ?? ""
        // sec = 本机持有完整私钥；sec# = 仅 stub（私钥不在本机，典型场景是智能卡 / OpenPGP token）。
        // 两者都属于「有私钥」，但 UI 上要分组展示，让用户知道哪些密钥用起来需要插卡。
        let secretFingerprints = Set(parseFingerprints(in: secretOutput, recordPrefix: "sec"))
        let stubFingerprints = Set(parseFingerprints(in: secretOutput, recordPrefix: "sec", requireStubFlag: true))
        return parseColonsList(publicOutput, secretFingerprints: secretFingerprints, stubFingerprints: stubFingerprints)
    }

    /// 修改某把密钥的 owner trust 等级。
    ///
    /// gpg `--edit-key <fpr>` 是 interactive menu，没有 `--quick-set-trust` 这种简便参数（部分新版有但兼容差）。
    /// 这里用 `--command-fd 0 --batch` 走 stdin 喂命令序列：`trust\n<n>\ny\nsave\n`。
    /// `--batch` 让 gpg 不去 prompt 确认；最后 `save` 而不是 `quit` 让设置落盘。
    /// 不可设置的等级（unknown / expired / revoked）调用方应在 UI 层拦住，本函数对那些 case 不做事。
    static func setTrustLevel(fingerprint: String, to level: GPGTrustLevel) async throws {
        guard let menuNumber = level.editTrustMenuNumber else {
            throw ArchiveError.commandFailed("Trust level \(level.rawValue) is read-only and cannot be set")
        }
        let tool = try resolve()
        // 命令序列：进入 trust 子菜单 → 选数字 → 对 "Do you really want to set this key to ultimate trust?" 回答 y
        // → save 退出。ultimate 比 marginal/full/never 多一个确认 prompt，统一加 y 不会有问题（其它等级 gpg 直接忽略）。
        let commands = "trust\n\(menuNumber)\ny\nsave\n"
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: [
                "--batch",
                "--yes",
                "--no-tty",
                "--command-fd", "0",
                "--edit-key", fingerprint
            ],
            inputStrategy: .staticInput(commands)
        )
    }

    /// 从插入的 OpenPGP 智能卡 / token 上读取公钥并导入本机 keyring（生成 sec# stub）。
    ///
    /// `gpg --card-status` 跑一次 ping 卡 —— 失败说明卡没插好 / 没驱动 / scdaemon 出问题。
    /// 通过后跑 `gpg --card-edit fetch quit`：gpg 解析卡上记录的 OpenPGP URL（Issuer 字段）回 keyserver 拿对应公钥；
    /// 如果卡上没设 URL，这步会失败，要靠 `gpg --card-edit generate` 之类才能造一份 —— 那个属于「在卡上新建密钥」
    /// 是 #26 不做的范围，本函数只覆盖「卡上已有密钥 + 已设公钥 URL」的常见场景。
    @discardableResult
    static func importFromSmartcard() async throws -> String {
        let tool = try resolve()
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: ["--card-status"]
        )
        // --card-edit 是 interactive menu，跟 trust 同样走 --command-fd 0 喂命令。
        return try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: [
                "--batch",
                "--yes",
                "--no-tty",
                "--command-fd", "0",
                "--card-edit"
            ],
            inputStrategy: .staticInput("fetch\nquit\n")
        )
    }

    /// 导入公钥（也兼容导入公私钥对，gpg 自动识别）。
    /// `gpg --import` 输出的 status 文本里包含「imported / unchanged / processed」等信息，转给调用方做提示。
    @discardableResult
    static func importKey(from fileURL: URL) async throws -> String {
        let tool = try resolve()
        // `--with-colons` 让输出更可控；但 `--import` 通常输出在 stderr，BackendProcessRunner 已合并。
        return try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: ["--import", "--no-tty", fileURL.path]
        )
    }

    /// 用指定私钥给压缩包做 detached signature，产物 `<archive>.asc`（ASCII armor 格式）。
    /// 密码框由 gpg-agent + pinentry-mac 自己弹，本函数完全不接触 passphrase。
    /// signingKeyFingerprint 为 nil → 让 gpg 用 default-key（用户没配 default 时用第一把可用私钥）。
    static func sign(
        archiveURL: URL,
        signingKeyFingerprint: String?,
        operationID: UUID? = nil
    ) async throws -> URL {
        let tool = try resolve()
        let signatureURL = archiveURL.appendingPathExtension("asc")
        // 已存在 → 先删，否则 gpg 会拒绝覆盖。
        try? FileManager.default.removeItem(at: signatureURL)
        var arguments: [String] = ["--batch", "--yes", "--armor", "--detach-sign"]
        if let key = signingKeyFingerprint {
            arguments.append(contentsOf: ["--local-user", key])
        }
        arguments.append(contentsOf: ["--output", signatureURL.path, archiveURL.path])
        _ = try await BackendProcessRunner.runAndCapture(tool, arguments: arguments, operationID: operationID)
        return signatureURL
    }

    /// 验签 —— `gpg --verify <archive>.asc <archive>`。
    /// gpg 退出码 ≠ 0 → 签名无效；退出码 == 0 但「未知签名者」也是常见情况（公钥不在 keyring）。
    /// 用状态机解析 stderr/stdout 的 `Good signature from / BAD signature / unknown` 关键字。
    static func verify(
        archiveURL: URL,
        signatureURL: URL,
        operationID: UUID? = nil
    ) async throws -> GPGVerifyResult {
        let tool = try resolve()
        do {
            let output = try await BackendProcessRunner.runAndCapture(
                tool,
                arguments: ["--verify", signatureURL.path, archiveURL.path],
                operationID: operationID
            )
            return parseVerifyOutput(output, exitOk: true)
        } catch {
            // gpg 退出码 != 0 时 BackendProcessRunner 抛错；把错误信息当 stderr 输出处理。
            let errorOutput = (error as? ArchiveError).flatMap { archiveError in
                if case .commandFailed(let text) = archiveError { return text }
                return nil
            } ?? error.localizedDescription
            return parseVerifyOutput(errorOutput, exitOk: false)
        }
    }

    // MARK: - 输出解析

    /// gpg `--with-colons` 协议：每行多个字段用 `:` 分隔。
    /// 记录类型在第 0 字段：`pub` / `sub` / `sec` / `ssb` / `uid` / `fpr` / `tru` / 等。
    /// 我们关心：
    /// - `pub:trust:keylength:algo:keyid:created:expires:certificateSerial:trust:userId:signClass:capabilities:...`
    /// - `uid:trust:::created::userIDHash:::userID:::...`
    /// - `fpr:::::::::fingerprint:`
    /// 状态机：遇到 `pub` 开新 key 收集；遇到 `fpr` 填 fingerprint；遇到 `uid` 填 primary UID（第一条）。
    private static func parseColonsList(
        _ output: String,
        secretFingerprints: Set<String>,
        stubFingerprints: Set<String>
    ) -> [GPGKey] {
        var keys: [GPGKey] = []
        var currentFingerprint: String?
        var currentUserID: String?
        var currentExpired = false
        var currentTrust: GPGTrustLevel = .unknown
        var collecting = false

        func flush() {
            if collecting, let fp = currentFingerprint {
                let uid = currentUserID ?? fp
                let hasSecret = secretFingerprints.contains(fp) || stubFingerprints.contains(fp)
                keys.append(GPGKey(
                    fingerprint: fp,
                    userID: uid,
                    hasSecretKey: hasSecret,
                    isSecretKeyStub: stubFingerprints.contains(fp),
                    isExpired: currentExpired,
                    trust: currentTrust
                ))
            }
            currentFingerprint = nil
            currentUserID = nil
            currentExpired = false
            currentTrust = .unknown
            collecting = false
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = rawLine.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard let recordType = fields.first else { continue }
            switch recordType {
            case "pub", "sec":
                flush()
                collecting = true
                // 第 1 字段：trust / validity 单字符。`e` = expired，`r` = revoked，`-` = unknown，u/f/m/n = 已设置等级。
                if fields.count > 1 {
                    let raw = fields[1]
                    if raw == "e" || raw == "r" {
                        currentExpired = true
                    }
                    currentTrust = GPGTrustLevel.parse(raw)
                }
            case "fpr":
                // 第 9 字段是 fingerprint
                if collecting, fields.count > 9, currentFingerprint == nil {
                    currentFingerprint = fields[9]
                }
            case "uid":
                // 第 9 字段是 user ID 文本（含 Name <email>）；只取第一条作为 primary。
                // uid 行有自己的 trust 字段（field 1），但我们更看重 pub 行的 trust（owner trust），uid trust 是 validity。
                if collecting, fields.count > 9, currentUserID == nil, !fields[9].isEmpty {
                    currentUserID = fields[9]
                }
            default:
                break
            }
        }
        flush()
        return keys
    }

    /// 仅提取指定记录前缀（`pub` / `sec`）后跟的 fingerprint，给 listKeys 做「这个 fingerprint 有私钥吗」交叉引用。
    /// `requireStubFlag = true` 时只匹配带 `#` 后缀的 stub 记录（如 `sec#`），用来识别智能卡 / OpenPGP token 上的密钥。
    private static func parseFingerprints(
        in output: String,
        recordPrefix: String,
        requireStubFlag: Bool = false
    ) -> [String] {
        var fingerprints: [String] = []
        var inTargetRecord = false
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = rawLine.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard let recordType = fields.first else { continue }
            // gpg 输出里 stub 标记直接在记录类型后跟 `#`（如 `sec#`、`ssb#`）；用第 14 字段（serial）有时也能区分。
            // 这里走最稳的路：检查 fields[14] 是否含 SmartCard serial / `>` / 第 1 字段是否 `#` 不可用。
            // 实际 gpg 在 --with-colons 输出 sec# 时记录类型就是 "sec#"（第 0 字段直接带 #）。所以正常 parse 切 ':' 不会丢这个标记。
            let baseType = recordType.replacingOccurrences(of: "#", with: "")
            let isStubLine = recordType.hasSuffix("#")

            if baseType == recordPrefix {
                if requireStubFlag {
                    inTargetRecord = isStubLine
                } else {
                    inTargetRecord = true
                }
            } else if recordType == "fpr", inTargetRecord, fields.count > 9 {
                fingerprints.append(fields[9])
                inTargetRecord = false
            } else if baseType == "pub" || baseType == "sec" {
                inTargetRecord = false
            }
        }
        return fingerprints
    }

    /// 把 gpg --verify 的人类可读输出转成 status enum。
    private static func parseVerifyOutput(_ output: String, exitOk: Bool) -> GPGVerifyResult {
        // gpg 输出里的关键字（英文，gpg CLI 不本地化这些）：
        //   "Good signature from \"<uid>\""
        //   "BAD signature from \"<uid>\""
        //   "Can't check signature: No public key"
        //   "WARNING: This key is not certified with a trusted signature"
        // 注意 BAD 是大写。
        let lowered = output.lowercased()
        let signer = extractSignerName(from: output)

        if lowered.contains("bad signature") {
            return .badSignature(signer: signer)
        }
        if lowered.contains("can't check signature") || lowered.contains("no public key") {
            // 未导入公钥；尝试提取 fingerprint / key id 让 UI 提供「一键导入」入口
            let unknownKeyID = extractUnknownKeyID(from: output)
            return .unknownSigner(keyID: unknownKeyID)
        }
        if lowered.contains("good signature") {
            let trusted = !lowered.contains("not certified with a trusted signature")
            return .validSignature(signer: signer, trusted: trusted)
        }
        // 兜底：退出码失败但没识别出任何关键字 —— 跟原始输出一起报给用户。
        return exitOk ? .validSignature(signer: signer, trusted: false) : .verificationError(message: output)
    }

    private static func extractSignerName(from output: String) -> String? {
        // 匹配 `Good signature from "<text>"` 里的引号内容。
        // 不上正则避免引入 NSRegularExpression 开销；手动扫一遍 line by line。
        for line in output.split(separator: "\n") {
            let lower = line.lowercased()
            guard lower.contains("signature from") else { continue }
            if let openQuote = line.firstIndex(of: "\""),
               let closeQuote = line[line.index(after: openQuote)...].firstIndex(of: "\"") {
                return String(line[line.index(after: openQuote)..<closeQuote])
            }
        }
        return nil
    }

    private static func extractUnknownKeyID(from output: String) -> String? {
        // "using RSA key ABCD1234..." 之类的提示里抽 key id。
        for line in output.split(separator: "\n") {
            guard line.lowercased().contains("using") else { continue }
            // 取最后一个像 hex id 的 token（16+ 位的 0-9A-F）
            for token in line.split(separator: " ") {
                let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'."))
                if cleaned.count >= 16, cleaned.allSatisfy({ $0.isHexDigit }) {
                    return cleaned
                }
            }
        }
        return nil
    }

    // MARK: - 候选路径

    /// GPG 在 macOS 上的典型安装位置：
    /// - Homebrew (Apple Silicon: `/opt/homebrew/bin/gpg`，Intel: `/usr/local/bin/gpg`)
    /// - GPGTools (`/usr/local/MacGPG2/bin/gpg` 或 `/opt/homebrew/MacGPG2/bin/gpg`，老版本可能装在这里)
    /// - $PATH 兜底
    /// 信任级别 —— gpg `--with-colons` 输出 `pub`/`uid` 记录第 2 字段的字符映射。
    /// 用户通过 `setTrustLevel(...)` 修改时，对应 gpg `--edit-key trust` 菜单的 1-5 数字。
    /// `expired` / `revoked` 不是用户可设置的等级，是 gpg 报告的密钥状态 —— UI 把它们渲染成红色但 picker 里不出现。
    enum GPGTrustLevel: String, CaseIterable, Hashable {
        case unknown    // gpg field "-"，新导入的他人公钥默认值
        case never      // gpg field "n"，gpg menu trust → 2
        case marginal   // gpg field "m"，gpg menu trust → 3
        case full       // gpg field "f"，gpg menu trust → 4
        case ultimate   // gpg field "u"，gpg menu trust → 5（本人自有密钥默认）
        case expired    // gpg field "e"
        case revoked    // gpg field "r"

        /// 从 gpg --with-colons 输出第 2 字段单字符解析。
        static func parse(_ raw: String) -> GPGTrustLevel {
            switch raw {
            case "n": return .never
            case "m": return .marginal
            case "f": return .full
            case "u": return .ultimate
            case "e": return .expired
            case "r": return .revoked
            default: return .unknown
            }
        }

        /// 喂给 `gpg --command-fd 0 trust` menu 的数字（unknown / expired / revoked 不可设置，返回 nil）。
        var editTrustMenuNumber: String? {
            switch self {
            case .never: return "2"
            case .marginal: return "3"
            case .full: return "4"
            case .ultimate: return "5"
            case .unknown, .expired, .revoked: return nil
            }
        }

        /// picker 里可选项 —— 不含 expired / revoked（密钥状态，不是用户可设置的）；含 unknown 让用户撤回 trust 设置。
        static var userAssignableCases: [GPGTrustLevel] {
            [.unknown, .never, .marginal, .full, .ultimate]
        }
    }

    /// Keyring 里的一把密钥（primary key + 首条 UID + 私钥状态 + 信任级别）。
    /// 故意不展开 subkey 列表 / 创建时间等细节 —— 当前 UI 只需要「分三类 + 挑一个签名 + 调整信任」。
    struct GPGKey: Identifiable, Hashable {
        let fingerprint: String
        let userID: String
        let hasSecretKey: Bool
        /// `true` = 私钥在本机有 stub 但完整密钥材料不在（典型场景：智能卡 / OpenPGP token，gpg 输出 `sec#`）。
        /// 签名 / 解密时需要插入对应卡，否则 gpg-agent 会卡。
        let isSecretKeyStub: Bool
        let isExpired: Bool
        let trust: GPGTrustLevel

        var id: String { fingerprint }

        /// `2A2A 2A2A 2A2A 2A2A 2A2A 2A2A 2A2A 2A2A 2A2A 2A2A` —— 给 UI 用的可读 fingerprint。
        var displayFingerprint: String {
            var formatted = ""
            for (index, char) in fingerprint.enumerated() {
                if index > 0, index % 4 == 0 {
                    formatted.append(" ")
                }
                formatted.append(char)
            }
            return formatted
        }
    }

    /// 验签结果四态。`signer` 取自 gpg 输出的「Good signature from "Name <email>"」。
    enum GPGVerifyResult: Equatable {
        /// 公钥在 keyring 里 + 签名匹配 + 文件未被改动。
        /// `trusted` 表示 gpg 没抛「This key is not certified」警告（信任级别足够）。
        case validSignature(signer: String?, trusted: Bool)
        /// 签名匹配但公钥不在 keyring。提供 `keyID` 让 UI 给「一键导入」入口。
        case unknownSigner(keyID: String?)
        /// 签名失败 = 文件被改动 / 签名损坏。最严重的状态。
        case badSignature(signer: String?)
        /// gpg 命令本身失败（非签名层面错误）。
        case verificationError(message: String)
    }

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

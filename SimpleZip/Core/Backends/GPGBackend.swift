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

    // MARK: - 私有 keyring（SimpleZip 自有）

    /// SimpleZip 私有 keyring 目录 `~/Library/Application Support/SimpleZip/keyring/`。
    /// 「他人公钥」导入到这里，**绝不**写入用户 `~/.gnupg/`，卸载 SimpleZip 不留痕。
    static func simpleZipKeyringDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("SimpleZip", isDirectory: true)
            .appendingPathComponent("keyring", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// SimpleZip 私有公钥 ring 文件路径 (`pubring.kbx`)。
    /// gpg 第一次写入时自动创建文件 —— 我们只确保目录存在。
    static func simpleZipPubringPath() -> URL {
        simpleZipKeyringDirectory().appendingPathComponent("pubring.kbx")
    }

    /// 给 gpg invocation 拼上「读取 SimpleZip ring」用的参数 —— `--keyring <path>` 是叠加搜索（默认 ring 仍参与）。
    /// 写 SimpleZip ring 的场合还需要追加 `--no-default-keyring`，让 default ring 不参与写入；调用方自己拼。
    static func simpleZipKeyringArguments() -> [String] {
        ["--keyring", simpleZipPubringPath().path]
    }

    // MARK: - 密钥管理

    /// 列出**两个 ring 合并**的公钥列表：
    /// - 默认 ring（`~/.gnupg/`）：用户 CLI 共享的钥匙串，私钥也在这里；
    /// - SimpleZip 私有 ring：仅 SimpleZip 导入的他人公钥。
    ///
    /// 私钥 / 智能卡 stub / stripped 标记**只**来自默认 ring（私钥本就属于用户的 GPG 设置）。
    /// 同一 fingerprint 在两个 ring 都出现时：以 `.userKeyring` 那条为准，SimpleZip ring 那条丢弃（去重）。
    static func listKeys() async throws -> [GPGKey] {
        let userKeys = try await listKeys(from: .userKeyring)
        let simpleZipKeys = (try? await listKeys(from: .simpleZipKeyring)) ?? []

        var seen = Set<String>()
        var merged: [GPGKey] = []
        for key in userKeys {
            merged.append(key)
            seen.insert(key.fingerprint)
        }
        for key in simpleZipKeys where !seen.contains(key.fingerprint) {
            merged.append(key)
            seen.insert(key.fingerprint)
        }
        return merged
    }

    /// 列出**单个 ring** 的公钥列表。给 `listKeys()` 合并逻辑用 + 单测可分别覆盖两 ring 解析。
    ///
    /// **智能卡检测两条独立路径**（互相补，命中任一即标卡上）：
    /// 1. 解析 `--list-secret-keys --with-colons` 输出里的 stub 标记（type 后缀 / field 14）—— gpg 版本敏感，不一定 100% 可靠。
    /// 2. 跑 `--card-status --with-colons` 直接问卡本身报告的 subkey fingerprints —— 卡上报告即权威，跨 gpg 版本稳定。
    static func listKeys(from source: GPGKeyringSource) async throws -> [GPGKey] {
        let tool = try resolve()
        var listArguments = ["--list-keys", "--with-colons", "--fingerprint"]
        var secretListArguments = ["--list-secret-keys", "--with-colons", "--fingerprint"]
        if source == .simpleZipKeyring {
            let szArgs = ["--no-default-keyring"] + simpleZipKeyringArguments()
            listArguments = szArgs + listArguments
            secretListArguments = szArgs + secretListArguments
        }

        let publicOutput: String
        do {
            publicOutput = try await BackendProcessRunner.runAndCapture(tool, arguments: listArguments)
        } catch {
            // SimpleZip ring 文件不存在时 gpg 可能直接报错（首次启动场景）；视为空列表。
            if source == .simpleZipKeyring {
                return []
            }
            throw error
        }

        let secretOutput = (try? await BackendProcessRunner.runAndCapture(tool, arguments: secretListArguments)) ?? ""

        // colons 解析（路径 1）
        let fullSecret = Set(parseFingerprints(in: secretOutput, recordPrefix: "sec", mode: .fullSecret))
        var smartcardPrimary = Set(parseFingerprints(in: secretOutput, recordPrefix: "sec", mode: .smartcard))
        let strippedPrimary = Set(parseFingerprints(in: secretOutput, recordPrefix: "sec", mode: .stripped))
        var smartcardSubkey = Set(parseFingerprints(in: secretOutput, recordPrefix: "ssb", mode: .smartcard))
        let strippedSubkey = Set(parseFingerprints(in: secretOutput, recordPrefix: "ssb", mode: .stripped))

        // 直接问卡（路径 2）—— 仅默认 ring 时才查（SimpleZip ring 不存私钥，没卡 stub 概念）。
        // card-status 在没插卡时返回非 0 退出码，我们当作空集合 silently 处理。
        if source == .userKeyring {
            let cardFingerprints = await collectCardFingerprintSet()
            smartcardPrimary.formUnion(cardFingerprints)
            smartcardSubkey.formUnion(cardFingerprints)
        }

        return parseColonsList(
            publicOutput,
            secretFingerprints: fullSecret,
            smartcardFingerprints: smartcardPrimary,
            strippedFingerprints: strippedPrimary,
            smartcardSubkeyFingerprints: smartcardSubkey,
            strippedSubkeyFingerprints: strippedSubkey,
            source: source
        )
    }

    /// 跑 `gpg --card-status --with-colons` 抽出卡上 subkey fingerprint 集合。
    ///
    /// 这是「权威路径」——卡硬件本身报告的 fingerprint 一定是卡上的密钥，跨 gpg 版本稳定。
    /// 没插卡时退出码 ≠ 0，BackendProcessRunner 抛错，我们 silently 返回空集；不要 noisy 干扰用户。
    /// 没有 timeout，但 card-status 在 scdaemon 正常时一般 100ms 内返回；scdaemon 死掉时可能等几秒。
    private static func collectCardFingerprintSet() async -> Set<String> {
        guard let tool = try? resolve() else { return [] }
        guard let output = try? await BackendProcessRunner.runAndCapture(
            tool,
            arguments: ["--card-status", "--with-colons"]
        ) else { return [] }

        var fingerprints: Set<String> = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = rawLine.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard let recordType = fields.first?.lowercased(), recordType == "fpr" else { continue }
            // fpr:<sign_fp>:<enc_fp>:<auth_fp>: 三段，按 OpenPGP card spec。
            // 任意一段非空且像 40 字符 hex 都收集进来 —— 校验 hex 由 listKeys 反查 keyring 时自然 dedup。
            for field in fields.dropFirst() {
                let trimmed = field.trimmingCharacters(in: .whitespaces)
                if trimmed.count >= 40, trimmed.allSatisfy({ $0.isHexDigit }) {
                    fingerprints.insert(trimmed)
                }
            }
        }
        return fingerprints
    }

    /// 当前插入卡片的 snapshot —— UI 展示「这张卡绑定了哪个公钥」用。
    ///
    /// 从 `gpg --card-status --with-colons` 输出里读：
    /// - 卡 serial number（field 2 of `Reader` record，或者 `serial:` line）
    /// - 三个用途的 subkey fingerprint（`fpr:0:sign:` / `fpr:1:enc:` / `fpr:2:auth:` 风格输出）
    /// 然后把第一个非空 subkey fingerprint 反查 listKeys 找到所属主密钥，告诉调用方「这张卡对应的主密钥是哪把」。
    static func cardStatus() async throws -> GPGCardStatus? {
        let tool = try resolve()
        let output: String
        do {
            output = try await BackendProcessRunner.runAndCapture(
                tool,
                arguments: ["--card-status", "--with-colons"]
            )
        } catch {
            return nil
        }

        var serial: String?
        var vendor: String?
        var holderName: String?
        var subkeyFingerprints: [String] = []

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = rawLine.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard let recordType = fields.first else { continue }
            switch recordType.lowercased() {
            case "reader":
                if fields.count > 3, !fields[3].isEmpty {
                    vendor = fields[3]
                }
            case "serial":
                if fields.count > 1, !fields[1].isEmpty {
                    serial = fields[1]
                }
            case "name":
                if fields.count > 2 {
                    let trimmed = "\(fields[1]) \(fields[2])".trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        holderName = trimmed
                    }
                }
            case "fpr":
                // fpr:<sign>:<enc>:<auth>: 三段
                let fps = fields.dropFirst().filter { !$0.isEmpty }
                subkeyFingerprints.append(contentsOf: fps)
            default:
                break
            }
        }

        guard !subkeyFingerprints.isEmpty || serial != nil else { return nil }

        // 反查所属主密钥：跟当前 listKeys 结果做 subkey fingerprint 比对（任何一个匹配即可）。
        let allKeys = (try? await listKeys()) ?? []
        let linkedPrimary = subkeyFingerprints.lazy.compactMap { subFp -> String? in
            for key in allKeys {
                if key.fingerprint == subFp { return key.fingerprint }
                if key.subkeys.contains(where: { $0.fingerprint == subFp }) {
                    return key.fingerprint
                }
            }
            return nil
        }.first

        return GPGCardStatus(
            serial: serial,
            vendor: vendor,
            holderName: holderName,
            subkeyFingerprints: subkeyFingerprints,
            linkedPrimaryFingerprint: linkedPrimary
        )
    }

    /// 修改某把密钥的 owner trust 等级。
    ///
    /// `source` 决定 gpg 操作哪个 ring：`.userKeyring` 走默认（用户 `~/.gnupg`）；
    /// `.simpleZipKeyring` 加 `--no-default-keyring --keyring <SZ>` 让操作只命中 SimpleZip 私有 ring。
    static func setTrustLevel(fingerprint: String, to level: GPGTrustLevel, source: GPGKeyringSource = .userKeyring) async throws {
        guard let menuNumber = level.editTrustMenuNumber else {
            throw ArchiveError.commandFailed("Trust level \(level.rawValue) is read-only and cannot be set")
        }
        let tool = try resolve()
        let commands = "trust\n\(menuNumber)\ny\nsave\n"
        var args = [
            "--batch",
            "--yes",
            "--no-tty",
            "--command-fd", "0"
        ]
        if source == .simpleZipKeyring {
            args.insert("--no-default-keyring", at: 0)
            args.append(contentsOf: simpleZipKeyringArguments())
        }
        args.append(contentsOf: ["--edit-key", fingerprint])
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: args,
            inputStrategy: .staticInput(commands)
        )
    }

    /// 导出公钥为 ASCII armor (`.asc`) 文本。
    /// `source = .simpleZipKeyring` 时只从 SimpleZip ring 查；`.userKeyring` 走默认。
    static func exportPublicKey(fingerprint: String, source: GPGKeyringSource = .userKeyring) async throws -> String {
        let tool = try resolve()
        var args: [String] = []
        if source == .simpleZipKeyring {
            args.append("--no-default-keyring")
            args.append(contentsOf: simpleZipKeyringArguments())
        }
        args.append(contentsOf: ["--armor", "--export", fingerprint])
        return try await BackendProcessRunner.runAndCapture(tool, arguments: args)
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

    /// 导入公钥（也兼容公私钥对，gpg 自动识别）到指定 ring。
    ///
    /// `into = .userKeyring`（默认）：写用户 `~/.gnupg/` —— 跟 CLI 共享，旧行为。
    /// `into = .simpleZipKeyring`：仅写 SimpleZip 私有 ring —— 不污染用户 CLI keyring（user 卸 app 后无痕）。
    ///   注意：用户文件如果包含私钥，gpg 仍可能把私钥写进 ~/.gnupg/（gpg 的私钥环跟公钥环独立）；这种场景由 UI 提示。
    @discardableResult
    static func importKey(from fileURL: URL, into ring: GPGKeyringSource = .userKeyring) async throws -> String {
        let tool = try resolve()
        var args = ["--import", "--no-tty"]
        if ring == .simpleZipKeyring {
            args.insert("--no-default-keyring", at: 0)
            args.append(contentsOf: simpleZipKeyringArguments())
        }
        args.append(fileURL.path)
        return try await BackendProcessRunner.runAndCapture(tool, arguments: args)
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
        // 验签时把 SimpleZip 私有 ring 加进 gpg 的搜索路径，让用户「导入到 SimpleZip 钥匙串」的他人公钥也能用来验签。
        // `--keyring <path>` 是**叠加**搜索（default ring 仍参与），所以 ~/.gnupg/ 的密钥仍然有效。
        let verifyArgs = simpleZipKeyringArguments() + ["--verify", signatureURL.path, archiveURL.path]
        do {
            let output = try await BackendProcessRunner.runAndCapture(
                tool,
                arguments: verifyArgs,
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
    /// 解析 `--list-keys --with-colons --fingerprint` 的合并 stdout，吐出 GPGKey 数组（含 subkeys）。
    ///
    /// 关键点：
    /// - **stub 标记两种**：`>` (`sec>`/`ssb>`) = 私钥在智能卡上；`#` (`sec#`/`ssb#`) = 私钥已从本机 stripped。
    ///   两者都属于「本机没有完整私钥材料」，但语义不同，要分别记下来给 UI 用。
    /// - **subkey 解析**：每个 `pub`/`sec` 起一个 primary key 上下文；后续 `sub`/`ssb` 都挂到当前 primary 的 subkeys 列表里；
    ///   每个 sub/ssb 后面跟一个 fpr 行（subkey fingerprint）+ 自己的 cap 字段（field 11 of sub record）。
    /// - **capability flags**：field 11 含 `s`/`e`/`a`/`c` 字符。小写 = subkey 本身有此能力；大写 = 整个 key 组合有（看主密钥能力时用大写）。
    private static func parseColonsList(
        _ output: String,
        secretFingerprints: Set<String>,
        smartcardFingerprints: Set<String>,
        strippedFingerprints: Set<String>,
        smartcardSubkeyFingerprints: Set<String>,
        strippedSubkeyFingerprints: Set<String>,
        source: GPGKeyringSource
    ) -> [GPGKey] {
        var keys: [GPGKey] = []
        var primaryFingerprint: String?
        var primaryUserID: String?
        var primaryExpired = false
        var primaryTrust: GPGTrustLevel = .unknown
        var primaryCapabilities = ""
        var primarySubkeys: [GPGSubkey] = []
        var collectingPrimary = false

        // 子密钥临时状态。`sub`/`ssb` 行先填基础字段，下一条 `fpr` 行填 fingerprint，最后 flush 时挂到 primary 的 subkeys。
        var pendingSubkey: (capabilities: String, isExpired: Bool, isOnSmartcard: Bool, isStripped: Bool)?
        var pendingSubkeyFingerprint: String?

        func flushSubkey() {
            guard let pending = pendingSubkey, let fp = pendingSubkeyFingerprint else {
                pendingSubkey = nil
                pendingSubkeyFingerprint = nil
                return
            }
            // 如果在 secret keys listing 里被标了 smartcard / stripped 也合并进来（field 14 / record suffix 哪个先到都行）。
            let onCard = pending.isOnSmartcard || smartcardSubkeyFingerprints.contains(fp)
            let stripped = pending.isStripped || strippedSubkeyFingerprints.contains(fp)
            primarySubkeys.append(GPGSubkey(
                fingerprint: fp,
                capabilities: pending.capabilities,
                isOnSmartcard: onCard,
                isStripped: stripped,
                isExpired: pending.isExpired
            ))
            pendingSubkey = nil
            pendingSubkeyFingerprint = nil
        }

        func flushPrimary() {
            flushSubkey()
            if collectingPrimary, let fp = primaryFingerprint {
                let uid = primaryUserID ?? fp
                let hasSecret = secretFingerprints.contains(fp) || smartcardFingerprints.contains(fp) || strippedFingerprints.contains(fp)
                keys.append(GPGKey(
                    fingerprint: fp,
                    userID: uid,
                    hasSecretKey: hasSecret,
                    isSecretKeyOnSmartcard: smartcardFingerprints.contains(fp),
                    isSecretKeyStripped: strippedFingerprints.contains(fp),
                    isExpired: primaryExpired,
                    trust: primaryTrust,
                    capabilities: primaryCapabilities,
                    subkeys: primarySubkeys,
                    source: source
                ))
            }
            primaryFingerprint = nil
            primaryUserID = nil
            primaryExpired = false
            primaryTrust = .unknown
            primaryCapabilities = ""
            primarySubkeys = []
            collectingPrimary = false
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = rawLine.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard let recordTypeRaw = fields.first else { continue }
            // 记录类型可能带 stub 后缀 `#`（stripped）/ `>`（卡上）—— 剥掉再 switch，标记单独记。
            let isStripped = recordTypeRaw.hasSuffix("#")
            let isOnSmartcard = recordTypeRaw.hasSuffix(">")
            let recordType = (isStripped || isOnSmartcard) ? String(recordTypeRaw.dropLast()) : recordTypeRaw

            switch recordType {
            case "pub", "sec":
                flushPrimary()
                collectingPrimary = true
                // field 1：trust / validity 单字符。`e` = expired，`r` = revoked，`-` = unknown，u/f/m/n = 已设置等级。
                if fields.count > 1 {
                    let raw = fields[1]
                    if raw == "e" || raw == "r" {
                        primaryExpired = true
                    }
                    primaryTrust = GPGTrustLevel.parse(raw)
                }
                // field 11：capabilities
                if fields.count > 11 {
                    primaryCapabilities = fields[11]
                }
            case "sub", "ssb":
                flushSubkey()
                guard collectingPrimary else { continue }
                let subExpired = (fields.count > 1) && (fields[1] == "e" || fields[1] == "r")
                let subCapabilities = (fields.count > 11) ? fields[11] : ""
                pendingSubkey = (
                    capabilities: subCapabilities,
                    isExpired: subExpired,
                    isOnSmartcard: isOnSmartcard,
                    isStripped: isStripped
                )
            case "fpr":
                guard fields.count > 9, !fields[9].isEmpty else { continue }
                let fp = fields[9]
                // 优先填给「最近的待挂载 subkey」；否则当作 primary 的 fingerprint。
                if pendingSubkey != nil {
                    pendingSubkeyFingerprint = fp
                } else if collectingPrimary, primaryFingerprint == nil {
                    primaryFingerprint = fp
                }
            case "uid":
                if collectingPrimary, fields.count > 9, primaryUserID == nil, !fields[9].isEmpty {
                    primaryUserID = fields[9]
                }
            default:
                break
            }
        }
        flushPrimary()
        return keys
    }

    /// 从 `--list-secret-keys --with-colons` 输出里抽出指定状态的 fingerprint 集。
    ///
    /// 三种模式：
    /// - `.fullSecret`：本机有完整私钥（记录类型纯净的 `sec` / `ssb`）。
    /// - `.smartcard`：私钥在卡上（gpg 输出 `sec>` / `ssb>`）。
    /// - `.stripped`：私钥已 stripped（gpg 输出 `sec#` / `ssb#`）。
    ///
    /// `recordPrefix` 选 `sec`（主密钥）或 `ssb`（子密钥）；调用方对两者分别提取，合并到 GPGKey / GPGSubkey 的标记字段。
    private enum SecretKeyMode {
        case fullSecret
        case smartcard
        case stripped
    }

    private static func parseFingerprints(
        in output: String,
        recordPrefix: String,
        mode: SecretKeyMode = .fullSecret
    ) -> [String] {
        var fingerprints: [String] = []
        var inTargetRecord = false
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = rawLine.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard let recordTypeRaw = fields.first else { continue }
            // **两种 smartcard / stripped 标记位置都识别**：
            // - 旧 / 人类可读混合输出：type 字段后缀 `sec>` / `ssb>` / `sec#` / `ssb#`
            // - 现代 gpg `--with-colons` 输出：type 字段干净 `sec` / `ssb`，第 14 字段（index 13）含卡 serial（如 `F1D0+0131337E`），或为 `#` 表示 stripped
            let typeSuffixStripped = recordTypeRaw.hasSuffix("#")
            let typeSuffixOnCard = recordTypeRaw.hasSuffix(">")
            let baseType = (typeSuffixStripped || typeSuffixOnCard) ? String(recordTypeRaw.dropLast()) : recordTypeRaw
            let field14 = (fields.count > 13) ? fields[13] : ""
            // field 14 非空且不是 stripped 标记 = 卡 serial / token info
            let field14OnCard = !field14.isEmpty && field14 != "#"
            let field14Stripped = field14 == "#"
            let isStripped = typeSuffixStripped || field14Stripped
            let isOnSmartcard = typeSuffixOnCard || field14OnCard

            if baseType == recordPrefix {
                switch mode {
                case .fullSecret:
                    inTargetRecord = !isStripped && !isOnSmartcard
                case .smartcard:
                    inTargetRecord = isOnSmartcard
                case .stripped:
                    inTargetRecord = isStripped
                }
            } else if recordTypeRaw == "fpr", inTargetRecord, fields.count > 9 {
                fingerprints.append(fields[9])
                inTargetRecord = false
            } else if baseType == "pub" || baseType == "sec" || baseType == "sub" || baseType == "ssb" {
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

    /// 密钥来自哪个 keyring。SimpleZip 把「他人公钥」隔离到自己的私有 keyring，不污染用户 `~/.gnupg/`。
    /// 我们对自己的私钥（含智能卡 stub）永远只看 `.userKeyring` —— 私钥本就属于用户 GPG 设置，不分裂。
    enum GPGKeyringSource: String, CaseIterable, Hashable {
        case userKeyring        // ~/.gnupg/，跟 gpg CLI 共享
        case simpleZipKeyring   // ~/Library/Application Support/SimpleZip/keyring/pubring.kbx，SimpleZip 私有
    }

    /// 一把子密钥（subkey）。GPG 主密钥往往只用于「认证 / 颁发证书」，实际签名 / 加密 / 认证由各 subkey 干。
    /// 智能卡用户通常 3 副密钥（sign / encrypt / auth）全在卡上，UI 必须把它们各自展示出来。
    struct GPGSubkey: Identifiable, Hashable {
        let fingerprint: String
        /// gpg --with-colons 输出 field 11 的能力字符串：含 `s`(sign) / `e`(encrypt) / `a`(auth) / `c`(certify)。
        /// 小写 = 该 subkey 本身有此能力。
        let capabilities: String
        /// `true` = 私钥在卡上（gpg 输出 `ssb>`）。
        let isOnSmartcard: Bool
        /// `true` = gpg 已删除本机 stub（`ssb#`），没卡也用不了。
        let isStripped: Bool
        let isExpired: Bool

        var id: String { fingerprint }

        var canSign: Bool { capabilities.contains("s") }
        var canEncrypt: Bool { capabilities.contains("e") }
        var canAuthenticate: Bool { capabilities.contains("a") }

        var displayFingerprint: String { GPGKey.formatFingerprint(fingerprint) }
    }

    /// Keyring 里的一把密钥（primary key + 首条 UID + 私钥状态 + 信任级别 + 子密钥列表 + 来源 ring）。
    struct GPGKey: Identifiable, Hashable {
        let fingerprint: String
        let userID: String
        let hasSecretKey: Bool
        /// `true` = 私钥在卡上（gpg `sec>`）；签名 / 解密需要插卡。
        let isSecretKeyOnSmartcard: Bool
        /// `true` = 主密钥私钥已从本机 stripped（gpg `sec#`）；通常 subkey 还能用。
        let isSecretKeyStripped: Bool
        /// 兼容旧 UI 字段：「私钥不在本机」（卡上 或 stripped 都算）。
        var isSecretKeyStub: Bool { isSecretKeyOnSmartcard || isSecretKeyStripped }
        let isExpired: Bool
        let trust: GPGTrustLevel
        /// gpg field 11 capability 字符串（小写表示主密钥本身能力，大写表示整个组合能力 —— UI 主要看 subkey）。
        let capabilities: String
        let subkeys: [GPGSubkey]
        let source: GPGKeyringSource

        var id: String { fingerprint + ":" + source.rawValue }

        /// `2A2A 2A2A 2A2A 2A2A 2A2A 2A2A 2A2A 2A2A 2A2A 2A2A` —— 给 UI 用的可读 fingerprint。
        var displayFingerprint: String { Self.formatFingerprint(fingerprint) }

        /// 简短指纹（末 16 字符 = long key ID），UI 在密度高的场合用。
        var shortFingerprint: String {
            String(fingerprint.suffix(16))
        }

        static func formatFingerprint(_ raw: String) -> String {
            var formatted = ""
            for (index, char) in raw.enumerated() {
                if index > 0, index % 4 == 0 {
                    formatted.append(" ")
                }
                formatted.append(char)
            }
            return formatted
        }
    }

    /// 插入卡片的 snapshot —— `cardStatus()` 返回值。GUI 用来告诉用户「这张卡绑了哪把公钥」。
    struct GPGCardStatus: Equatable {
        let serial: String?
        let vendor: String?
        let holderName: String?
        /// 卡上记录的三个 subkey fingerprint（签 / 加密 / 认证）—— gpg `fpr:` 行原文，可能含空值。
        let subkeyFingerprints: [String]
        /// 反查 keyring 后命中的主密钥 fingerprint —— nil 表示卡上 subkey 在本机 keyring 里找不到对应主密钥
        /// （需要先 `--card-edit fetch` 拉公钥，或者把对方公钥导进来）。
        let linkedPrimaryFingerprint: String?
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

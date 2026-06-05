//
//  GPGBackend+KeyCreation.swift
//  SimpleZip
//
//  0.3.0 架构拆分：从 GPGBackend.swift 按职责切出，纯移动、零行为变更。
//

import Foundation

extension GPGBackend {
    // MARK: - 新建密钥

    /// 新建密钥支持的算法。`Ed25519` 是当前推荐（小 + 快 + 强）；RSA 系列给老兼容。
    enum GPGKeyAlgorithm: String, CaseIterable, Hashable, Identifiable {
        case ed25519 = "ed25519"
        case rsa4096 = "rsa4096"
        case rsa3072 = "rsa3072"
        case rsa2048 = "rsa2048"

        var id: String { rawValue }

        /// 某个用途的子密钥该用什么 gpg 算法字符串。
        /// **EdDSA(ed25519) 只能签 / 认证**,加密子密钥必须用 Curve25519 的 `cv25519`;
        /// 签名 / 认证子密钥用 `ed25519`。RSA 主密钥的子密钥都用同位数 RSA。
        func subkeyAlgorithm(for capability: GPGSubkeyCapability) -> String {
            switch self {
            case .ed25519:
                return capability == .encrypt ? "cv25519" : "ed25519"
            case .rsa4096, .rsa3072, .rsa2048:
                return rawValue
            }
        }

        /// 加密子密钥算法。`--quick-generate-key <uid> ed25519 default` 不会自动建加密子密钥(实测 gpg 2.5),
        /// 所以 createKey 用这个显式 `--quick-add-key ... encrypt`。
        var encryptionSubkeyAlgorithm: String { subkeyAlgorithm(for: .encrypt) }
    }

    /// 子密钥用途 —— 新建密钥时(加密自动 + 认证可选)与给现有密钥「补票」加子密钥时共用。
    /// `gpgUsage` 是喂给 `--quick-add-key <fp> <algo> <usage>` 的用途字符串。
    /// certify(签证)只属于主密钥、不作为可加的子密钥用途,故不在此列。
    enum GPGSubkeyCapability: String, CaseIterable, Hashable, Identifiable {
        case sign
        case encrypt
        case authenticate

        var id: String { rawValue }

        var gpgUsage: String {
            switch self {
            case .sign: return "sign"
            case .encrypt: return "encrypt"
            case .authenticate: return "auth"
            }
        }
    }

    /// 新建密钥的过期时间选项。`never` 给 gpg 传字面 "never"。
    enum GPGKeyExpiration: String, CaseIterable, Hashable, Identifiable {
        case never = "never"
        case oneYear = "1y"
        case twoYears = "2y"
        case fiveYears = "5y"

        var id: String { rawValue }
    }

    /// 新建 GPG 密钥到指定 ring。私钥由 gpg-agent + pinentry-mac 弹原生密码框收 passphrase ——
    /// 本函数 / SimpleZip 不接触 passphrase。
    ///
    /// `into = .userKeyring`：标准 `gpg --quick-generate-key`，公钥进 `~/.gnupg/pubring.kbx`、私钥进 `~/.gnupg/private-keys-v1.d/`。CLI 共享。
    /// `into = .simpleZipKeyring`：加 `--no-default-keyring --keyring <SZ>/pubring.kbx`，公钥进 SimpleZip 私有 ring，
    ///   **但**私钥仍然进 `~/.gnupg/private-keys-v1.d/`（gpg 的 secring 是全局的，无法通过 `--keyring` 改变）—— 调用方应在 UI 上声明这一点。
    ///
    /// 返回新密钥的 40 字符 fingerprint（从 `--status-fd 1` 的 `KEY_CREATED` 行解析）。
    ///
    /// `passphrase` 处理：
    /// - 非空 → 走 `--pinentry-mode loopback --passphrase-fd 0`，passphrase 通过 stdin pipe 喂给 gpg
    ///   （不进 cmdline `ps` 输出，几秒后子进程退出释放）。SimpleZip 短暂持有，权衡可靠性。
    /// - 空字符串 `""` → 走 `--batch --passphrase ''` 创建**无 passphrase 密钥**（不安全，仅自动化 / 测试用）。
    /// - **不要**留 nil：之前那个走 pinentry-mac 的路径用户环境如果没配好 `gpg-agent.conf` pinentry-program
    ///   就死等 —— 改成强制必填后，本函数总是工作。
    ///
    /// `outputObserver` 实时回调每段 stdout（含 `[GNUPG:]` 状态行）——UI 可以解析 `PROGRESS` 等给用户进度反馈。
    /// `operationID` 用 `BackendProcessRunner.cancelRunningCommand(operationID:)` 取消挂死进程。
    @discardableResult
    static func createKey(
        name: String,
        email: String,
        algorithm: GPGKeyAlgorithm,
        expiration: GPGKeyExpiration,
        into ring: GPGKeyringSource = .userKeyring,
        addAuthenticationSubkey: Bool = false,
        passphrase: String,
        outputObserver: (@Sendable (String) -> Void)? = nil,
        operationID: UUID? = nil
    ) async throws -> String {
        let tool = try resolve()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedEmail.isEmpty else {
            throw ArchiveError.commandFailed("Name and email are required")
        }
        let userID = "\(trimmedName) <\(trimmedEmail)>"

        // 预拉 gpg-agent：loopback 模式下虽然不用 pinentry，但 gpg 仍可能拉 agent 跑 keygen，幂等 launch 一下没坏处。
        await ensureGPGAgentLaunched(near: tool)

        var args: [String] = ["--batch", "--pinentry-mode", "loopback", "--passphrase-fd", "0"]
        if ring == .simpleZipKeyring {
            // SimpleZip 私有走独立 GNUPGHOME（`--homedir <SZ>`）—— 公钥 + 私钥 + trustdb 全部进 SZ 私有目录。
            // 之前 `--no-default-keyring --keyring <SZ> --primary-keyring <SZ>` 在某些 gpg 版本下 `--quick-generate-key`
            // 仍写到 `~/.gnupg/`，搞不定 → 直接换 homedir，gpg 无歧义。
            args.insert(contentsOf: simpleZipKeyringArguments(), at: 0)
        }
        args.append(contentsOf: [
            "--status-fd", "1",
            "--quick-generate-key",
            userID,
            algorithm.rawValue,
            "default",                // 用途：默认（主密钥 sign+certify，自动生成 encrypt subkey）
            expiration.rawValue
        ])

        // passphrase 通过 stdin 喂 gpg（`--passphrase-fd 0`）—— 不出现在 cmdline 里，`ps` / Activity Monitor 看不到。
        // 空字符串依旧加换行让 gpg 读到 EOF；gpg 把空 passphrase 当作「不加密私钥」处理。
        let stdinInput = passphrase + "\n"
        var output = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: args,
            inputStrategy: .staticInput(stdinInput),
            outputObserver: outputObserver,
            operationID: operationID
        )

        // 解析主密钥 fingerprint（`[GNUPG:] KEY_CREATED B <fp>`），之后用 `--quick-add-key` 加 auth subkey。
        var primaryFingerprint = ""
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("[GNUPG:] KEY_CREATED") else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if parts.count >= 4, parts[3].count == 40, parts[3].allSatisfy({ $0.isHexDigit }) {
                primaryFingerprint = parts[3]
                break
            }
        }

        if !primaryFingerprint.isEmpty {
            // **加密子密钥必须显式追加**：`--quick-generate-key <uid> ed25519 default` 造出的主密钥只有
            // sign+certify(caps `scSC`)、没有加密子密钥(实测 gpg 2.5：ed25519/EdDSA 本身不能加密，
            // gpg 也不替你补一个 cv25519)。对话框承诺「加密 — encryption subkey(自动)」，这里把它真正建出来。
            // 跑一次 `--quick-add-key <fp> <algo> <usage> <expire>`，passphrase 走同款 loopback stdin。
            func addSubkeyDuringCreation(algorithm subkeyAlgorithm: String, usage: String) async throws {
                var subArgs: [String] = ["--batch", "--pinentry-mode", "loopback", "--passphrase-fd", "0"]
                if ring == .simpleZipKeyring {
                    subArgs.insert(contentsOf: simpleZipKeyringArguments(), at: 0)
                }
                subArgs.append(contentsOf: [
                    "--status-fd", "1",
                    "--quick-add-key",
                    primaryFingerprint,
                    subkeyAlgorithm,
                    usage,
                    expiration.rawValue
                ])
                let subOutput = try await BackendProcessRunner.runAndCapture(
                    tool,
                    arguments: subArgs,
                    inputStrategy: .staticInput(stdinInput),
                    outputObserver: outputObserver,
                    operationID: operationID
                )
                output += "\n[SimpleZip] add \(usage) subkey\n" + subOutput
            }

            // **加密子密钥是硬需求 → 失败必须抛错**（否则会返回一把「假装成功」的 sign-only key，
            // UI / CHANGELOG 都显示创建成功，实际不能加密）。失败时把已建出来的残缺主密钥删掉，
            // 保持「要么完整要么没有」，再抛错让 UI 显示失败。
            do {
                try await addSubkeyDuringCreation(algorithm: algorithm.encryptionSubkeyAlgorithm, usage: "encrypt")
            } catch {
                _ = try? await deleteKey(fingerprint: primaryFingerprint, deleteSecret: true, source: ring)
                throw ArchiveError.commandFailed(
                    "Key created but the required encryption subkey could not be added: \(error.localizedDescription)"
                )
            }

            // auth 子密钥**可选** → 软失败：主密钥 + 加密子密钥已 OK，auth 失败不该毁掉整把可用密钥。
            if addAuthenticationSubkey {
                do {
                    try await addSubkeyDuringCreation(algorithm: algorithm.rawValue, usage: "auth")
                } catch {
                    output += "\n[SimpleZip] auth subkey add failed (non-fatal): \(error.localizedDescription)\n"
                }
            }
        }

        // `[GNUPG:] KEY_CREATED B <fingerprint>` —— B 表示 both（主 + 子）。
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("[GNUPG:] KEY_CREATED") else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // parts: ["[GNUPG:]", "KEY_CREATED", "B", "<fingerprint>"]
            if parts.count >= 4, parts[3].count == 40, parts[3].allSatisfy({ $0.isHexDigit }) {
                return parts[3]
            }
        }
        // 兜底：从整段输出里捞第一段 40 字符 hex。
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            for word in rawLine.split(separator: " ", omittingEmptySubsequences: true) {
                let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
                if w.count == 40, w.allSatisfy({ $0.isHexDigit }) {
                    return w
                }
            }
        }
        // 创建确实成功了（gpg 退出码 0）但 fingerprint 没解析出来 —— 返回空串让 UI 提示「成功但未拿到指纹」，
        // 调用方 refresh keyring 还能看到新密钥。
        return ""
    }

    /// 给**现有密钥**追加一个子密钥（「补票」）—— 例如给只有签名能力的旧密钥补一个加密子密钥。
    ///
    /// 走 `gpg --quick-add-key <fp> <algo> <usage> <expire>`，passphrase 通过 stdin loopback 喂 gpg 解锁主密钥
    /// （新子密钥要用主密钥签名绑定）。算法按 `algorithm.subkeyAlgorithm(for:)` 映射
    /// （ed25519 的加密子密钥 → cv25519，签名 / 认证 → ed25519；RSA → 同位数）。
    ///
    /// **不支持卡上 / stripped 主密钥**：卡上私钥不出卡，`--quick-add-key` 没有可用主私钥签新子密钥 → 调用方
    /// （UI）必须在入口处用 `isSecretKeyStub` 把这条路对智能卡密钥隐藏，本函数不为卡场景做特殊处理。
    static func addSubkey(
        fingerprint: String,
        capability: GPGSubkeyCapability,
        algorithm: GPGKeyAlgorithm,
        expiration: GPGKeyExpiration,
        passphrase: String,
        source: GPGKeyringSource = .userKeyring
    ) async throws {
        let tool = try resolve()
        await ensureGPGAgentLaunched(near: tool)
        var args: [String] = ["--batch", "--pinentry-mode", "loopback", "--passphrase-fd", "0"]
        if source == .simpleZipKeyring {
            args.insert(contentsOf: simpleZipKeyringArguments(), at: 0)
        }
        args.append(contentsOf: [
            "--status-fd", "1",
            "--quick-add-key",
            fingerprint,
            algorithm.subkeyAlgorithm(for: capability),
            capability.gpgUsage,
            expiration.rawValue
        ])
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: args,
            inputStrategy: .staticInput(passphrase + "\n")
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
            // SimpleZip 私有走独立 GNUPGHOME（`--homedir <SZ>`）—— 公钥 + 私钥 + trustdb 全部隔离。
            args.insert(contentsOf: simpleZipKeyringArguments(), at: 0)
        }
        args.append(fileURL.path)
        return try await BackendProcessRunner.runAndCapture(tool, arguments: args)
    }
}

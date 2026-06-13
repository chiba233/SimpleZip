//
//  GPGBackend+KeyManagement.swift
//  SimpleZip
//
//  0.3.0 架构拆分：从 GPGBackend.swift 按职责切出，纯移动、零行为变更。
//

import Foundation

extension GPGBackend {
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
            // SimpleZip 私有走独立 GNUPGHOME；不需要 `--no-default-keyring`（homedir 已经把 ring 切到 SZ 私有目录）。
            let szArgs = simpleZipKeyringArguments()
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

        // 读**用户设置的 ownertrust**（跟 colons 里的 validity 不同）。`--export-ownertrust` 输出
        // `<fingerprint>:<value>:` 行（# 开头是注释）；信任 dropdown 的「当前值」要用这个,否则设
        // never/marginal/full 后 validity 不变会显示「未设置」。失败（首次无 trustdb 等）→ 空 map。
        var ownertrustArguments = ["--export-ownertrust"]
        if source == .simpleZipKeyring {
            ownertrustArguments = simpleZipKeyringArguments() + ownertrustArguments
        }
        let ownertrustOutput = (try? await BackendProcessRunner.runAndCapture(tool, arguments: ownertrustArguments)) ?? ""
        let ownertrustByFingerprint = parseOwnertrust(ownertrustOutput)

        var keys = parseColonsList(
            publicOutput,
            secretFingerprints: fullSecret,
            smartcardFingerprints: smartcardPrimary,
            strippedFingerprints: strippedPrimary,
            smartcardSubkeyFingerprints: smartcardSubkey,
            strippedSubkeyFingerprints: strippedSubkey,
            source: source
        )
        for i in keys.indices {
            if let owner = ownertrustByFingerprint[keys[i].fingerprint] {
                keys[i].ownerTrust = owner
            }
        }
        return keys
    }

    /// 解析 `gpg --export-ownertrust` 输出 → `[fingerprint: ownertrust]`。
    /// 每行 `<40hex fingerprint>:<value>:`；`#` 注释跳过。
    /// `nonisolated`：纯字符串解析、不碰任何 actor 状态,需从 `ownertrustLevel` 的 `@Sendable` 并发闭包里调用。
    nonisolated static func parseOwnertrust(_ output: String) -> [String: GPGTrustLevel] {
        var map: [String: GPGTrustLevel] = [:]
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, !fields[0].isEmpty else { continue }
            map[fields[0]] = GPGTrustLevel.parseOwnertrust(fields[1])
        }
        return map
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
            // SimpleZip 私有走独立 GNUPGHOME（`--homedir <SZ>`）—— 公钥 + 私钥 + trustdb 全部隔离。
            args.insert(contentsOf: simpleZipKeyringArguments(), at: 0)
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
            args.append(contentsOf: simpleZipKeyringArguments())
        }
        args.append(contentsOf: ["--armor", "--export", fingerprint])
        return try await BackendProcessRunner.runAndCapture(tool, arguments: args)
    }

    /// 修改密钥的 passphrase（私钥加密口令）。
    ///
    /// `gpg --batch --pinentry-mode loopback --command-fd 0 --passwd <fp>`：loopback 下 `--passwd`
    /// 依次索要 **当前口令 / 新口令 / 新口令确认**，全部从 command-fd 0（stdin）读。
    /// **新旧口令都走 stdin、都不进 argv** —— `ps` / 活动监视器看不到任何口令，修掉了「旧口令曾走
    /// `--passphrase` arg、被 `ps` 看见」的纰漏，与全 app「密钥只走 stdin」惯例一致。
    /// 已对 GnuPG 2.5.x 实测 loopback `--passwd`：旧口令失效、新口令生效、exit 0。
    static func changePassphrase(
        fingerprint: String,
        oldPassphrase: String,
        newPassphrase: String,
        source: GPGKeyringSource = .userKeyring
    ) async throws {
        let tool = try resolve()
        var args: [String] = ["--batch", "--pinentry-mode", "loopback"]
        if source == .simpleZipKeyring {
            args.insert(contentsOf: simpleZipKeyringArguments(), at: 0)
        }
        args.append(contentsOf: ["--command-fd", "0", "--passwd", fingerprint])
        // loopback `--passwd` 的三段输入：当前口令 → 新口令 → 新口令确认。
        let responses = "\(oldPassphrase)\n\(newPassphrase)\n\(newPassphrase)\n"
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: args,
            inputStrategy: .staticInput(responses)
        )
    }

    /// 添加 User ID 到现有密钥（一把 GPG 密钥可以挂多个 UID，比如多个邮箱 / 别名）。
    ///
    /// 走 `gpg --quick-add-uid <fp> "Name [(comment)] <email>"` —— gpg 自动用主密钥签名新 UID。
    /// 需要私钥 passphrase 解锁主密钥来做签名。
    /// `comment` 可选；非空时拼成 `Name (comment) <email>` 格式。
    static func addUserID(
        fingerprint: String,
        name: String,
        email: String,
        comment: String,
        passphrase: String,
        source: GPGKeyringSource = .userKeyring
    ) async throws {
        let tool = try resolve()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedEmail.isEmpty else {
            throw ArchiveError.commandFailed("Name and email are required")
        }
        let userIDString: String
        if trimmedComment.isEmpty {
            userIDString = "\(trimmedName) <\(trimmedEmail)>"
        } else {
            userIDString = "\(trimmedName) (\(trimmedComment)) <\(trimmedEmail)>"
        }

        var args: [String] = ["--batch", "--pinentry-mode", "loopback", "--passphrase-fd", "0"]
        if source == .simpleZipKeyring {
            args.insert(contentsOf: simpleZipKeyringArguments(), at: 0)
        }
        args.append(contentsOf: ["--quick-add-uid", fingerprint, userIDString])
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: args,
            inputStrategy: .staticInput(passphrase + "\n")
        )
    }

    /// 导出**私钥**为 ASCII armor (`.asc`) 文本 —— 备份 / 迁移到其它机器用。
    ///
    /// 导出的私钥仍保留**原 passphrase 加密**（gpg 不会解密 secring 里的私钥才能导出）—— 文件里是已加密 blob。
    /// 但导入到另一台机器时仍需要原 passphrase 才能用。
    /// **不要把这份 .asc 跟 passphrase 一起放**——分两个地方存（如：私钥放 U 盘、passphrase 放密码管理器）。
    ///
    /// gpg 的 secring 是全局的 —— 即使密钥的公钥在 SimpleZip ring 里，私钥仍存 `~/.gnupg/private-keys-v1.d/`。
    /// 所以 `--export-secret-keys` 在两个 source 下都能从 ~/.gnupg/ 拿到私钥；source 参数主要影响公钥部分查找。
    static func exportSecretKey(fingerprint: String, source: GPGKeyringSource = .userKeyring) async throws -> String {
        let tool = try resolve()
        var args: [String] = ["--batch", "--pinentry-mode", "loopback", "--passphrase", ""]
        if source == .simpleZipKeyring {
            // SimpleZip 私有走独立 GNUPGHOME（`--homedir <SZ>`）—— 公钥 + 私钥 + trustdb 全部隔离。
            args.insert(contentsOf: simpleZipKeyringArguments(), at: 0)
        }
        args.append(contentsOf: ["--armor", "--export-secret-keys", fingerprint])
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
}

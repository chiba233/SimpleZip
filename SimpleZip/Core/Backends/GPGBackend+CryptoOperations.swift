//
//  GPGBackend+CryptoOperations.swift
//  SimpleZip
//
//  0.3.0 架构拆分：从 GPGBackend.swift 按职责切出，纯移动、零行为变更。
//

import Foundation

extension GPGBackend {
    /// 嗅探一个 `.gpg`/`.pgp`/`.asc` 文件的 OpenPGP 内容类别 —— 决定双击是「解密打开」还是「导入钥匙串」。
    ///
    /// **纯本地、瞬时、绝不起 gpg、绝不解密、绝不弹 passphrase**：
    /// - 装甲（ASCII-armored）→ 读首行 `-----BEGIN PGP …-----`（`GPGFileKind.fromArmorHeader`）。
    /// - 二进制 → 读首个 OpenPGP 包头字节，按 RFC 4880 packet tag 定性（`GPGFileKind.fromBinaryPacketTag`）。
    ///
    /// 之所以**不**用 `gpg --list-packets`：它对加密文件会尝试解密内层会话密钥、触发 pinentry；用户取消
    /// 就让它非零退出，把加密文件误判成「不可识别」。读包头则完全规避——只看结构、不碰内容。
    static func classifyFile(at fileURL: URL) -> GPGFileKind {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return .unknown }
        defer { try? handle.close() }
        // 读前 4KB 足以覆盖装甲头 + 注释行；二进制只需首字节，多读无妨。
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        if let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .ascii),
           let armorKind = GPGFileKind.fromArmorHeader(text) {
            return armorKind
        }
        return GPGFileKind.fromBinaryPacketTag(head)
    }

    /// 加密任意文件 —— `.siz` v3 内层 archive 加密的后端入口。
    ///
    /// **三种组合**：
    /// - 仅收件人公钥（`recipients` 非空 + `symmetricPassphrase` 为 nil）→ 持有任一收件人对应私钥的人能解；
    /// - 仅对称密码（`recipients` 为空 + `symmetricPassphrase` 非 nil）→ 知道密码的人能解；
    /// - 二者都给 → 「任一私钥**或**密码」都能解（`gpg --symmetric --encrypt --passphrase-fd 0 -r ...`）。
    ///
    /// passphrase 走 stdin（`--passphrase-fd 0`），**不进 ps 输出**；recipients 是 fingerprint 直接放命令行（fingerprint 本就不是机密）。
    /// 输出是二进制（不带 `--armor`）—— `.siz` 内层 archive 已经是压缩态，再 ASCII armor 一次只让体积变大。
    static func encrypt(
        fileURL: URL,
        recipients: [String],
        symmetricPassphrase: String? = nil,
        outputURL: URL,
        useSimpleZipKeyring: Bool = false,
        operationID: UUID? = nil
    ) async throws {
        let normalizedPassphrase = symmetricPassphrase?.isEmpty == false ? symmetricPassphrase : nil
        guard !recipients.isEmpty || normalizedPassphrase != nil else {
            // 收件人列表空 + 没密码 → 没人能解。调用方 UI 应该在前面拦住，到这里属编程错。
            throw ArchiveError.commandFailed("encrypt called with no recipients and no passphrase")
        }
        let tool = try resolve()
        try? FileManager.default.removeItem(at: outputURL)
        var arguments: [String] = ["--batch", "--yes"]
        if useSimpleZipKeyring {
            arguments.insert(contentsOf: simpleZipKeyringArguments(), at: 0)
        }
        if normalizedPassphrase != nil {
            // `--symmetric` 加 `--passphrase-fd 0` —— 让 gpg 从 stdin 读密码；进程命令行里看不到 passphrase。
            // 和 `--encrypt` 并列时 gpg 同时塞 ESK（对称会话密钥）和 PK-ESK（公钥包裹的会话密钥）到包头，
            // 解密方任一方式命中即可。
            arguments.append(contentsOf: ["--symmetric", "--pinentry-mode", "loopback", "--passphrase-fd", "0"])
        }
        if !recipients.isEmpty {
            arguments.append("--encrypt")
            for fingerprint in recipients {
                arguments.append(contentsOf: ["--recipient", fingerprint])
            }
            // `--trust-model always`：对收件人公钥的 ownertrust 不做强检查（用户已通过 UI picker 主动选了）。
            arguments.append(contentsOf: ["--trust-model", "always"])
        }
        arguments.append(contentsOf: ["--output", outputURL.path, fileURL.path])
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: arguments,
            inputStrategy: normalizedPassphrase.map { .staticInput($0) } ?? .none,
            operationID: operationID
        )
    }

    /// 解密 GPG 加密的文件 —— `.siz` v3 解密入口。
    ///
    /// 跑 `gpg --batch --yes --decrypt [--passphrase-fd 0] [--local-user <fp>] --output <out> <in>`。
    /// - `decryptionKeyFingerprint`：「优先尝试用哪把私钥」hint，多密钥用户在 UI 选过的密钥；nil = gpg 自挑。
    /// - `passphrase`：对称密码模式 / 私钥 passphrase（如果 gpg-agent 没缓存且文件是对称加密）。**走 stdin**，不进 ps。
    /// - 不给 passphrase 时由 gpg-agent + pinentry-mac 弹原生密码框（公钥模式 + agent 没缓存私钥 passphrase 的常规路径）。
    ///
    /// **两环都试**：公钥加密的文件，其私钥可能在 `~/.gnupg`、**也可能在 SimpleZip 私有环**（独立 GNUPGHOME，
    /// 私钥存私有 `private-keys-v1.d/`）。一次 gpg 解密只能用一个 homedir，而文件本身不带「该用哪个 homedir」信息——
    /// 所以 `useSimpleZipKeyring == false`(默认/自动)时**先试 `~/.gnupg`，失败再试私有环**，任一成功即返回。
    /// （对称密码文件不需要私钥，第一次就成；之前只试 `~/.gnupg` → 加密给私有环收件人的文件「能加密却解不开」。）
    /// `useSimpleZipKeyring == true` 时只用私有环（调用方已确定 ring，不浪费一次尝试）。
    static func decrypt(
        fileURL: URL,
        outputURL: URL,
        decryptionKeyFingerprint: String? = nil,
        passphrase: String? = nil,
        useSimpleZipKeyring: Bool = false,
        operationID: UUID? = nil
    ) async throws {
        let normalizedPassphrase = passphrase?.isEmpty == false ? passphrase : nil
        let tool = try resolve()

        // 单次解密尝试（指定用哪个 ring）。成功返回、失败抛错。
        func attempt(useSZRing: Bool) async throws {
            try? FileManager.default.removeItem(at: outputURL)
            var arguments: [String] = ["--batch", "--yes"]
            if useSZRing {
                arguments.insert(contentsOf: simpleZipKeyringArguments(), at: 0)
            }
            if normalizedPassphrase != nil {
                arguments.append(contentsOf: ["--pinentry-mode", "loopback", "--passphrase-fd", "0"])
            }
            arguments.append("--decrypt")
            if let key = decryptionKeyFingerprint, !key.isEmpty {
                arguments.append(contentsOf: ["--local-user", key])
            }
            arguments.append(contentsOf: ["--output", outputURL.path, fileURL.path])
            _ = try await BackendProcessRunner.runAndCapture(
                tool,
                arguments: arguments,
                inputStrategy: normalizedPassphrase.map { .staticInput($0) } ?? .none,
                operationID: operationID
            )
        }

        // 调用方明确要私有环 → 只试私有环。
        if useSimpleZipKeyring {
            try await attempt(useSZRing: true)
            return
        }
        // 自动：先 ~/.gnupg，失败再私有环。两次都失败 → 抛**第一次**(用户主环)的错误，信息更贴近常规场景。
        do {
            try await attempt(useSZRing: false)
        } catch let userKeyringError {
            do {
                try await attempt(useSZRing: true)
            } catch {
                throw userKeyringError
            }
        }
    }

    /// **Clearsign** —— 把整个文本文件签名后输出为「clearsigned message」格式（`-----BEGIN PGP SIGNED MESSAGE-----` … 包住原文，
    /// 末尾跟一段 `-----BEGIN PGP SIGNATURE-----`）。是 `.szs` 签名清单的核心格式：
    /// 一个 clearsigned `.szs` 文件就是「JSON 清单 + 内联签名」，单文件即可用 `gpg --verify` 校验。
    ///
    /// 跑 `gpg --batch --yes --clearsign [--local-user <fp>] --output <out> <in>`。
    /// signingKeyFingerprint 为 nil → gpg 用 default-key。
    static func clearsign(
        plaintextURL: URL,
        signingKeyFingerprint: String?,
        useSimpleZipKeyring: Bool = false,
        outputURL: URL,
        operationID: UUID? = nil
    ) async throws {
        let tool = try resolve()
        try? FileManager.default.removeItem(at: outputURL)
        var arguments: [String] = ["--batch", "--yes", "--clearsign"]
        // 签名密钥在 SimpleZip 私有环时,必须用它的独立 `--homedir`,否则 `--local-user <fp>` 在 ~/.gnupg
        // 里找不到这把私钥而签名失败。私有环是独立 GNUPGHOME(非 --keyring),一次调用只能用一个 homedir。
        if useSimpleZipKeyring {
            arguments.insert(contentsOf: simpleZipKeyringArguments(), at: 0)
        }
        if let key = signingKeyFingerprint {
            arguments.append(contentsOf: ["--local-user", key])
        }
        arguments.append(contentsOf: ["--output", outputURL.path, plaintextURL.path])
        _ = try await BackendProcessRunner.runAndCapture(tool, arguments: arguments, operationID: operationID)
    }

    /// **校验 clearsigned 文件**并返回签名状态 + 内联明文 body。
    ///
    /// 跑 `gpg --status-fd 1 --decrypt <file>`（clearsign 文件用 `--decrypt` 提取明文 + 校验，
    /// `--verify` 不输出明文）。返回值同时包含验签结果（重用 `.siz` 的 `GPGVerifyResult` 类型）和明文 body（Data）。
    /// SHA / 格式化等下游逻辑由 caller 处理。
    static func verifyClearsign(
        signedURL: URL,
        operationID: UUID? = nil
    ) async throws -> (verify: GPGVerifyResult, plaintext: Data) {
        let tool = try resolve()
        // 两 pass 兼容 .siz：默认 homedir + SimpleZip 私有 homedir。校验状态合并；明文从赢家 pass 拿。
        let baseArgs = ["--status-fd", "1", "--decrypt", signedURL.path]
        async let r1 = clearsignSingleRing(tool: tool, args: baseArgs, operationID: operationID)
        async let r2 = clearsignSingleRing(tool: tool, args: simpleZipKeyringArguments() + baseArgs, operationID: operationID)
        let user = await r1
        let sz = await r2
        // 优先选「拿到明文 + 验签更佳」的那 pass —— 跟 .siz 的 mergeVerifyResults 风格一致。
        let merged = await applyOwnertrust(to: mergeVerifyResults(user.verify, sz.verify))
        // plaintext 选「拿到明文且 not empty」的；如果都空就给空 Data（让 caller 报「解析失败」）。
        let plaintext: Data = {
            if !user.plaintext.isEmpty { return user.plaintext }
            if !sz.plaintext.isEmpty { return sz.plaintext }
            return Data()
        }()
        return (merged, plaintext)
    }

    /// 单 ring clearsign 校验：跑 `gpg --decrypt` 拿到 stdout 明文 + stderr / status fd 状态。
    /// 明文比验签状态难拿 —— stdout 跟 status fd 都从 fd 1 出（`--status-fd 1`），需要拆 `[GNUPG:]` 前缀那几行才能得到纯明文。
    ///
    /// **catch 分支也提取明文**：gpg 在 BADSIG / NO_PUBKEY 等情况下仍会把 clearsigned body 输出到 stdout（只是 exit code ≠ 0），
    /// 旧版本直接返回 `Data()` 丢掉明文，导致「未知签名者 / 坏签名的 `.szs` 用户看不到 manifest 内容」—— 应该把签名问题展示给用户但
    /// **同时允许用户阅读清单**（manifest 内容本身不是机密，是签名背书出问题）。
    private static func clearsignSingleRing(
        tool: String,
        args: [String],
        operationID: UUID?
    ) async -> (verify: GPGVerifyResult, plaintext: Data) {
        do {
            let output = try await BackendProcessRunner.runAndCapture(tool, arguments: args, operationID: operationID)
            let plaintext = extractClearsignPlaintext(from: output)
            return (parseStatusOutput(output, exitOk: true), plaintext)
        } catch {
            let errorOutput = (error as? ArchiveError).flatMap { archiveError in
                if case .commandFailed(let text) = archiveError { return text }
                return nil
            } ?? error.localizedDescription
            // 关键：errorOutput 里也可能有 clearsigned body —— 用同样的 prefix 过滤抽出来。
            let plaintext = extractClearsignPlaintext(from: errorOutput)
            return (parseStatusOutput(errorOutput, exitOk: false), plaintext)
        }
    }

    /// 0.4.4 #11:用**临时隔离 GNUPGHOME** 验签 —— 只导入给定的公钥文件,完全不读不写用户钥匙环。
    /// 用途:发布目录检查站在「收件人」视角验证「随包公钥能否独立验证 .szs」。
    /// 临时目录 0700 权限、用后即删;信任状态在隔离环里必然是 unknown —— 调用方只关心
    /// 密码学有效性(GOODSIG),不评估 trust。
    static func verifyClearsignWithIsolatedKey(
        publicKeyURL: URL,
        signedURL: URL,
        operationID: UUID? = nil
    ) async throws -> GPGVerifyResult {
        let tool = try resolve()
        let homedir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleZip-IsolatedVerify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: homedir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: homedir) }
        let base = ["--homedir", homedir.path, "--batch", "--no-tty"]
        // 导入失败(损坏的 .asc)直接抛 —— 「公钥文件坏了」本身就是检查结论。
        _ = try await BackendProcessRunner.runAndCapture(
            tool, arguments: base + ["--import", publicKeyURL.path], operationID: operationID
        )
        do {
            let output = try await BackendProcessRunner.runAndCapture(
                tool, arguments: base + ["--status-fd", "1", "--verify", signedURL.path], operationID: operationID
            )
            return parseStatusOutput(output, exitOk: true)
        } catch {
            let errorOutput = (error as? ArchiveError).flatMap { archiveError in
                if case .commandFailed(let text) = archiveError { return text }
                return nil
            } ?? error.localizedDescription
            return parseStatusOutput(errorOutput, exitOk: false)
        }
    }

    /// 从合并的 stdout/stderr 里抽明文：所有不以 `[GNUPG:] ` 开头的行就是明文。Caveat：人类可读 stderr 也会混进来，
    /// 但 stderr 的字符串都是 `gpg: …` 前缀（gpg 标准 stderr 输出格式），用 `gpg: ` 前缀也能滤掉。
    private static func extractClearsignPlaintext(from output: String) -> Data {
        var lines: [String] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("[GNUPG:] ") { continue }
            if line.hasPrefix("gpg: ") { continue }
            lines.append(line)
        }
        // 去掉末尾可能多余的换行行；前后保留 newline 让 caller 看到原始 body。
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// 用指定私钥给压缩包做 detached signature，产物 `<archive>.asc`（ASCII armor 格式）。
    /// 密码框由 gpg-agent + pinentry-mac 自己弹，本函数完全不接触 passphrase。
    /// signingKeyFingerprint 为 nil → 让 gpg 用 default-key（用户没配 default 时用第一把可用私钥）。
    static func sign(
        archiveURL: URL,
        signingKeyFingerprint: String?,
        useSimpleZipKeyring: Bool = false,
        operationID: UUID? = nil
    ) async throws -> URL {
        let tool = try resolve()
        let signatureURL = archiveURL.appendingPathExtension("asc")
        // 已存在 → 先删，否则 gpg 会拒绝覆盖。
        try? FileManager.default.removeItem(at: signatureURL)
        var arguments: [String] = ["--batch", "--yes", "--armor", "--detach-sign"]
        // 见 clearsign 注释:私有环签名密钥要用其独立 `--homedir`,否则在 ~/.gnupg 找不到私钥。
        if useSimpleZipKeyring {
            arguments.insert(contentsOf: simpleZipKeyringArguments(), at: 0)
        }
        if let key = signingKeyFingerprint {
            arguments.append(contentsOf: ["--local-user", key])
        }
        arguments.append(contentsOf: ["--output", signatureURL.path, archiveURL.path])
        _ = try await BackendProcessRunner.runAndCapture(tool, arguments: arguments, operationID: operationID)
        return signatureURL
    }

    /// 验签 —— `gpg --status-fd 1 --verify <archive>.asc <archive>`。
    ///
    /// `--status-fd 1` 让 gpg 把机器可读的状态行（`[GNUPG:] GOODSIG ...` / `VALIDSIG ...` / `BADSIG ...` /
    /// `TRUST_ULTIMATE` / `NO_PUBKEY` / `ERRSIG` / 等）输出到 stdout，跟原先的 stderr 人类可读输出共存。
    /// 解析器只认状态行，stderr 文本只当回退。
    ///
    /// 收益：
    /// - **不依赖 locale**：状态码永远英文，原 stderr 的「Good signature」/「BAD signature」可能因 locale 变化。
    /// - **fingerprint 强校验**：`VALIDSIG` 字段 1 是签名者 fingerprint（40 hex），字段 10 是主密钥 fingerprint
    ///   （如果签名子密钥不同于主密钥）。SIZ 验签时把 metadata 声明的 signerFingerprint 跟这个比对，
    ///   不等 = metadata 被重签 = impersonation → 判 bad。
    /// - **状态精确**：可区分「key 已过期 / 已撤销 / 签名本身过期」等之前文本里靠 WARNING 行模糊判别的情况。
    static func verify(
        archiveURL: URL,
        signatureURL: URL,
        operationID: UUID? = nil
    ) async throws -> GPGVerifyResult {
        let tool = try resolve()

        // SimpleZip 私有改用独立 `--homedir` 后，gpg 默认 ring 已经互相不可见。验签必须分两 pass：
        // 1) 默认 homedir（用户 ~/.gnupg/）—— 用户系统已有的公钥参与匹配；
        // 2) SimpleZip 私有 homedir —— 用户「导入到 SimpleZip 私有钥匙串」的他人公钥参与匹配。
        // 两 pass 结果合并：badSignature 永远优先（最严重）；两个都 validSignature 时按 trusted=true → 有 fingerprint → a 的顺序挑。
        let baseArgs = ["--status-fd", "1", "--verify", signatureURL.path, archiveURL.path]

        async let userResult = verifySingleRing(tool: tool, args: baseArgs, operationID: operationID)
        async let szResult = verifySingleRing(tool: tool, args: simpleZipKeyringArguments() + baseArgs, operationID: operationID)
        let r1 = await userResult
        let r2 = await szResult
        return await applyOwnertrust(to: mergeVerifyResults(r1, r2))
    }

    /// 单次验签调用 —— wrap 现有的「跑命令 + 解析输出」逻辑。
    private static func verifySingleRing(
        tool: String,
        args: [String],
        operationID: UUID?
    ) async -> GPGVerifyResult {
        do {
            let output = try await BackendProcessRunner.runAndCapture(
                tool,
                arguments: args,
                operationID: operationID
            )
            return parseStatusOutput(output, exitOk: true)
        } catch {
            let errorOutput = (error as? ArchiveError).flatMap { archiveError in
                if case .commandFailed(let text) = archiveError { return text }
                return nil
            } ?? error.localizedDescription
            return parseStatusOutput(errorOutput, exitOk: false)
        }
    }

    /// 两 pass 验签结果合并：
    /// 1) badSignature 永远优先 —— 「文件被改」最严重，必须被看见，即便另一 pass 说 valid（不应该发生但保守判定）。
    /// 2) 两个都 validSignature 时按 trusted=true > 有 fingerprint > a 的顺序挑 —— **修复历史 bug**：
    ///    用户自己签的文件如果在 `~/.gnupg` 和 SimpleZip 私有两个 homedir 都有公钥，但只有一头有 ownertrust ultimate
    ///    （比如 SimpleZip 私有里 `--quick-generate-key` 自动标了，但用户 export 到 `~/.gnupg` 时没设 ownertrust），
    ///    之前「first validSignature wins」会吃掉 untrusted 那个，覆盖掉 trusted 的；现在 trusted 永远胜。
    /// 3) 都没 validSignature 时按 unknownSigner > verificationError 信息丰富度选。
    private static func mergeVerifyResults(_ a: GPGVerifyResult, _ b: GPGVerifyResult) -> GPGVerifyResult {
        if case .badSignature = a { return a }
        if case .badSignature = b { return b }
        if let av = extractValidSignatureInfo(a), let bv = extractValidSignatureInfo(b) {
            if av.trusted && !bv.trusted { return a }
            if bv.trusted && !av.trusted { return b }
            if av.fingerprint == nil && bv.fingerprint != nil { return b }
            return a
        }
        if case .validSignature = a { return a }
        if case .validSignature = b { return b }
        if case .unknownSigner = a { return a }
        if case .unknownSigner = b { return b }
        return a // 两者都是 verificationError；返回第一份
    }

    /// validSignature 提取 trusted + fingerprint 给 merge 比较用 —— 拆出来避免 nested pattern matching 看不清。
    private static func extractValidSignatureInfo(_ result: GPGVerifyResult) -> (trusted: Bool, fingerprint: String?)? {
        if case .validSignature(_, let fp, let trusted, _) = result {
            return (trusted, fp)
        }
        return nil
    }

    /// 用**用户设置的 ownertrust** 重定 validSignature 的 `trusted`，而不是用 gpg `--verify` 报的 validity。
    ///
    /// 为什么必须这么做：gpg `--verify` 的 `TRUST_*` 是**计算出的 validity**（看签名网 + 别的 key 的 ownertrust 推），
    /// 对「用户给导入公钥设了完全/勉强信任、但没用自己的密钥签过它」的情形，validity 仍是 UNDEFINED →
    /// 之前会把**完全信任**的 key 误判成「公钥已导入但未信任」（用户报的 bug）。
    /// 信任徽章应当跟「信任」下拉一致 —— 都读 ownertrust：勉强/完全/终极 → 受信任；永不 / 未定义 → 不受信任。
    /// 读不到 ownertrust（无指纹 / gpg 出错）时保留原 validity-based 判定，不至于更糟。
    private static func applyOwnertrust(to result: GPGVerifyResult) async -> GPGVerifyResult {
        guard case .validSignature(let signer, let fingerprint, _, let concerns) = result,
              let fingerprint, !fingerprint.isEmpty,
              let level = await ownertrustLevel(forFingerprint: fingerprint) else {
            return result
        }
        let trusted: Bool
        switch level {
        case .marginal, .full, .ultimate:
            trusted = true
        case .never, .unknown, .expired, .revoked:
            trusted = false
        }
        return .validSignature(signer: signer, fingerprint: fingerprint, trusted: trusted, concerns: concerns)
    }

    /// 读某 fingerprint 的 ownertrust —— 跨默认 + SimpleZip 私有两个 homedir（优先默认环的设置）。
    /// `--export-ownertrust` 输出大写 40hex 指纹，跟验签 VALIDSIG 的 `.uppercased()` 指纹对齐。
    private static func ownertrustLevel(forFingerprint fingerprint: String) async -> GPGBackend.GPGTrustLevel? {
        guard let tool = try? resolve() else { return nil }
        let key = fingerprint.uppercased()
        // `async let` 并发执行 → 闭包必须 @Sendable（捕获的 tool / key 都是 String，Sendable）。
        let read: @Sendable ([String]) async -> GPGBackend.GPGTrustLevel? = { arguments in
            let output = (try? await BackendProcessRunner.runAndCapture(tool, arguments: arguments)) ?? ""
            return parseOwnertrust(output)[key]
        }
        async let user = read(["--export-ownertrust"])
        async let simpleZip = read(simpleZipKeyringArguments() + ["--export-ownertrust"])
        let userTrust = await user
        let simpleZipTrust = await simpleZip
        return userTrust ?? simpleZipTrust
    }
}

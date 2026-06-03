//
//  GPGBackend+Parsing.swift
//  SimpleZip
//
//  0.3.0 架构拆分：从 GPGBackend.swift 按职责切出，纯移动、零行为变更。
//

import Foundation

extension GPGBackend {
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
    static func parseColonsList(
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
    enum SecretKeyMode {
        case fullSecret
        case smartcard
        case stripped
    }

    static func parseFingerprints(
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

    /// 解析 `gpg --status-fd 1` 的机器可读状态行（`[GNUPG:] <CODE> <args>`）。
    ///
    /// 我们关心的关键 status：
    /// - `GOODSIG <long_keyid> <username>` —— 签名匹配，公钥找到。注意：「good」只说明密码学成立，不说信任。
    /// - `EXPKEYSIG` / `REVKEYSIG` —— 签名仍匹配，但签名密钥已过期 / 已撤销 → 收进 `concerns`，依然算 valid。
    /// - `EXPSIG` —— 签名本身过期（用户在生成签名时就限定了 sig 有效期）。
    /// - `BADSIG` —— 签名不匹配（最严重，文件被改 / 签名损坏）。
    /// - `NO_PUBKEY` / `ERRSIG <…> 9` —— 公钥不在 keyring，rc=9 是 NO_PUBKEY 的 ERRSIG 编码。
    /// - `VALIDSIG <fingerprint> ... [primary_key_fpr]` —— **fingerprint 强校验来源**：
    ///   字段 1 = 签名密钥 fingerprint（可能是 subkey）；
    ///   字段 10（VALIDSIG 后第 10 个 token）= 主密钥 fingerprint，子密钥签名时不同于字段 1。
    ///   SIZ metadata 存的 signerFingerprint 一般是主密钥，所以优先取字段 10。
    /// - `TRUST_ULTIMATE/FULLY/MARGINAL/UNDEFINED/NEVER` —— ownertrust 精确等级，不再靠 stderr 字符串猜。
    ///
    /// **历史 bug 在这里被修掉**：旧解析靠 `output.lowercased().contains("not certified with a trusted signature")`
    /// 判 trusted —— 这条 WARNING 受 locale、verbosity、trustdb 半同步状态影响极不稳定，导致 ultimate 密钥被误判为 untrusted。
    /// 现在直接读 `TRUST_ULTIMATE` 之类的明牌状态码，结果跟 gpg 的真值一致。
    static func parseStatusOutput(_ output: String, exitOk: Bool) -> GPGVerifyResult {
        var sawGoodSig = false
        var sawBadSig = false
        var sawNoPubkey = false
        var signerName: String?
        var longKeyID: String?
        var fingerprint: String?
        var concerns: Set<GPGVerifyResult.KeyConcern> = []
        var trustCode: String?
        var sawAnyStatus = false

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let payload = stripGNUPGStatusPrefix(String(rawLine)) else { continue }
            sawAnyStatus = true
            let tokens = payload.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let code = tokens.first else { continue }
            switch code {
            case "GOODSIG", "EXPKEYSIG", "REVKEYSIG":
                sawGoodSig = true
                if code == "EXPKEYSIG" { concerns.insert(.keyExpired) }
                if code == "REVKEYSIG" { concerns.insert(.keyRevoked) }
                if tokens.count > 1 { longKeyID = tokens[1] }
                if tokens.count > 2 {
                    signerName = tokens.dropFirst(2).joined(separator: " ")
                }
            case "EXPSIG":
                concerns.insert(.signatureExpired)
                if tokens.count > 1 { longKeyID = tokens[1] }
                if tokens.count > 2 {
                    signerName = tokens.dropFirst(2).joined(separator: " ")
                }
            case "BADSIG":
                sawBadSig = true
                if tokens.count > 1 { longKeyID = tokens[1] }
                if tokens.count > 2 {
                    signerName = tokens.dropFirst(2).joined(separator: " ")
                }
            case "VALIDSIG":
                // tokens: [VALIDSIG, sig_fp, sigdate, sigtimestamp, expiretimestamp, sigversion, reserved,
                //         pubkey_algo, hash_algo, sig_class, primary_key_fpr?]
                if tokens.count > 1, isFingerprint(tokens[1]) {
                    fingerprint = tokens[1].uppercased()
                }
                if tokens.count > 10, isFingerprint(tokens[10]) {
                    fingerprint = tokens[10].uppercased() // 主密钥 fp 覆盖签名子密钥 fp
                }
            case "NO_PUBKEY":
                sawNoPubkey = true
                if tokens.count > 1 { longKeyID = tokens[1] }
            case "ERRSIG":
                // ERRSIG <keyid> <pkalgo> <hashalgo> <sig_class> <time> <rc> [fpr]
                // rc=9 (NO_PUBKEY) 是「公钥不在 keyring」最常见情形。
                if tokens.count > 6, tokens[6] == "9" {
                    sawNoPubkey = true
                    if tokens.count > 1 { longKeyID = tokens[1] }
                }
            case "TRUST_UNDEFINED", "TRUST_NEVER", "TRUST_MARGINAL", "TRUST_FULLY", "TRUST_ULTIMATE":
                trustCode = code
            default:
                break
            }
        }

        if sawBadSig {
            return .badSignature(signer: signerName, fingerprint: fingerprint)
        }
        if sawNoPubkey && !sawGoodSig {
            return .unknownSigner(keyID: longKeyID)
        }
        if sawGoodSig {
            let trusted: Bool
            switch trustCode {
            case "TRUST_MARGINAL", "TRUST_FULLY", "TRUST_ULTIMATE":
                trusted = true
            default:
                trusted = false
            }
            return .validSignature(
                signer: signerName,
                fingerprint: fingerprint,
                trusted: trusted,
                concerns: concerns
            )
        }
        // 没有任何 status line —— 兜底走 legacy 文本解析（极端环境如非 GNU gpg 实现），
        // 仅作为后端 unknown 时的容错；新 gpg 都会输出状态行。
        if !sawAnyStatus {
            return parseLegacyVerifyOutput(output, exitOk: exitOk)
        }
        return .verificationError(message: output)
    }

    /// 剥 `[GNUPG:] ` 前缀。stdout 和 stderr 合并管道里有非状态行（人类可读文本），那些被忽略。
    private static func stripGNUPGStatusPrefix(_ line: String) -> String? {
        let prefix = "[GNUPG:] "
        guard let range = line.range(of: prefix) else { return nil }
        // gpg 的 status line 永远在行首；但合并管道里偶尔会被人类可读的 stderr 截断前缀拼到同一行。
        // 取 prefix 之后的内容即可。
        return String(line[range.upperBound...])
    }

    private static func isFingerprint(_ token: String) -> Bool {
        token.count == 40 && token.allSatisfy { $0.isHexDigit }
    }

    /// 旧文本解析，仅作为 `parseStatusOutput` 的 fallback（无任何 `[GNUPG:]` 状态行时）。
    /// 留着是为了非 GNU gpg 实现的极端兜底；正常 gpg 不会走这里。
    private static func parseLegacyVerifyOutput(_ output: String, exitOk: Bool) -> GPGVerifyResult {
        let lowered = output.lowercased()
        let signer = extractSignerName(from: output)
        if lowered.contains("bad signature") {
            return .badSignature(signer: signer, fingerprint: nil)
        }
        if lowered.contains("can't check signature") || lowered.contains("no public key") {
            return .unknownSigner(keyID: extractUnknownKeyID(from: output))
        }
        if lowered.contains("good signature") {
            // legacy 路径无法读 TRUST_*，trusted 字段保守置 false，让 UI 提示用户。
            return .validSignature(signer: signer, fingerprint: nil, trusted: false, concerns: [])
        }
        return exitOk
            ? .validSignature(signer: signer, fingerprint: nil, trusted: false, concerns: [])
            : .verificationError(message: output)
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
}

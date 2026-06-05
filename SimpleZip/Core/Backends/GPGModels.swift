//
//  GPGModels.swift
//  SimpleZip
//
//  0.3.0 架构拆分：从 GPGBackend.swift 切出的嵌套数据类型，纯移动、零行为变更。
//

import Foundation

extension GPGBackend {
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

        /// 从 gpg --with-colons 输出第 2 字段单字符解析 —— 这是**计算出的 validity**(有效性),不是用户设的 ownertrust。
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

        /// 从 `gpg --export-ownertrust` 的数字值解析**用户设置的 ownertrust**(跟 validity 不同 —— 这是你在 UI 里选的那个)。
        /// 值:2=undefined/未设置、3=never、4=marginal、5=full、6=ultimate。
        /// ⚠️ 之前 UI 信任 dropdown 读的是 validity(parse),所以设 never/marginal/full 后 validity 仍是 unknown →
        /// 看起来「只有终极信任成功」。dropdown 应该读这个 ownertrust。
        static func parseOwnertrust(_ raw: String) -> GPGTrustLevel {
            switch raw {
            case "3": return .never
            case "4": return .marginal
            case "5": return .full
            case "6": return .ultimate
            default: return .unknown   // 2 / 空 / 其它 = 未设置
            }
        }

        /// 喂给 `gpg --command-fd 0 trust` menu 的数字。expired / revoked 是密钥状态、不可设置 → nil。
        /// `unknown` = gpg 菜单「1 = I don't know or won't say」,可设置(撤回信任),返回 "1"。
        var editTrustMenuNumber: String? {
            switch self {
            case .unknown: return "1"
            case .never: return "2"
            case .marginal: return "3"
            case .full: return "4"
            case .ultimate: return "5"
            case .expired, .revoked: return nil
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
        /// gpg --with-colons 第 2 字段:**计算出的 validity**(有效性,看签名网 + ownertrust 推出来)。UI 的 trust 徽章用它。
        let trust: GPGTrustLevel
        /// 用户**设置的 ownertrust**(来自 --export-ownertrust),信任 dropdown 的「当前值」用它 —— 跟 validity 区分开,
        /// 否则设 never/marginal/full 后 validity 不变会显示成「未设置」。
        var ownerTrust: GPGTrustLevel = .unknown
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

    /// 验签结果四态。`signer` / `fingerprint` 取自 `--status-fd 1` 的 `GOODSIG` / `VALIDSIG` 状态行。
    enum GPGVerifyResult: Equatable {
        /// 公钥在 keyring 里 + 签名匹配 + 文件未被改动。
        /// - `trusted` 来自 `TRUST_MARGINAL/FULLY/ULTIMATE`（true）/ `TRUST_UNDEFINED/NEVER`（false）。
        /// - `fingerprint` 是 `VALIDSIG` 报告的主密钥 fingerprint（40 hex，子密钥签名时也归到主密钥）；
        ///   `.siz` / `.szs` 等场景用这个跟 metadata 声明的 signerFingerprint 强比对。
        /// - `concerns` 是「签名仍密码学有效，但密钥 / 签名本身有问题」的情况集合：keyExpired / keyRevoked / signatureExpired。
        case validSignature(signer: String?, fingerprint: String?, trusted: Bool, concerns: Set<KeyConcern>)
        /// 签名匹配但公钥不在 keyring。提供 `keyID` 让 UI 给「一键导入」入口。
        case unknownSigner(keyID: String?)
        /// 签名失败 = 文件被改动 / 签名损坏 / 强 fingerprint 校验不通过。最严重的状态。
        case badSignature(signer: String?, fingerprint: String?)
        /// gpg 命令本身失败（非签名层面错误）。
        case verificationError(message: String)

        /// 签名仍密码学有效但密钥 / 签名状态需要关注。
        enum KeyConcern: String, Hashable, CaseIterable {
            case keyExpired       // EXPKEYSIG：签名密钥已过期
            case keyRevoked       // REVKEYSIG：签名密钥已撤销
            case signatureExpired // EXPSIG：签名本身设置了有效期且已过
        }
    }
}

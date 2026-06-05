import Foundation
import Testing
@testable import SimpleZipCore

/// 覆盖 0.3.1 新增的 GPG **纯逻辑**：ownertrust 解析、整把密钥有效能力 / 能否当加密收件人、
/// 子密钥算法映射。这些直接决定信任 dropdown 当前值、收件人 picker 过滤、新建 / 补子密钥用的算法，
/// 全是不依赖 gpg 二进制的纯函数，适合 SwiftPM 测。
struct GPGKeyLogicTests {

    // MARK: - 构造辅助

    private func subkey(caps: String, expired: Bool = false) -> GPGBackend.GPGSubkey {
        GPGBackend.GPGSubkey(
            fingerprint: String(repeating: "A", count: 40),
            capabilities: caps,
            isOnSmartcard: false,
            isStripped: false,
            isExpired: expired
        )
    }

    private func key(
        caps: String,
        subkeys: [GPGBackend.GPGSubkey] = [],
        trust: GPGBackend.GPGTrustLevel = .unknown,
        expired: Bool = false
    ) -> GPGBackend.GPGKey {
        GPGBackend.GPGKey(
            fingerprint: String(repeating: "B", count: 40),
            userID: "Test <t@t>",
            hasSecretKey: false,
            isSecretKeyOnSmartcard: false,
            isSecretKeyStripped: false,
            isExpired: expired,
            trust: trust,
            capabilities: caps,
            subkeys: subkeys,
            source: .userKeyring
        )
    }

    // MARK: - parseOwnertrust（--export-ownertrust 的数字值）

    @Test func parseOwnertrustNumericValues() {
        #expect(GPGBackend.GPGTrustLevel.parseOwnertrust("3") == .never)
        #expect(GPGBackend.GPGTrustLevel.parseOwnertrust("4") == .marginal)
        #expect(GPGBackend.GPGTrustLevel.parseOwnertrust("5") == .full)
        #expect(GPGBackend.GPGTrustLevel.parseOwnertrust("6") == .ultimate)
    }

    @Test func parseOwnertrustUnsetOrUnknownIsUnknown() {
        // 2 = undefined/未设置；空串 / 其它都归 unknown。
        #expect(GPGBackend.GPGTrustLevel.parseOwnertrust("2") == .unknown)
        #expect(GPGBackend.GPGTrustLevel.parseOwnertrust("") == .unknown)
        #expect(GPGBackend.GPGTrustLevel.parseOwnertrust("x") == .unknown)
    }

    // MARK: - effectiveCapabilities（主密钥 + 未过期子密钥的合并能力）

    @Test func effectiveCapabilitiesSignOnlyPrimaryNoEncrypt() {
        // dad / dadba 这种：scSC，纯签名 + 认证，无加密子密钥 → 不能加密。
        let caps = key(caps: "scSC").effectiveCapabilities
        #expect(caps.sign)
        #expect(caps.certify)
        #expect(!caps.encrypt)
        #expect(!caps.authenticate)
    }

    @Test func effectiveCapabilitiesEncryptComesFromSubkey() {
        // 正常密钥：主签证 + 加密子密钥 → encrypt 必须为 true（徽章 / 收件人都看这个）。
        let caps = key(caps: "scSC", subkeys: [subkey(caps: "e")]).effectiveCapabilities
        #expect(caps.sign)
        #expect(caps.encrypt)
    }

    @Test func effectiveCapabilitiesIgnoresExpiredSubkey() {
        // 过期的加密子密钥不算数。
        let caps = key(caps: "scSC", subkeys: [subkey(caps: "e", expired: true)]).effectiveCapabilities
        #expect(!caps.encrypt)
    }

    @Test func effectiveCapabilitiesAuthFromSubkey() {
        let caps = key(caps: "scSC", subkeys: [subkey(caps: "a")]).effectiveCapabilities
        #expect(caps.authenticate)
    }

    // MARK: - canEncryptToRecipient（收件人 picker 过滤）

    @Test func canEncryptRejectsSignOnlyKey() {
        #expect(!key(caps: "scSC").canEncryptToRecipient)
    }

    @Test func canEncryptAcceptsKeyWithEncryptionSubkey() {
        #expect(key(caps: "scSC", subkeys: [subkey(caps: "e")]).canEncryptToRecipient)
    }

    @Test func canEncryptAcceptsPrimaryWithEncryptCapability() {
        // 主密钥本身含 e（少见，但合法）。
        #expect(key(caps: "escE").canEncryptToRecipient)
    }

    @Test func canEncryptRejectsExpiredOrRevokedEvenWithEncryptSubkey() {
        #expect(!key(caps: "scSC", subkeys: [subkey(caps: "e")], expired: true).canEncryptToRecipient)
        #expect(!key(caps: "scSC", subkeys: [subkey(caps: "e")], trust: .revoked).canEncryptToRecipient)
        #expect(!key(caps: "scSC", subkeys: [subkey(caps: "e")], trust: .expired).canEncryptToRecipient)
    }

    // MARK: - subkeyAlgorithm(for:)（新建 / 补子密钥的算法映射）

    @Test func subkeyAlgorithmEd25519EncryptIsCv25519() {
        // EdDSA 不能加密 → 加密子密钥必须用 cv25519；签名 / 认证仍用 ed25519。
        #expect(GPGBackend.GPGKeyAlgorithm.ed25519.subkeyAlgorithm(for: .encrypt) == "cv25519")
        #expect(GPGBackend.GPGKeyAlgorithm.ed25519.subkeyAlgorithm(for: .sign) == "ed25519")
        #expect(GPGBackend.GPGKeyAlgorithm.ed25519.subkeyAlgorithm(for: .authenticate) == "ed25519")
        // encryptionSubkeyAlgorithm 便捷属性走同一映射。
        #expect(GPGBackend.GPGKeyAlgorithm.ed25519.encryptionSubkeyAlgorithm == "cv25519")
    }

    @Test func subkeyAlgorithmRSAStaysSameBitLength() {
        for algo: GPGBackend.GPGKeyAlgorithm in [.rsa4096, .rsa3072, .rsa2048] {
            #expect(algo.subkeyAlgorithm(for: .encrypt) == algo.rawValue)
            #expect(algo.subkeyAlgorithm(for: .sign) == algo.rawValue)
        }
    }
}

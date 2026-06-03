import Foundation
import Testing
@testable import SimpleZipCore

/// 覆盖 `GPGFileKind` 的**纯解析**逻辑（装甲头 + list-packets 文本），不依赖 gpg 二进制。
/// 这是「双击 .gpg → 区分 加密数据 / 公钥 / 私钥 / 签名」路由的判定核心。
struct GPGFileKindTests {
    // MARK: - 装甲头

    @Test func armorPublicKey() {
        let text = "-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nmQENBF...\n"
        #expect(GPGFileKind.fromArmorHeader(text) == .publicKey)
    }

    @Test func armorPrivateKey() {
        let text = "-----BEGIN PGP PRIVATE KEY BLOCK-----\n\nlQOYBF...\n"
        #expect(GPGFileKind.fromArmorHeader(text) == .privateKey)
    }

    @Test func armorSecretKeyBlockAlias() {
        // 某些导出工具用 "SECRET KEY BLOCK" 而非 "PRIVATE KEY BLOCK"。
        let text = "-----BEGIN PGP SECRET KEY BLOCK-----\n"
        #expect(GPGFileKind.fromArmorHeader(text) == .privateKey)
    }

    @Test func armorEncryptedMessage() {
        let text = "-----BEGIN PGP MESSAGE-----\n\nhQEMA...\n"
        #expect(GPGFileKind.fromArmorHeader(text) == .encryptedMessage)
    }

    @Test func armorDetachedSignature() {
        let text = "-----BEGIN PGP SIGNATURE-----\n\niQEz...\n"
        #expect(GPGFileKind.fromArmorHeader(text) == .detachedSignature)
    }

    @Test func armorClearSignedBeatsSignature() {
        // "SIGNED MESSAGE" 含 "SIGNATURE" 子串吗？不含，但必须先判 SIGNED MESSAGE 再判 SIGNATURE。
        let text = "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA512\n\nhello\n"
        #expect(GPGFileKind.fromArmorHeader(text) == .clearSigned)
    }

    @Test func armorSkipsCommentAndVersionLines() {
        let text = "Comment: GPGTools\nVersion: GnuPG v2\n\n-----BEGIN PGP PUBLIC KEY BLOCK-----\n"
        #expect(GPGFileKind.fromArmorHeader(text) == .publicKey)
    }

    @Test func armorReturnsNilForNonArmored() {
        // 二进制 / 普通文本没有 BEGIN PGP 头 → nil（交给 list-packets 兜底）。
        #expect(GPGFileKind.fromArmorHeader("PK\u{03}\u{04}\u{14}binary zip bytes") == nil)
        #expect(GPGFileKind.fromArmorHeader("just some plain text\nsecond line") == nil)
    }

    @Test func armorNonPGPBeginIsUnknown() {
        // 别的 PEM/装甲（如证书）明确不是 PGP → unknown，绝不当加密数据解。
        #expect(GPGFileKind.fromArmorHeader("-----BEGIN CERTIFICATE-----\n") == .unknown)
    }

    // MARK: - 二进制首包头字节（RFC 4880 packet tag）

    /// 构造一个「只含首包头字节」的 Data。`tag` + `newFormat` 决定首字节。
    private func packetHeader(tag: UInt8, newFormat: Bool) -> Data {
        let first: UInt8 = newFormat
            ? (0xC0 | (tag & 0x3F))            // 11 + 6-bit tag
            : (0x80 | ((tag & 0x0F) << 2))     // 10 + 4-bit tag + 2-bit length-type
        return Data([first, 0x00, 0x00])
    }

    @Test func binarySecretKey() {
        // tag 5 = Secret-Key（私钥导出首包）。
        #expect(GPGFileKind.fromBinaryPacketTag(packetHeader(tag: 5, newFormat: false)) == .privateKey)
        #expect(GPGFileKind.fromBinaryPacketTag(packetHeader(tag: 5, newFormat: true)) == .privateKey)
    }

    @Test func binaryPublicKey() {
        // tag 6 = Public-Key（公钥导出首包）。
        #expect(GPGFileKind.fromBinaryPacketTag(packetHeader(tag: 6, newFormat: false)) == .publicKey)
        #expect(GPGFileKind.fromBinaryPacketTag(packetHeader(tag: 6, newFormat: true)) == .publicKey)
    }

    @Test func binaryPubkeyEncrypted() {
        // tag 1 = Public-Key Encrypted Session Key（公钥加密消息首包）。
        #expect(GPGFileKind.fromBinaryPacketTag(packetHeader(tag: 1, newFormat: false)) == .encryptedMessage)
        #expect(GPGFileKind.fromBinaryPacketTag(packetHeader(tag: 1, newFormat: true)) == .encryptedMessage)
    }

    @Test func binarySymkeyEncrypted() {
        // tag 3 = Symmetric-Key Encrypted Session Key（对称加密消息首包）。
        #expect(GPGFileKind.fromBinaryPacketTag(packetHeader(tag: 3, newFormat: true)) == .encryptedMessage)
    }

    @Test func binarySEIPAndCompressedAreMessages() {
        #expect(GPGFileKind.fromBinaryPacketTag(packetHeader(tag: 18, newFormat: true)) == .encryptedMessage) // SEIP
        #expect(GPGFileKind.fromBinaryPacketTag(packetHeader(tag: 8, newFormat: true)) == .encryptedMessage)  // Compressed
    }

    @Test func binarySignature() {
        // tag 2 = Signature。
        #expect(GPGFileKind.fromBinaryPacketTag(packetHeader(tag: 2, newFormat: false)) == .detachedSignature)
    }

    @Test func binaryNonPGPHighBitClearIsUnknown() {
        // ZIP 以 'PK' (0x50 0x4B) 开头 —— 高位为 0，绝不是 OpenPGP 包头 → unknown（不会误当加密数据解）。
        #expect(GPGFileKind.fromBinaryPacketTag(Data([0x50, 0x4B, 0x03, 0x04])) == .unknown)
        #expect(GPGFileKind.fromBinaryPacketTag(Data()) == .unknown)
    }

    @Test func binaryUnknownTagIsUnknown() {
        // tag 10 = Marker（不属任何我们关心的类别）→ unknown。
        #expect(GPGFileKind.fromBinaryPacketTag(packetHeader(tag: 10, newFormat: true)) == .unknown)
    }

    // MARK: - isKeyMaterial

    @Test func keyMaterialFlag() {
        #expect(GPGFileKind.publicKey.isKeyMaterial)
        #expect(GPGFileKind.privateKey.isKeyMaterial)
        #expect(!GPGFileKind.encryptedMessage.isKeyMaterial)
        #expect(!GPGFileKind.detachedSignature.isKeyMaterial)
        #expect(!GPGFileKind.unknown.isKeyMaterial)
    }
}

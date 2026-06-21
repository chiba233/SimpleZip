//
//  GPGFileKind.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/03.
//
//  「双击打开 .gpg」的内容嗅探分类器。
//
//  动机：`.gpg`/`.pgp`/`.asc` **按后缀不保证是加密数据** —— 同样后缀也可能是公钥导出、私钥导出、
//  分离签名、clearsign 文本。直接「解密并当压缩包打开」会对一个公钥文件无意义地弹 pinentry。
//  所以打开前先嗅探内容分类，再路由：
//    - 公钥 / 私钥  → 唤起设置里的「导入钥匙串」（复用现有 importKey，不解密）
//    - 加密数据     → 解密 → 当加密压缩包打开
//    - 签名 / 其他  → 落回默认 app 打开（不属本功能）
//
//  嗅探**只读包头**：装甲文件读首行 `-----BEGIN PGP …-----`（纯函数、可单测）；二进制走
//  `gpg --list-packets`（只列包结构，**不解密、不需要 passphrase**）。
//

import Foundation

/// 一个 `.gpg`/`.pgp`/`.asc` 文件的内容类别。
enum GPGFileKind: Equatable, Sendable {
    /// 公钥导出（`PUBLIC KEY BLOCK` / `public key packet`，且不含私钥材料）。
    case publicKey
    /// 私钥导出（`PRIVATE KEY BLOCK` / `secret key packet`）。导入是敏感操作，UI 要额外提示。
    case privateKey
    /// 加密数据（`PGP MESSAGE` / `pubkey enc` / `symkey enc`）。可解密后当压缩包打开。
    case encryptedMessage
    /// 分离签名（`PGP SIGNATURE` / 独立 `signature packet`）。非本功能范围。
    case detachedSignature
    /// clearsign 内联签名文本（`PGP SIGNED MESSAGE`）。非本功能范围。
    case clearSigned
    /// 无法识别为 OpenPGP 内容（嗅探失败 / 不是 PGP 文件）。
    case unknown

    /// 是否为「钥匙串材料」—— 命中即应路由到导入流程而非解密。
    var isKeyMaterial: Bool { self == .publicKey || self == .privateKey }
}

extension GPGFileKind {
    /// 纯函数：从装甲（ASCII-armored）文件首个 `-----BEGIN PGP …-----` 头行定性。
    ///
    /// 传入文件开头的一段文本即可（无需读全文）。识别不到装甲头返回 nil（交给二进制 list-packets 兜底）。
    static func fromArmorHeader(_ text: String) -> GPGFileKind? {
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("-----BEGIN PGP ") else {
                // 装甲文件的有效负载前可能有空行 / 注释行，继续找；遇到明显非空非注释正文则停。
                if line.isEmpty || line.hasPrefix("Comment:") || line.hasPrefix("Version:") { continue }
                // 第一行有内容但不是 BEGIN PGP，多半不是装甲文件。
                if line.hasPrefix("-----BEGIN ") { return .unknown }
                continue
            }
            let upper = line.uppercased()
            if upper.contains("PUBLIC KEY BLOCK") { return .publicKey }
            if upper.contains("PRIVATE KEY BLOCK") || upper.contains("SECRET KEY BLOCK") { return .privateKey }
            if upper.contains("SIGNED MESSAGE") { return .clearSigned }
            if upper.contains("SIGNATURE") { return .detachedSignature }
            if upper.contains("MESSAGE") { return .encryptedMessage }
            return .unknown
        }
        return nil
    }

    /// 纯函数：从二进制 OpenPGP 数据的**首个包头字节**定性（RFC 4880 §4.2 packet tag）。
    ///
    /// **绝不起 gpg 进程、绝不解密、绝不弹 passphrase** —— 只看第一个 packet 的 tag。
    /// （早期版本误用 `gpg --list-packets`：它对加密文件会尝试解密内层并触发 pinentry，
    ///  用户取消就让 list-packets 非零退出、把加密文件误判成「不可解密」。改成直接读包头杜绝此问题。）
    ///
    /// 包头首字节：bit7 必须为 1。bit6=1 → new format，tag = 低 6 位；bit6=0 → old format，tag = bit5..2。
    static func fromBinaryPacketTag(_ bytes: Data) -> GPGFileKind {
        guard let first = bytes.first, (first & 0x80) != 0 else { return .unknown }
        let tag: Int = (first & 0x40) != 0
            ? Int(first & 0x3F)          // new format
            : Int((first >> 2) & 0x0F)   // old format
        switch tag {
        case 5, 7:        return .privateKey        // Secret-Key / Secret-Subkey
        case 6, 14:       return .publicKey         // Public-Key / Public-Subkey
        case 1, 3:        return .encryptedMessage  // PK-ESK / SK-ESK（加密会话密钥）
        case 8, 9, 18:    return .encryptedMessage  // Compressed / Sym-Enc / SEIP（加密/压缩数据）
        case 2:           return .detachedSignature // Signature
        default:          return .unknown
        }
    }
}

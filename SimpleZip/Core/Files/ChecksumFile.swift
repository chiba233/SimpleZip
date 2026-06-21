//
//  ChecksumFile.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  0.4.3 #11:校验文件(SHA256SUMS / checksums.txt / *.sha256 / *.md5 / *.sfv)的解析与生成。
//  这是「非 SimpleZip 用户也能验证」的桥 —— 生成走 GNU coreutils 兼容格式(`sha256sum -c` 直接可用),
//  解析兼容 GNU(`<hex>  <name>`,可带 `*` 二进制标记)、BSD(`SHA256 (name) = <hex>`)、
//  SFV(`<name> <crc32>`,`;` 注释)和单摘要 sidecar(`.sha256` 一行裸 hex)。
//  纯文本处理,不碰文件系统 —— 哈希计算与文件遍历由调用方(HashService)负责。
//

import Foundation

/// 校验文件里一行的算法 —— 按摘要十六进制长度唯一推断。
public nonisolated enum ChecksumAlgorithm: String, CaseIterable, Sendable {
    case crc32 = "CRC32"     // 8
    case md5 = "MD5"         // 32
    case sha1 = "SHA1"       // 40
    case sha256 = "SHA256"   // 64
    case sha512 = "SHA512"   // 128

    /// 摘要 hex 长度 → 算法。长度不在表内 = 不是合法摘要。
    public static func inferred(fromHexLength length: Int) -> ChecksumAlgorithm? {
        switch length {
        case 8: return .crc32
        case 32: return .md5
        case 40: return .sha1
        case 64: return .sha256
        case 128: return .sha512
        default: return nil
        }
    }
}

/// 校验文件里的一条记录:相对文件名 + 期望摘要(小写 hex)+ 算法。
public nonisolated struct ChecksumFileEntry: Equatable, Sendable {
    public let name: String
    public let digestHex: String
    public let algorithm: ChecksumAlgorithm

    public init(name: String, digestHex: String, algorithm: ChecksumAlgorithm) {
        self.name = name
        self.digestHex = digestHex.lowercased()
        self.algorithm = algorithm
    }
}

/// `nonisolated`:纯解析,CLI companion 与后台流程都要在非主隔离上下文调(app target 默认 MainActor 隔离)。
public nonisolated enum ChecksumFile {

    /// 这个文件名是不是校验文件(右键给「验证校验文件」入口的判定)。
    public static func isChecksumFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if ["sha256sums", "sha512sums", "sha1sums", "md5sums", "checksums.txt", "checksum.txt"].contains(lower) {
            return true
        }
        let ext = (lower as NSString).pathExtension
        return ["sha256", "sha512", "sha1", "md5", "sfv", "crc"].contains(ext)
    }

    /// 解析校验文件文本。`fileName` 用于单摘要 sidecar 推断目标名(`app.dmg.sha256` → `app.dmg`)。
    /// 容错:解析不出的行静默跳过(校验文件常混注释 / 空行 / 平台差异),全部解析不出返回空数组。
    public static func parse(_ text: String, fileName: String) -> [ChecksumFileEntry] {
        var entries: [ChecksumFileEntry] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#") else { continue }
            if let entry = parseBSDLine(line) ?? parseGNULine(line) ?? parseSFVLine(line) {
                entries.append(entry)
            } else if entries.isEmpty, let single = parseBareDigest(line, fileName: fileName) {
                // 单摘要 sidecar:整行就是一个 hex(目标名从文件名剥 .sha256 等后缀得来)。
                entries.append(single)
            }
        }
        return entries
    }

    /// 生成 GNU coreutils 兼容的 SHA256SUMS 文本(`sha256sum -c SHA256SUMS` 直接可验)。
    /// 两个空格分隔 = 文本模式;名字按给定顺序原样输出。
    public static func generateSHA256SUMS(_ entries: [(name: String, digestHex: String)]) -> String {
        entries.map { "\($0.digestHex.lowercased())  \($0.name)" }.joined(separator: "\n") + "\n"
    }

    // MARK: - 行解析

    /// BSD 格式:`SHA256 (file name) = hex`。
    private static func parseBSDLine(_ line: String) -> ChecksumFileEntry? {
        guard let match = line.wholeMatch(of: /(?i)(CRC32|MD5|SHA1|SHA256|SHA512)\s*\((.+)\)\s*=\s*([0-9a-fA-F]+)/) else {
            return nil
        }
        let digest = String(match.3)
        guard let algorithm = ChecksumAlgorithm.inferred(fromHexLength: digest.count),
              algorithm.rawValue.lowercased() == String(match.1).lowercased() else { return nil }
        return ChecksumFileEntry(name: String(match.2), digestHex: digest, algorithm: algorithm)
    }

    /// GNU 格式:`hex  name` / `hex *name`(`*` = 二进制模式标记,语义相同)。
    private static func parseGNULine(_ line: String) -> ChecksumFileEntry? {
        guard let match = line.wholeMatch(of: /([0-9a-fA-F]{8,128})[ \t]+\*?(.+)/) else { return nil }
        let digest = String(match.1)
        guard let algorithm = ChecksumAlgorithm.inferred(fromHexLength: digest.count) else { return nil }
        return ChecksumFileEntry(name: String(match.2), digestHex: digest, algorithm: algorithm)
    }

    /// SFV 格式:`name hex8`(CRC32 在行尾)。名字可含空格,取最后一个空白段当摘要。
    private static func parseSFVLine(_ line: String) -> ChecksumFileEntry? {
        guard let match = line.wholeMatch(of: /(.+?)[ \t]+([0-9a-fA-F]{8})/) else { return nil }
        return ChecksumFileEntry(name: String(match.1), digestHex: String(match.2), algorithm: .crc32)
    }

    /// 单摘要 sidecar:整行裸 hex。目标名 = 校验文件名去掉算法后缀;剥完为空则放弃。
    private static func parseBareDigest(_ line: String, fileName: String) -> ChecksumFileEntry? {
        guard line.wholeMatch(of: /[0-9a-fA-F]+/) != nil,
              let algorithm = ChecksumAlgorithm.inferred(fromHexLength: line.count) else { return nil }
        let target = (fileName as NSString).deletingPathExtension
        guard !target.isEmpty, target != fileName else { return nil }
        return ChecksumFileEntry(name: target, digestHex: line, algorithm: algorithm)
    }
}

//
//  ZipArchiveComment.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  0.4.2 #114 后续：ZIP **归档级注释的原生写入**。
//
//  7zz 没有写注释的命令行参数，但 ZIP 的归档级注释就存在文件末尾的 EOCD
//  （End of Central Directory）记录里：
//      签名(4) | 盘号(2) | 目录起始盘(2) | 本盘条目数(2) | 总条目数(2)
//      | 目录大小(4) | 目录偏移(4) | 注释长度(2) | 注释(≤65535 字节)
//  改注释 = 只动「注释长度 + 注释」两个尾部字段，EOCD 之前的所有字节
//  （条目数据 + central directory + EOCD 头 20 字节）原样保留。ZIP64 的注释
//  也存这条经典 EOCD（ZIP64 EOCD 自身没有注释字段），同样适用。
//
//  数据安全：绝不在原文件上就地改 —— 复制到同目录临时文件（APFS clonefile，
//  瞬时 CoW）→ 截断到注释长度字段 → 追加新长度 + 新注释 → `replaceItemAt`
//  原子替换。任何一步失败原包字节不变，临时文件清掉。
//
//  条目级注释**不做**：它存在 central directory 每条记录里，改动要重写整个
//  central directory 并修正 EOCD 偏移，出错即损坏归档 —— 收益配不上风险。
//

import Foundation

enum ZipArchiveCommentError: Error, Equatable {
    /// 找不到合法 EOCD（不是 zip / 文件被截断 / 尾部结构对不上）。
    case eocdNotFound
    /// 注释 UTF-8 字节数超过 ZIP 格式上限 65535。
    case commentTooLong(Int)
    /// 0.4.3 #7:写后回读验证失败 —— 临时副本的注释区解析结果与刚写入的不一致(绝不替换原包)。
    case verificationFailed
}

enum ZipArchiveComment {

    /// ZIP 格式注释字段上限（EOCD 注释长度是 UInt16）。
    nonisolated static let maxCommentBytes = 65_535

    /// EOCD 定位结果：`eocdOffset` 是 EOCD 签名在文件里的绝对偏移。
    struct EOCDLocation: Equatable {
        let eocdOffset: UInt64
        let commentLength: Int
    }

    // MARK: - 定位

    /// 在文件尾部定位 EOCD。从文件末尾向前扫签名 `PK\x05\x06`，**严格校验**
    /// 「签名偏移 + 22 + 声明的注释长度 == 文件大小」才算数 —— 注释正文里出现
    /// 同样字节序列的假签名过不了这条校验，会继续向前扫到真 EOCD。
    nonisolated static func locateEndOfCentralDirectory(at url: URL) throws -> EOCDLocation {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw ZipArchiveCommentError.eocdNotFound }

        let tailLength = UInt64(min(fileSize, UInt64(22 + maxCommentBytes)))
        let tailStart = fileSize - tailLength
        try handle.seek(toOffset: tailStart)
        guard let tail = try handle.read(upToCount: Int(tailLength)), tail.count == Int(tailLength) else {
            throw ZipArchiveCommentError.eocdNotFound
        }
        let bytes = [UInt8](tail)

        var index = bytes.count - 22
        while index >= 0 {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B, bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                let declared = Int(bytes[index + 20]) | (Int(bytes[index + 21]) << 8)
                if tailStart + UInt64(index) + 22 + UInt64(declared) == fileSize {
                    return EOCDLocation(eocdOffset: tailStart + UInt64(index), commentLength: declared)
                }
            }
            index -= 1
        }
        throw ZipArchiveCommentError.eocdNotFound
    }

    // MARK: - 读

    /// 读归档级注释。没有注释返回空串。无效 UTF-8 字节做有损解码（不抛错）——
    /// 旧工具写的 cp437 注释至少能看个大概，展示层（7zz 解析）另有自己的口径。
    nonisolated static func readComment(at url: URL) throws -> String {
        let location = try locateEndOfCentralDirectory(at: url)
        guard location.commentLength > 0 else { return "" }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: location.eocdOffset + 22)
        guard let data = try handle.read(upToCount: location.commentLength) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 写

    /// 写（或清空：传空串）归档级注释。UTF-8 编码，超 65535 字节抛错。
    /// 全程不动原文件：同目录临时副本上改尾部，成功后原子替换。
    nonisolated static func writeComment(_ comment: String, to url: URL) throws {
        let bytes = Array(comment.utf8)
        guard bytes.count <= maxCommentBytes else {
            throw ZipArchiveCommentError.commentTooLong(bytes.count)
        }
        let location = try locateEndOfCentralDirectory(at: url)

        let fileManager = FileManager.default
        // 0.4.3 #4:空间预检 —— 同目录整包副本,需要 ~1x 包大小。
        if let size = ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value {
            try DiskSpacePreflight.ensure(estimatedBytes: size, at: url.deletingLastPathComponent())
        }
        // 临时副本放归档同目录（同卷才能 `replaceItemAt` 原子替换），隐藏名 + UUID 防撞。
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).simplezip-comment-\(UUID().uuidString).tmp")
        try fileManager.copyItem(at: url, to: temporary)
        var replaced = false
        defer {
            if !replaced { try? fileManager.removeItem(at: temporary) }
        }

        let handle = try FileHandle(forWritingTo: temporary)
        do {
            // 截到「注释长度」字段起点（EOCD 头 20 字节保留），再追加新长度 + 新注释。
            try handle.truncate(atOffset: location.eocdOffset + 20)
            try handle.seekToEnd()
            var payload = Data([UInt8(bytes.count & 0xFF), UInt8((bytes.count >> 8) & 0xFF)])
            payload.append(contentsOf: bytes)
            try handle.write(contentsOf: payload)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        // 0.4.3 #7:写后验证 —— 替换前在**临时副本**上回读 EOCD,确认注释区可解析且与写入一致;
        // 失败则不替换,原包不动。微秒级开销,无条件做。
        let written = try readComment(at: temporary)
        guard written == comment else {
            throw ZipArchiveCommentError.verificationFailed
        }

        _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        replaced = true
    }
}

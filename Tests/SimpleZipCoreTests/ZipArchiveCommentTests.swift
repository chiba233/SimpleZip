//
//  ZipArchiveCommentTests.swift
//  SimpleZip
//
//  0.4.2：ZIP 归档级注释原生写入（EOCD 尾部改写 + 原子替换）的回归测试。
//  用手工构造的最小合法 zip（空包 = 仅 22 字节 EOCD）+ 7zz 同款字节布局验证，
//  不需要外部工具。
//

import Foundation
import Testing
@testable import SimpleZipCore

struct ZipArchiveCommentTests {

    /// 最小合法空 zip：EOCD 头 20 字节（签名 + 全 0 计数/偏移）+ 注释长度 + 注释。
    private func emptyZipData(comment: String = "") -> Data {
        var data = Data([0x50, 0x4B, 0x05, 0x06])
        data.append(Data(repeating: 0, count: 16))
        let bytes = Array(comment.utf8)
        data.append(UInt8(bytes.count & 0xFF))
        data.append(UInt8((bytes.count >> 8) & 0xFF))
        data.append(contentsOf: bytes)
        return data
    }

    private func makeTempZip(_ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleZip-ZipCommentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("test.zip")
        try data.write(to: url)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func readEmptyCommentOnMinimalZip() throws {
        let url = try makeTempZip(emptyZipData())
        defer { cleanup(url) }
        #expect(try ZipArchiveComment.readComment(at: url) == "")
    }

    @Test func writeAndReadBackRoundTrip() throws {
        let url = try makeTempZip(emptyZipData())
        defer { cleanup(url) }
        try ZipArchiveComment.writeComment("发布说明 v1.0 ✅", to: url)
        #expect(try ZipArchiveComment.readComment(at: url) == "发布说明 v1.0 ✅")
        // 文件大小 = 22 + 注释 UTF-8 字节数,EOCD 之前的字节原样。
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(size == 22 + "发布说明 v1.0 ✅".utf8.count)
    }

    @Test func replaceLongerCommentWithShorterShrinksFile() throws {
        let url = try makeTempZip(emptyZipData(comment: "a much longer original comment"))
        defer { cleanup(url) }
        try ZipArchiveComment.writeComment("short", to: url)
        #expect(try ZipArchiveComment.readComment(at: url) == "short")
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(size == 27)
    }

    @Test func clearCommentTruncatesToBareEOCD() throws {
        let url = try makeTempZip(emptyZipData(comment: "to be removed"))
        defer { cleanup(url) }
        try ZipArchiveComment.writeComment("", to: url)
        #expect(try ZipArchiveComment.readComment(at: url) == "")
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(size == 22)
    }

    /// 注释正文里嵌入假的 EOCD 签名:定位必须跳过假签名(长度严格校验过不了)找到真 EOCD。
    @Test func fakeSignatureInsideCommentIsSkipped() throws {
        let fakeSignature = String(decoding: [0x50, 0x4B, 0x05, 0x06], as: UTF8.self)
        let tricky = "abc\(fakeSignature)def"
        let url = try makeTempZip(emptyZipData(comment: tricky))
        defer { cleanup(url) }
        #expect(try ZipArchiveComment.readComment(at: url) == tricky)
        try ZipArchiveComment.writeComment("clean", to: url)
        #expect(try ZipArchiveComment.readComment(at: url) == "clean")
    }

    @Test func nonZipFileThrowsEOCDNotFound() throws {
        let url = try makeTempZip(Data("definitely not a zip archive at all".utf8))
        defer { cleanup(url) }
        #expect(throws: ZipArchiveCommentError.eocdNotFound) {
            try ZipArchiveComment.readComment(at: url)
        }
        #expect(throws: ZipArchiveCommentError.eocdNotFound) {
            try ZipArchiveComment.writeComment("x", to: url)
        }
    }

    /// EOCD 声明的注释长度与文件实际尾巴对不上(被截断的包)→ 拒绝,不能凑合着写。
    @Test func truncatedCommentLengthIsRejected() throws {
        var data = emptyZipData(comment: "full comment text")
        data.removeLast(5)   // 砍掉注释尾巴 → 声明长度 > 实际
        let url = try makeTempZip(data)
        defer { cleanup(url) }
        #expect(throws: ZipArchiveCommentError.eocdNotFound) {
            try ZipArchiveComment.writeComment("x", to: url)
        }
    }

    @Test func oversizedCommentThrows() throws {
        let url = try makeTempZip(emptyZipData())
        defer { cleanup(url) }
        let huge = String(repeating: "a", count: ZipArchiveComment.maxCommentBytes + 1)
        #expect(throws: ZipArchiveCommentError.commentTooLong(ZipArchiveComment.maxCommentBytes + 1)) {
            try ZipArchiveComment.writeComment(huge, to: url)
        }
        // 失败后原文件未被动过。
        #expect(try ZipArchiveComment.readComment(at: url) == "")
    }

    /// 失败路径不留临时副本(写失败要把同目录的 .tmp 清干净)。
    @Test func failedWriteLeavesNoTemporaryFiles() throws {
        let url = try makeTempZip(Data("not a zip".utf8))
        defer { cleanup(url) }
        #expect(throws: ZipArchiveCommentError.eocdNotFound) {
            try ZipArchiveComment.writeComment("x", to: url)
        }
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(siblings == ["test.zip"])
    }

    /// 带条目数据的「真」zip 形状:EOCD 前面有任意字节,改注释后前缀必须逐字节不变。
    @Test func bytesBeforeEOCDAreUntouched() throws {
        let prefix = Data((0..<2048).map { UInt8($0 % 251) })   // 模拟条目数据 + central directory
        var data = prefix
        data.append(emptyZipData(comment: "old"))
        let url = try makeTempZip(data)
        defer { cleanup(url) }
        try ZipArchiveComment.writeComment("new comment", to: url)
        let after = try Data(contentsOf: url)
        #expect(after.prefix(prefix.count) == prefix)
        #expect(try ZipArchiveComment.readComment(at: url) == "new comment")
    }
}

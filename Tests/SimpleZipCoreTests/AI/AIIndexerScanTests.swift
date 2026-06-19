//
//  AIIndexerScanTests.swift
//  SimpleZipCoreTests
//
//  独立 AI 进程改造 · 阶段0b/1:`AIIndexerScan` 从 app target 抽进 SimpleZipCore 后**首次可单测**。
//  这里只覆盖 `redactedExcerpt` 的**安全闸**(归档安全敏感):疑似密钥文件名、敏感目录(.ssh 等)、空文件一律不读出内容。
//  目录遍历 `scanScope` 因 `AIPrefetchExclusions` 排除一切系统 temp(/var/folders、/tmp、SimpleZip-*),要在非排除位置建树
//  才能测,过于侵入;单文件的 `redactedExcerpt` 不走目录排除,可在普通 temp 文件上确定性验证其门控。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIIndexerScanTests {
    /// 非 `SimpleZip-` 前缀的 temp 子目录(避免被 `isDecryptOrTempPath` 当 scratch 拦掉),用完即删。
    private func makeSandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiscan-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)!.write(to: url)
    }

    @Test func readsPlainTextFileTrimmed() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.md")
        try write("\n  # Project notes\nhello world content\n  ", to: file)

        let excerpt = AIIndexerScan.redactedExcerpt(url: file, fileName: "notes.md")
        #expect(excerpt != nil)
        #expect(excerpt?.contains("hello world content") == true)
        // 首尾空白被 trim 掉。
        #expect(excerpt?.first != " " && excerpt?.first != "\n")
    }

    @Test func blocksSecretNamedFile() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 即便内容是普通文本,文件名疑似密钥(id_rsa)→ 整条不读(blockReason: sensitiveFilename)。
        let file = dir.appendingPathComponent("id_rsa")
        try write("not actually a key, but the name screams secret", to: file)

        #expect(AIIndexerScan.redactedExcerpt(url: file, fileName: "id_rsa") == nil)
    }

    @Test func blocksFileInsideSensitiveDirectory() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 落在 .ssh 目录下 → isSensitiveDirectory 命中 → 不读(哪怕文件名/内容都普通)。
        let sshDir = dir.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        let file = sshDir.appendingPathComponent("config.txt")
        try write("Host example\n  User me", to: file)

        #expect(AIIndexerScan.redactedExcerpt(url: file, fileName: "config.txt") == nil)
    }

    @Test func returnsNilForEmptyFile() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("empty.md")
        try write("", to: file)

        #expect(AIIndexerScan.redactedExcerpt(url: file, fileName: "empty.md") == nil)
    }

    @Test func returnsNilForMissingFile() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("does-not-exist.md")
        #expect(AIIndexerScan.redactedExcerpt(url: missing, fileName: "does-not-exist.md") == nil)
    }
}

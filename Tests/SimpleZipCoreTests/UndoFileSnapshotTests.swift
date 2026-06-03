//
//  UndoFileSnapshotTests.swift
//  SimpleZip
//
//  #86 阶段2：撤销/重做的数据安全核心 `UndoFileSnapshot.matches` —— 「源是否仍是原来那个、未被外部改动」。
//  铁律「绝不静默覆盖用户数据」就靠它返回 false 时跳过该步。用真实临时文件覆盖:同文件→真;内容变/删了重建→假;不存在→nil。
//

import Foundation
import Testing
@testable import SimpleZipCore

struct UndoFileSnapshotTests {
    private let fm = FileManager.default

    /// 在系统临时目录开一个隔离的 scratch 目录,跑完删掉。
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("SimpleZip-UndoSnapTest-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try body(dir)
    }

    @Test
    func initReturnsNilForMissingFile() throws {
        try withTempDir { dir in
            let missing = dir.appendingPathComponent("nope.txt")
            #expect(UndoFileSnapshot(url: missing, fileManager: fm) == nil)
        }
    }

    @Test
    func matchesUnchangedFile() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("a.txt")
            try "hello".data(using: .utf8)!.write(to: file)
            let snapshot = try #require(UndoFileSnapshot(url: file, fileManager: fm))
            #expect(snapshot.matches(url: file, fileManager: fm))
        }
    }

    @Test
    func doesNotMatchAfterContentChange() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("a.txt")
            try "hello".data(using: .utf8)!.write(to: file)
            let snapshot = try #require(UndoFileSnapshot(url: file, fileManager: fm))
            // 改大小 + mtime → 不再匹配 → 撤销时该步会被跳过(不覆盖被外部改动的文件)。
            try "hello world, now longer".data(using: .utf8)!.write(to: file)
            #expect(!snapshot.matches(url: file, fileManager: fm))
        }
    }

    @Test
    func doesNotMatchAfterDeleteAndRecreate() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("a.txt")
            try "hello".data(using: .utf8)!.write(to: file)
            let snapshot = try #require(UndoFileSnapshot(url: file, fileManager: fm))
            // 删除原文件、再以**同名同内容**重建 —— inode(systemFileNumber) 会变,快照应判为不匹配。
            // 这是 device+inode 校验的意义:防「同名同大小同时间的冒名顶替」。
            try fm.removeItem(at: file)
            try "hello".data(using: .utf8)!.write(to: file)
            #expect(!snapshot.matches(url: file, fileManager: fm))
        }
    }

    @Test
    func doesNotMatchWhenFileGone() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("a.txt")
            try "hello".data(using: .utf8)!.write(to: file)
            let snapshot = try #require(UndoFileSnapshot(url: file, fileManager: fm))
            try fm.removeItem(at: file)
            #expect(!snapshot.matches(url: file, fileManager: fm))
        }
    }
}

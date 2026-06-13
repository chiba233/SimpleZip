//
//  FinderFavoritesReaderTests.swift
//  SimpleZipCoreTests
//
//  Q4:给 FinderFavoritesReader 的纯过滤 / 去重逻辑补覆盖(它每次主窗口聚焦都跑、原本零测试)。
//  只测 `existingDeduplicatedDirectories(from:)` —— 不碰 sfl4 解析 / stale-bookmark / 注入缝。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct FinderFavoritesReaderTests {
    /// 每个用例自建一个独立临时目录,defer 清理。
    private func makeScratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SZFinderFavTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func emptyInputReturnsEmpty() {
        #expect(FinderFavoritesReader.existingDeduplicatedDirectories(from: []).isEmpty)
    }

    @Test func filtersNonexistentPaths() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let realDir = scratch.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let missing = scratch.appendingPathComponent("does-not-exist")

        let result = FinderFavoritesReader.existingDeduplicatedDirectories(from: [missing.path, realDir.path])
        #expect(result.map { $0.url.standardizedFileURL.path } == [realDir.standardizedFileURL.path])
    }

    @Test func filtersFilesKeepingOnlyDirectories() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let realDir = scratch.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let file = scratch.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)

        let result = FinderFavoritesReader.existingDeduplicatedDirectories(from: [file.path, realDir.path])
        #expect(result.map { $0.url.standardizedFileURL.path } == [realDir.standardizedFileURL.path])
    }

    @Test func deduplicatesByCanonicalPathKeepingFirst() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let dir = scratch.appendingPathComponent("d")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 同一目录三种写法:直接、重复、含 `..` 绕一圈 —— 规范化后都是同一路径,只应保留一条。
        let viaDotDot = scratch.appendingPathComponent("d/../d").path
        let result = FinderFavoritesReader.existingDeduplicatedDirectories(from: [dir.path, dir.path, viaDotDot])
        #expect(result.count == 1)
        #expect(result.first?.url.standardizedFileURL.path == dir.standardizedFileURL.path)
    }

    @Test func preservesInputOrderOfDistinctDirectories() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let a = scratch.appendingPathComponent("a")
        let b = scratch.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)

        let result = FinderFavoritesReader.existingDeduplicatedDirectories(from: [b.path, a.path])
        #expect(result.map { $0.url.standardizedFileURL.path }
            == [b.standardizedFileURL.path, a.standardizedFileURL.path])
    }
}

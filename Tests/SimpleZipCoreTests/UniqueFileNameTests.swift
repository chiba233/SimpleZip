//
//  UniqueFileNameTests.swift
//  SimpleZip
//
//  #86 阶段1：文件名去重的纯逻辑（创建副本 / 符号链接 / 新建项）抽到 Core 后的回归测试。
//  用注入的 `exists` 闭包模拟「已占用」集合，不碰真实文件系统。
//

import Foundation
import Testing
@testable import SimpleZipCore

struct UniqueFileNameTests {
    private let dir = URL(fileURLWithPath: "/tmp/szt")

    // MARK: - suffixed（创建副本 / 符号链接共用）

    @Test
    func suffixedReturnsBaseSuffixWhenFree() {
        let url = dir.appendingPathComponent("a.txt")
        let result = UniqueFileName.suffixed(for: url, suffix: " copy", exists: { _ in false })
        #expect(result == dir.appendingPathComponent("a copy.txt"))
    }

    @Test
    func suffixedIncrementsFromTwoOnCollision() {
        let url = dir.appendingPathComponent("a.txt")
        let taken: Set<String> = [
            dir.appendingPathComponent("a copy.txt").path,
            dir.appendingPathComponent("a copy 2.txt").path,
        ]
        let result = UniqueFileName.suffixed(for: url, suffix: " copy", exists: { taken.contains($0.path) })
        #expect(result == dir.appendingPathComponent("a copy 3.txt"))
    }

    @Test
    func suffixedHandlesNoExtension() {
        let url = dir.appendingPathComponent("README")
        let result = UniqueFileName.suffixed(for: url, suffix: " 副本", exists: { _ in false })
        #expect(result == dir.appendingPathComponent("README 副本"))
    }

    @Test
    func suffixedPreservesMultiPartExtensionTail() {
        // pathExtension 只取最后一段（tar.gz → gz），与原实现一致：保留这个已知行为，不在此偷偷"修复"。
        let url = dir.appendingPathComponent("data.tar.gz")
        let result = UniqueFileName.suffixed(for: url, suffix: " copy", exists: { _ in false })
        #expect(result == dir.appendingPathComponent("data.tar copy.gz"))
    }

    // MARK: - numbered（新建文件夹 / 文件）

    @Test
    func numberedReturnsPreferredWhenFree() {
        let result = UniqueFileName.numbered(in: dir, preferredName: "New Folder", exists: { _ in false })
        #expect(result == dir.appendingPathComponent("New Folder"))
    }

    @Test
    func numberedIncrementsFromTwoOnCollision() {
        let taken: Set<String> = [
            dir.appendingPathComponent("New Folder").path,
            dir.appendingPathComponent("New Folder 2").path,
        ]
        let result = UniqueFileName.numbered(in: dir, preferredName: "New Folder", exists: { taken.contains($0.path) })
        #expect(result == dir.appendingPathComponent("New Folder 3"))
    }

    @Test
    func numberedKeepsExtensionWhenNumbering() {
        let taken: Set<String> = [dir.appendingPathComponent("note.md").path]
        let result = UniqueFileName.numbered(in: dir, preferredName: "note.md", exists: { taken.contains($0.path) })
        #expect(result == dir.appendingPathComponent("note 2.md"))
    }
}

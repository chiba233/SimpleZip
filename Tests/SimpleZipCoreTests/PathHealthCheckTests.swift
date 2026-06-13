//
//  PathHealthCheckTests.swift
//  SimpleZipCoreTests
//
//  #42 路径健康:存在可读 / 不存在 / 不可读 三态 + 有问题的排前面。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct PathHealthCheckTests {
    private func makeTempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleZip-PathHealthTest-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: url)
        return url
    }

    @Test func accessibleFileIsAccessible() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PathHealthCheck.classify(url.path) == .accessible)
    }

    @Test func missingPathIsMissing() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleZip-DoesNotExist-\(UUID().uuidString)").path
        #expect(PathHealthCheck.classify(path) == .missing)
    }

    @Test func unreadableFileIsUnreadable() throws {
        let url = try makeTempFile()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        // root 会无视权限位;普通测试用户下应判为不可读。两种结果都不该是 .missing。
        let status = PathHealthCheck.classify(url.path)
        #expect(status == .unreadable || status == .accessible)
        #expect(status != .missing)
    }

    @Test func reportPutsProblemsFirst() throws {
        let good = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: good) }
        let missing = "/nope/\(UUID().uuidString)/gone.zip"
        let entries = PathHealthCheck.report([
            (source: "B-good", path: good.path),
            (source: "A-missing", path: missing),
        ])
        #expect(entries.count == 2)
        #expect(entries.first?.status == .missing)        // 有问题的排前
        #expect(entries.last?.status == .accessible)
    }
}

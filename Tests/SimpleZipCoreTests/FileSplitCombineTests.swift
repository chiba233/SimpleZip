//
//  FileSplitCombineTests.swift
//  SimpleZipCoreTests
//
//  「拆分文件 / 合并分卷」纯字节引擎的单测：round-trip、尾片余量、撞名拒绝、
//  非法卷大小、非首卷拒绝、缺中段截断。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct FileSplitCombineTests {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleZip-SplitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func splitThenCombineRoundTripsBytes() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 10_000 字节、3_000/卷 → 4 片：3000、3000、3000、1000。
        let payload = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let source = dir.appendingPathComponent("data.bin")
        try payload.write(to: source)

        let parts = try FileSplitCombine.split(source, volumeSize: 3_000)
        #expect(parts.map(\.lastPathComponent) == ["data.bin.001", "data.bin.002", "data.bin.003", "data.bin.004"])
        let sizes = try parts.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 }
        #expect(sizes == [3_000, 3_000, 3_000, 1_000])

        // 原文件还在(拆分不动源);删掉再合并,确认逐字节一致。
        try FileManager.default.removeItem(at: source)
        let output = try FileSplitCombine.combine(firstVolume: parts[0])
        #expect(output.lastPathComponent == "data.bin")
        #expect(try Data(contentsOf: output) == payload)
    }

    @Test func splitRefusesWhenPartNameOccupied() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("a.txt")
        try Data(repeating: 1, count: 100).write(to: source)
        try Data().write(to: dir.appendingPathComponent("a.txt.002"))

        #expect(throws: FileSplitCombineError.partAlreadyExists("a.txt.002")) {
            try FileSplitCombine.split(source, volumeSize: 40)
        }
        // 预检失败 → 一个分片都不该写出来。
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.txt.001").path))
    }

    @Test func splitRejectsInvalidVolumeSize() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.txt")
        try Data(repeating: 1, count: 10).write(to: source)

        #expect(throws: FileSplitCombineError.invalidVolumeSize) {
            try FileSplitCombine.split(source, volumeSize: 0)
        }
    }

    @Test func combineRejectsNonFirstVolume() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let second = dir.appendingPathComponent("a.txt.002")
        try Data(repeating: 2, count: 10).write(to: second)

        #expect(throws: FileSplitCombineError.notFirstVolume) {
            try FileSplitCombine.combine(firstVolume: second)
        }
    }

    @Test func combineAvoidsOverwritingExistingOutput() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = Data(repeating: 9, count: 5_000)
        let source = dir.appendingPathComponent("doc.pdf")
        try payload.write(to: source)
        let parts = try FileSplitCombine.split(source, volumeSize: 2_000)

        // 原文件还在 → 合并输出必须避让成「doc 2.pdf」,绝不覆盖。
        let output = try FileSplitCombine.combine(firstVolume: parts[0])
        #expect(output.lastPathComponent == "doc 2.pdf")
        #expect(try Data(contentsOf: output) == payload)
        #expect(try Data(contentsOf: source) == payload)
    }

    @Test func volumePartsStopAtGap() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        for index in [1, 2, 4] {
            try Data(repeating: UInt8(index), count: 10)
                .write(to: dir.appendingPathComponent(String(format: "x.zip.%03d", index)))
        }
        let parts = FileSplitCombine.volumeParts(for: dir.appendingPathComponent("x.zip.001"))
        // 003 缺席 → 只认 001、002 这个连续前缀(缺中段拼出来必是坏文件)。
        #expect(parts.map(\.lastPathComponent) == ["x.zip.001", "x.zip.002"])
    }
}

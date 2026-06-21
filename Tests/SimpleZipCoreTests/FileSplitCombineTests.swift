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

/// 0.4.2:分卷集识别(纯文件名逻辑)。
struct SplitVolumeSetTests {

    @Test func recognizesNumericFamilyFromAnyMember() {
        let siblings = ["a.7z.001", "a.7z.002", "a.7z.003", "other.txt"]
        let set = FileSplitCombine.volumeSet(forMemberNamed: "a.7z.002", among: siblings)
        #expect(set?.baseName == "a.7z")
        #expect(set?.memberIndex == 2)
        #expect(set?.presentIndices == [1, 2, 3])
        #expect(set?.missingIndices == [])
        #expect(set?.isComplete == true)
    }

    @Test func reportsMissingVolumes() {
        let siblings = ["a.7z.001", "a.7z.003", "a.7z.005"]
        let set = FileSplitCombine.volumeSet(forMemberNamed: "a.7z.001", among: siblings)
        #expect(set?.missingIndices == [2, 4])
        #expect(set?.isComplete == false)
        #expect(set?.highestIndex == 5)
    }

    @Test func recognizesPartRarFamily() {
        let siblings = ["movie.part1.rar", "movie.part2.rar", "movie.part3.rar"]
        let set = FileSplitCombine.volumeSet(forMemberNamed: "movie.part2.rar", among: siblings)
        #expect(set?.baseName == "movie.rar")
        #expect(set?.memberIndex == 2)
        #expect(set?.volumeCount == 3)
    }

    @Test func lonelyNumericExtensionIsNotASet() {
        // 「碰巧全数字扩展名」的孤立文件(卷号≠1、同目录无同伴)不能误判成分卷。
        #expect(FileSplitCombine.volumeSet(forMemberNamed: "report.2024", among: ["report.2024", "x.txt"]) == nil)
    }

    @Test func lonelyFirstVolumeIsStillASet() {
        let set = FileSplitCombine.volumeSet(forMemberNamed: "a.zip.001", among: ["a.zip.001"])
        #expect(set?.presentIndices == [1])
        #expect(set?.isComplete == true)
    }

    @Test func nonVolumeNamesReturnNil() {
        #expect(FileSplitCombine.volumeSet(forMemberNamed: "a.zip", among: ["a.zip"]) == nil)
        #expect(FileSplitCombine.volumeSet(forMemberNamed: "a.01", among: ["a.01", "a.02"]) == nil)   // 2 位数字不算(避免误伤)
    }

    @Test func volumesPastThousandKeepWorking() {
        let siblings = ["big.bin.999", "big.bin.1000", "big.bin.001"]
        let set = FileSplitCombine.volumeSet(forMemberNamed: "big.bin.1000", among: siblings)
        #expect(set?.presentIndices == [1, 999, 1000])
        #expect(set?.missingIndices.count == 997)
    }

    /// 批量 `volumeSets(among:)`(O(n) 热路径入口)对每个名字的结果必须与逐个 `volumeSet(forMemberNamed:among:)` 一致。
    @Test func volumeSetsBatchMatchesPerName() {
        let siblings = [
            "release.7z.001", "release.7z.002", "release.7z.003",
            "movie.part1.rar", "movie.part2.rar",
            "notes.txt", "a.zip", "single.bin.001", "report.2024",
        ]
        let batch = FileSplitCombine.volumeSets(among: siblings)
        for name in siblings {
            let single = FileSplitCombine.volumeSet(forMemberNamed: name, among: siblings)
            #expect((batch[name] == nil) == (single == nil), "nil-ness mismatch for \(name)")
            #expect(batch[name]?.baseName == single?.baseName, "baseName mismatch for \(name)")
            #expect(batch[name]?.presentNames == single?.presentNames, "presentNames mismatch for \(name)")
            #expect(batch[name]?.volumeCount == single?.volumeCount, "volumeCount mismatch for \(name)")
        }
    }
}

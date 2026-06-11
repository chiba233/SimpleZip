//
//  SelfTestSampleRunner.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/12.
//
//  0.4.3 #12:自检样本库 —— 开发者工具里一键对**真实后端**跑一批恶心样本,确认安全
//  与解析逻辑没有回归。与 SwiftPM 单测互补:这里跑的是装进 app 的 7zz / 系统 tar /
//  当前偏好环境,发版前最后一道「现场体检」。
//
//  样本不进仓库、不占包体:全部运行时现造。路径逃逸 / 保留名这类 7zz 拒绝正常创建的
//  条目名,用内置的「裸 zip 写入器」直接拼字节(stored 无压缩 + CRC32,zip 格式最小子集)。
//

import Foundation

@MainActor
enum SelfTestSampleRunner {

    struct SampleResult: Identifiable {
        let id = UUID()
        let name: String
        let passed: Bool
        let detail: String
    }

    /// 跑全部样本,返回逐项结果(全部在临时目录,跑完即清)。
    static func runAll() async -> [SampleResult] {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("SimpleZip-SelfTest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        var results: [SampleResult] = []

        // ① 路径安全报告的全部恶意家族:裸 zip 塞构造条目 → 7zz 必须能 list,报告必须逐类命中。
        await results.append(securityFamiliesSample(in: temp))
        // ② 解压侧路径逃逸拦截:`../` 条目在 validate 策略下绝不能落到目标目录之外。
        await results.append(escapeExtractionBlockedSample(in: temp))
        // ③ 损坏 zip:截断的包,test 必须失败(失败 = 通过)。
        await results.append(corruptArchiveSample(in: temp))
        // ④ 加密 zip:list 标记加密;错误口令解压必须失败。
        await results.append(encryptedZipSample(in: temp))
        // ⑤ header-encrypted 7z:无口令 list 必须失败,带口令必须成功。
        await results.append(headerEncryptedSevenZipSample(in: temp))
        // ⑥ 归档级注释:写入 → 读回一致(EOCD 改写路径)。
        results.append(commentRoundTripSample(in: temp))
        // ⑦ 缺分卷:.001/.003 缺 .002,FileSplitCombine 必须报缺口。
        results.append(missingVolumeSample())
        // ⑧ 元数据垃圾识别:.DS_Store / __MACOSX / ._AppleDouble。
        results.append(junkDetectionSample())

        return results
    }

    // MARK: - 各样本

    private static func securityFamiliesSample(in temp: URL) async -> SampleResult {
        let name = "路径安全报告:恶意家族全命中"
        do {
            let zip = temp.appendingPathComponent("families.zip")
            try RawZipWriter.write(entries: [
                ("../escape.txt", "escape"),
                ("/abs/path.txt", "abs"),
                ("C:\\drive\\x.txt", "drive"),
                ("readme.txt", "a"),
                ("README.TXT", "b"),
                ("a\u{0308}.txt", "nfd"),
                ("\u{00E4}.txt", "nfc"),
                ("docs/CON", "reserved"),
                ("invoice\u{202E}fdp.exe", "bidi"),
                ("trailing. ", "trail")
            ], to: zip)
            let items = try await ArchiveService.list(zip)
            let kinds = Set(ArchiveSecurityReport.analyze(items).map(\.kind))
            let expected: Set<ArchiveSecurityFindingKind> = [
                .parentTraversal, .absolutePath, .windowsDrivePath, .caseCollision,
                .normalizationCollision, .windowsReservedName, .controlCharacters, .trailingSpaceOrDot
            ]
            let missing = expected.subtracting(kinds)
            guard missing.isEmpty else {
                return SampleResult(name: name, passed: false, detail: "漏报:\(missing.map(\.rawValue).joined(separator: ", "))")
            }
            return SampleResult(name: name, passed: true, detail: "8/8 家族命中")
        } catch {
            return SampleResult(name: name, passed: false, detail: error.localizedDescription)
        }
    }

    private static func escapeExtractionBlockedSample(in temp: URL) async -> SampleResult {
        let name = "解压拦截:../ 逃逸条目不落盘到目标之外"
        do {
            let zip = temp.appendingPathComponent("escape.zip")
            try RawZipWriter.write(entries: [("../escaped-\(UUID().uuidString.prefix(6)).txt", "boom")], to: zip)
            let dest = temp.appendingPathComponent("escape-out", isDirectory: true)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            do {
                try await ArchiveService.extract(zip, to: dest, overwriteBehavior: .overwrite, safetyPolicy: .validate)
            } catch {
                return SampleResult(name: name, passed: true, detail: "解压被拒(预期):\(type(of: error))")
            }
            // 没抛错也行 —— 只要目标目录的**父级**没有被写出逃逸文件。
            let parent = dest.deletingLastPathComponent()
            let leaked = (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?
                .contains { $0.hasPrefix("escaped-") } ?? false
            return leaked
                ? SampleResult(name: name, passed: false, detail: "逃逸文件落到了目标目录之外!")
                : SampleResult(name: name, passed: true, detail: "无外泄文件")
        } catch {
            return SampleResult(name: name, passed: false, detail: error.localizedDescription)
        }
    }

    private static func corruptArchiveSample(in temp: URL) async -> SampleResult {
        let name = "损坏包:截断 zip 的完整性测试必须失败"
        do {
            let good = temp.appendingPathComponent("good-src", isDirectory: true)
            try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
            try String(repeating: "x", count: 4096).write(to: good.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
            var options = ArchiveCreationOptions()
            options.format = .zip
            options.skipDSStore = false
            let zip = temp.appendingPathComponent("good.zip")
            try await ArchiveService.createArchive(from: [good], destination: zip, options: options)
            // 截断尾部 1/3(砍掉中央目录)。
            let data = try Data(contentsOf: zip)
            let corrupt = temp.appendingPathComponent("corrupt.zip")
            try data.prefix(data.count * 2 / 3).write(to: corrupt)
            do {
                try await ArchiveService.test(corrupt)
                return SampleResult(name: name, passed: false, detail: "截断包 test 竟然通过了")
            } catch {
                return SampleResult(name: name, passed: true, detail: "test 失败(预期)")
            }
        } catch {
            return SampleResult(name: name, passed: false, detail: error.localizedDescription)
        }
    }

    private static func encryptedZipSample(in temp: URL) async -> SampleResult {
        let name = "加密 zip:标记加密 + 错口令解压失败"
        do {
            let src = temp.appendingPathComponent("enc-src", isDirectory: true)
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try "secret".write(to: src.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
            var options = ArchiveCreationOptions()
            options.format = .zip
            options.skipDSStore = false
            options.password = "right-password"
            options.passwordConfirmation = "right-password"
            let zip = temp.appendingPathComponent("enc.zip")
            try await ArchiveService.createArchive(from: [src], destination: zip, options: options)

            let items = try await ArchiveService.list(zip)
            guard items.contains(where: { $0.isEncrypted }) else {
                return SampleResult(name: name, passed: false, detail: "list 没把条目标记为加密")
            }
            let dest = temp.appendingPathComponent("enc-out", isDirectory: true)
            do {
                try await ArchiveService.extract(zip, to: dest, overwriteBehavior: .overwrite, password: "wrong", safetyPolicy: .validate)
                return SampleResult(name: name, passed: false, detail: "错误口令解压竟然成功")
            } catch {
                return SampleResult(name: name, passed: true, detail: "加密标记 ✓,错口令被拒 ✓")
            }
        } catch {
            return SampleResult(name: name, passed: false, detail: error.localizedDescription)
        }
    }

    private static func headerEncryptedSevenZipSample(in temp: URL) async -> SampleResult {
        let name = "header 加密 7z:无口令连列表都拿不到"
        do {
            let src = temp.appendingPathComponent("he-src", isDirectory: true)
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try "secret".write(to: src.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
            var options = ArchiveCreationOptions()
            options.format = .sevenZip
            options.skipDSStore = false
            options.password = "pw"
            options.passwordConfirmation = "pw"
            options.sevenZipEncryptFileNames = true
            let archive = temp.appendingPathComponent("he.7z")
            try await ArchiveService.createArchive(from: [src], destination: archive, options: options)

            var listFailedWithoutPassword = false
            do {
                _ = try await ArchiveService.list(archive)
            } catch {
                listFailedWithoutPassword = true
            }
            guard listFailedWithoutPassword else {
                return SampleResult(name: name, passed: false, detail: "无口令 list 竟然成功(header 加密失效?)")
            }
            let items = try await ArchiveService.list(archive, password: "pw")
            guard items.contains(where: { $0.name.hasSuffix("s.txt") }) else {
                return SampleResult(name: name, passed: false, detail: "带口令 list 拿不到条目")
            }
            return SampleResult(name: name, passed: true, detail: "无口令拒列 ✓,带口令可列 ✓")
        } catch {
            return SampleResult(name: name, passed: false, detail: error.localizedDescription)
        }
    }

    private static func commentRoundTripSample(in temp: URL) -> SampleResult {
        let name = "归档注释:EOCD 写入读回一致"
        do {
            let zip = temp.appendingPathComponent("comment.zip")
            try RawZipWriter.write(entries: [("a.txt", "a")], to: zip)
            let comment = "self-test 注释 \u{1F512}"
            try ZipArchiveComment.writeComment(comment, to: zip)
            let read = try ZipArchiveComment.readComment(at: zip)
            return read == comment
                ? SampleResult(name: name, passed: true, detail: "round-trip 一致")
                : SampleResult(name: name, passed: false, detail: "读回不一致:\(read)")
        } catch {
            return SampleResult(name: name, passed: false, detail: error.localizedDescription)
        }
    }

    private static func missingVolumeSample() -> SampleResult {
        let name = "缺分卷:.001/.003 在场必须报缺 .002"
        let names = ["movie.mkv.001", "movie.mkv.003", "unrelated.txt"]
        guard let set = FileSplitCombine.volumeSet(forMemberNamed: "movie.mkv.001", among: names) else {
            return SampleResult(name: name, passed: false, detail: "没识别出分卷集")
        }
        return set.missingIndices.isEmpty
            ? SampleResult(name: name, passed: false, detail: "没报缺卷")
            : SampleResult(name: name, passed: true, detail: "缺卷索引:\(set.missingIndices)")
    }

    private static func junkDetectionSample() -> SampleResult {
        let name = "元数据垃圾识别:.DS_Store / __MACOSX / ._AppleDouble"
        let junk = ["docs/.DS_Store", "__MACOSX/x", "photos/._IMG.jpg", "Thumbs.db"]
        let clean = ["docs/readme.md", "_underscore.txt", "..twodots"]
        let junkOK = junk.allSatisfy(ArchiveJunkFiles.isJunkPath)
        let cleanOK = clean.allSatisfy { !ArchiveJunkFiles.isJunkPath($0) }
        return junkOK && cleanOK
            ? SampleResult(name: name, passed: true, detail: "\(junk.count) 类垃圾命中,正常名零误报")
            : SampleResult(name: name, passed: false, detail: "junk=\(junkOK) clean=\(cleanOK)")
    }
}

/// 最小裸 zip 写入器:stored(无压缩)+ CRC32。**只为自检样本服务** —— 它能写出 7zz
/// 拒绝正常创建的条目名(`../` 逃逸、盘符、保留名),这正是样本的意义。绝不用于生产创建。
private enum RawZipWriter {
    static func write(entries: [(name: String, content: String)], to url: URL) throws {
        var out = Data()
        var central = Data()
        var offsets: [UInt32] = []
        for (name, content) in entries {
            let nameBytes = Array(name.utf8)
            let body = Array(content.utf8)
            let crc = crc32(body)
            offsets.append(UInt32(out.count))
            // Local file header
            out.append(le32(0x0403_4B50))
            out.append(le16(20))            // version needed
            out.append(le16(1 << 11))       // general purpose: UTF-8 names
            out.append(le16(0))             // method: stored
            out.append(le16(0)); out.append(le16(0))   // dos time/date
            out.append(le32(crc))
            out.append(le32(UInt32(body.count)))
            out.append(le32(UInt32(body.count)))
            out.append(le16(UInt16(nameBytes.count)))
            out.append(le16(0))             // extra len
            out.append(contentsOf: nameBytes)
            out.append(contentsOf: body)
        }
        for (index, (name, content)) in entries.enumerated() {
            let nameBytes = Array(name.utf8)
            let body = Array(content.utf8)
            let crc = crc32(body)
            central.append(le32(0x0201_4B50))
            central.append(le16(20)); central.append(le16(20))
            central.append(le16(1 << 11))
            central.append(le16(0))
            central.append(le16(0)); central.append(le16(0))
            central.append(le32(crc))
            central.append(le32(UInt32(body.count)))
            central.append(le32(UInt32(body.count)))
            central.append(le16(UInt16(nameBytes.count)))
            central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0))
            central.append(le32(0))
            central.append(le32(offsets[index]))
            central.append(contentsOf: nameBytes)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        // EOCD
        out.append(le32(0x0605_4B50))
        out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(entries.count)))
        out.append(le16(UInt16(entries.count)))
        out.append(le32(UInt32(central.count)))
        out.append(le32(centralOffset))
        out.append(le16(0))
        try out.write(to: url)
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

//
//  FormatLabRunner.swift
//  SimpleZip
//
//  0.4.4 #6:格式兼容性实验室(只进 DevTools —— 调试件,不是用户功能)。
//  对用户选的小文件夹逐格式跑 create → extract → 验证对比:结构 / 权限 / xattr / 符号链接 /
//  时间戳 / 注释往返 / 可复现 —— 与 SelfTestSampleRunner 同一习语(真后端、临时目录、跑完即清)。
//  样本会先**复制**进临时区再增补探针(xattr / symlink / 可执行位),绝不改用户的原文件夹。
//

import Foundation

@MainActor
enum FormatLabRunner {

    enum Verdict: Equatable {
        case yes
        case no(String)
        /// 该格式不声称支持此维度(能力表 = no)—— 不测不计,矩阵显示「—」。
        case notApplicable
    }

    enum Dimension: String, CaseIterable, Identifiable {
        case structure
        case permissions
        case xattr
        case symlink
        case timestamps
        case comment
        case reproducible

        var id: String { rawValue }
    }

    struct FormatResult: Identifiable {
        let id = UUID()
        let format: ArchiveCreateFormat
        var verdicts: [Dimension: Verdict] = [:]
        var setupFailure: String?
    }

    static let formats: [ArchiveCreateFormat] = [.zip, .sevenZip, .tar, .tarGzip]

    /// 跑全部格式。`sampleFolder` 只读;一切写操作在临时区。
    static func run(sampleFolder: URL) async -> [FormatResult] {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("SimpleZip-FormatLab-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temp) }

        // staging:复制样本 + 加探针(xattr / symlink / 可执行位 / 已知 mtime)。
        let stage: URL
        do {
            stage = try makeStagedSample(from: sampleFolder, in: temp)
        } catch {
            return formats.map { FormatResult(format: $0, verdicts: [:], setupFailure: error.localizedDescription) }
        }

        var results: [FormatResult] = []
        for format in formats {
            results.append(await runFormat(format, stage: stage, temp: temp))
        }
        return results
    }

    // MARK: - 单格式

    private static func runFormat(_ format: ArchiveCreateFormat, stage: URL, temp: URL) async -> FormatResult {
        let fm = FileManager.default
        var result = FormatResult(format: format)
        let workspace = temp.appendingPathComponent("lab-\(format.rawValue)", isDirectory: true)
        try? fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        let archiveURL = workspace.appendingPathComponent("sample.\(format.pathExtension)")
        let extractDir = workspace.appendingPathComponent("extracted", isDirectory: true)
        try? fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        var options = ArchiveCreationOptions()
        options.format = format
        // 链接 / 权限尽量保真:7z 显式开符号链接保留(zip/tar 由后端默认行为决定 —— 验证即目的)。
        if format == .sevenZip {
            options.sevenZipStoreSymbolicLinks = true
        }

        do {
            try await ArchiveService.createArchive(
                from: [stage],
                destination: archiveURL,
                options: options
            )
            try await ArchiveService.extract(archiveURL, to: extractDir, safetyPolicy: .validate)
        } catch {
            result.setupFailure = error.localizedDescription
            return result
        }
        // 解出根 = extractDir/<stage 名>(整包保留路径)。容错:平铺时直接用 extractDir。
        let extractedRoot = fm.fileExists(atPath: extractDir.appendingPathComponent(stage.lastPathComponent).path)
            ? extractDir.appendingPathComponent(stage.lastPathComponent)
            : extractDir

        // ① 结构:条目集对齐(ArchiveDiff 的文件夹快照,路径/大小;junk 不滤 —— 样本是我们自己造的)。
        let diff = ArchiveDiff.compare(
            left: ArchiveDiff.folderItems(at: stage),
            right: ArchiveDiff.folderItems(at: extractedRoot)
        )
        result.verdicts[.structure] = diff.hasDifferences
            ? .no("\(diff.added.count)+/\(diff.removed.count)-/\(diff.changed.count)~")
            : .yes

        // ② 权限:可执行探针的 0755 位回来没。
        let executableProbe = extractedRoot.appendingPathComponent(Self.executableProbeName)
        if let attrs = try? fm.attributesOfItem(atPath: executableProbe.path),
           let permissions = attrs[.posixPermissions] as? NSNumber {
            result.verdicts[.permissions] = (permissions.uint16Value & 0o111) != 0
                ? .yes
                : .no(String(format: "0%o", permissions.uint16Value))
        } else {
            result.verdicts[.permissions] = .no("probe missing")
        }

        // ③ xattr:探针文件的自定义 xattr 回来没(getxattr)。
        let xattrProbe = extractedRoot.appendingPathComponent(Self.xattrProbeName)
        let xattrSize = getxattr(xattrProbe.path, Self.xattrName, nil, 0, 0, 0)
        result.verdicts[.xattr] = xattrSize > 0 ? .yes : .no("xattr dropped")

        // ④ 符号链接:lab-link 仍是链接且指向探针。
        let linkProbe = extractedRoot.appendingPathComponent(Self.symlinkProbeName)
        if let destination = try? fm.destinationOfSymbolicLink(atPath: linkProbe.path) {
            result.verdicts[.symlink] = destination == Self.xattrProbeName ? .yes : .no("→ \(destination)")
        } else {
            result.verdicts[.symlink] = .no("not a symlink")
        }

        // ⑤ 时间戳:探针 mtime 容差 2s。
        let stageProbe = stage.appendingPathComponent(Self.xattrProbeName)
        if let original = (try? stageProbe.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           let extracted = (try? xattrProbe.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            result.verdicts[.timestamps] = abs(original.timeIntervalSince(extracted)) <= 2
                ? .yes
                : .no(String(format: "Δ%.0fs", abs(original.timeIntervalSince(extracted))))
        } else {
            result.verdicts[.timestamps] = .no("probe missing")
        }

        // ⑥ 注释往返:能力表说支持才测(目前仅 zip 的 EOCD 原生改写)。
        if format == .zip {
            do {
                try ZipArchiveComment.writeComment("format-lab", to: archiveURL)
                _ = try await ArchiveService.list(archiveURL)   // list 旁路缓存头部注释
                result.verdicts[.comment] = ArchiveService.headerComment(for: archiveURL) == "format-lab"
                    ? .yes
                    : .no("round-trip mismatch")
            } catch {
                result.verdicts[.comment] = .no(error.localizedDescription)
            }
        } else {
            result.verdicts[.comment] = .notApplicable
        }

        // ⑦ 可复现:zip/7z 才有时间戳钳制参数;创建两次比 sha256。
        if format == .zip || format == .sevenZip {
            var reproducibleOptions = options
            reproducibleOptions.reproducibleArchive = true
            let first = workspace.appendingPathComponent("repro-1.\(format.pathExtension)")
            let second = workspace.appendingPathComponent("repro-2.\(format.pathExtension)")
            do {
                try await ArchiveService.createArchive(from: [stage], destination: first, options: reproducibleOptions)
                try await ArchiveService.createArchive(from: [stage], destination: second, options: reproducibleOptions)
                let firstHash = try await Task.detached(priority: .userInitiated) { try HashService.sha256(for: first) }.value
                let secondHash = try await Task.detached(priority: .userInitiated) { try HashService.sha256(for: second) }.value
                result.verdicts[.reproducible] = firstHash == secondHash ? .yes : .no("hashes differ")
            } catch {
                result.verdicts[.reproducible] = .no(error.localizedDescription)
            }
        } else {
            result.verdicts[.reproducible] = .notApplicable
        }

        return result
    }

    // MARK: - staging

    static let xattrProbeName = "lab-xattr-probe.txt"
    static let symlinkProbeName = "lab-symlink"
    static let executableProbeName = "lab-executable.sh"
    static let xattrName = "com.simplezip.formatlab"

    /// 把用户样本复制进临时区并加探针。返回 staged 根。
    private static func makeStagedSample(from sampleFolder: URL, in temp: URL) throws -> URL {
        let fm = FileManager.default
        let stage = temp.appendingPathComponent("sample", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        try fm.copyItem(at: sampleFolder, to: stage)
        // xattr 探针
        let xattrProbe = stage.appendingPathComponent(xattrProbeName)
        try Data("format lab xattr probe\n".utf8).write(to: xattrProbe)
        let payload = "probe-value"
        _ = payload.withCString { pointer in
            setxattr(xattrProbe.path, xattrName, pointer, strlen(pointer), 0, 0)
        }
        // 符号链接探针(指向 stage 内文件 —— 包内相对链接)
        try fm.createSymbolicLink(
            atPath: stage.appendingPathComponent(symlinkProbeName).path,
            withDestinationPath: xattrProbeName
        )
        // 可执行位探针
        let executable = stage.appendingPathComponent(executableProbeName)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: executable.path)
        return stage
    }
}

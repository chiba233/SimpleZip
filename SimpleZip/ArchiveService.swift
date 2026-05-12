//
//  ArchiveService.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation
import UniformTypeIdentifiers

/// 归档命令服务：封装 zip/unzip/7zz 调用，让界面层不直接接触命令行细节。
enum ArchiveService {
    static let supportedExtensions = ["zip", "7z", "tar", "gz", "tgz", "bz2", "xz"]
    static let supportedArchiveTypes: [UTType] = supportedExtensions.compactMap { UTType(filenameExtension: $0) }

    static func isSupportedArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    static func createZipArchive(from sourceURLs: [URL], destination: URL) async throws {
        guard let first = sourceURLs.first else { return }
        let parent = first.deletingLastPathComponent()
        let relativeNames = sourceURLs.map { $0.lastPathComponent }
        var arguments = ["-r", "-q", destination.path]
        arguments.append(contentsOf: relativeNames)
        try await run("/usr/bin/zip", arguments: arguments, currentDirectory: parent)
    }

    static func extract(_ archive: URL, to destination: URL) async throws {
        switch archive.pathExtension.lowercased() {
        case "zip":
            try await run("/usr/bin/unzip", arguments: ["-o", archive.path, "-d", destination.path])
        case "7z", "tar", "gz", "tgz", "bz2", "xz":
            let tool = try sevenZipTool()
            try await run(tool, arguments: ["x", archive.path, "-o\(destination.path)", "-y"])
        default:
            throw ArchiveError.unsupportedFormat
        }
    }

    static func test(_ archive: URL) async throws {
        switch archive.pathExtension.lowercased() {
        case "zip":
            try await run("/usr/bin/unzip", arguments: ["-t", archive.path])
        case "7z", "tar", "gz", "tgz", "bz2", "xz":
            let tool = try sevenZipTool()
            try await run(tool, arguments: ["t", archive.path])
        default:
            throw ArchiveError.unsupportedFormat
        }
    }

    static func list(_ archive: URL) async throws -> [ArchiveItem] {
        switch archive.pathExtension.lowercased() {
        case "zip":
            let output = try await runAndCapture("/usr/bin/unzip", arguments: ["-l", archive.path])
            return parseUnzipList(output)
        case "7z", "tar", "gz", "tgz", "bz2", "xz":
            let tool = try sevenZipTool()
            let output = try await runAndCapture(tool, arguments: ["l", "-slt", archive.path])
            return parseSevenZipList(output)
        default:
            throw ArchiveError.unsupportedFormat
        }
    }

    /// 查找常见 Homebrew 路径下的 7zz/7z，可覆盖 Apple Silicon 和 Intel Mac。
    private static func sevenZipTool() throws -> String {
        let candidates = ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz", "/opt/homebrew/bin/7z", "/usr/local/bin/7z"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        throw ArchiveError.missingSevenZip
    }

    private static func run(_ executable: String, arguments: [String], currentDirectory: URL? = nil) async throws {
        _ = try await runAndCapture(executable, arguments: arguments, currentDirectory: currentDirectory)
    }

    /// 在后台线程运行命令，避免压缩/解压时阻塞主界面。
    private static func runAndCapture(_ executable: String, arguments: [String], currentDirectory: URL? = nil) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw ArchiveError.commandFailed(error.isEmpty ? output : error)
            }

            return output
        }.value
    }

    /// 解析 macOS 自带 unzip -l 的列表输出。
    private static func parseUnzipList(_ output: String) -> [ArchiveItem] {
        output
            .split(separator: "\n")
            .compactMap { line -> ArchiveItem? in
                let text = String(line)
                guard text.range(of: #"^\s*\d+\s+\d{2}-\d{2}-\d{4}\s+\d{2}:\d{2}\s+.+$"#, options: .regularExpression) != nil else {
                    return nil
                }

                let parts = text.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count == 4 else { return nil }

                return ArchiveItem(
                    name: String(parts[3]),
                    sizeText: ByteCountFormatter.string(fromByteCount: Int64(parts[0]) ?? 0, countStyle: .file),
                    modifiedText: "\(parts[1]) \(parts[2])",
                    method: "Deflate"
                )
            }
    }

    /// 解析 7zz -slt 的 key/value 输出，兼容 7z/tar/gz 等格式。
    private static func parseSevenZipList(_ output: String) -> [ArchiveItem] {
        var rows: [ArchiveItem] = []
        var values: [String: String] = [:]

        func flush() {
            guard let path = values["Path"], path != "." else {
                values.removeAll()
                return
            }

            let size = Int64(values["Size"] ?? "") ?? 0
            rows.append(
                ArchiveItem(
                    name: path,
                    sizeText: ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                    modifiedText: values["Modified"] ?? "",
                    method: values["Method"] ?? ""
                )
            )
            values.removeAll()
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.isEmpty {
                flush()
                continue
            }

            let parts = text.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                values[parts[0]] = parts[1]
            }
        }

        flush()
        return rows
    }
}

//
//  ArchiveSpaceAnalysis.swift
//  SimpleZip
//
//  队列 #8:归档空间分析 —— 对已列出的条目算「哪里占地方」:Top N 大文件 / 按顶层目录 /
//  按扩展名 / 垃圾占用 / 压缩率 / 加密条目占比。纯函数、确定性排序,SwiftPM 可测;
//  展示侧(报告 sheet)另行接入。
//

import Foundation

struct ArchiveSpaceAnalysis: Equatable {
    struct Entry: Equatable {
        let name: String
        let bytes: Int64
    }

    /// Top N 大文件(按原始大小降序;同大小按名稳定)。
    let largestFiles: [Entry]
    /// 顶层目录占用(目录树第一层聚合;顶层散文件归入 ""(根)),按字节降序。
    let topLevelDirectories: [Entry]
    /// 扩展名占用(小写;无扩展名归入 "");按字节降序,最多 12 项。
    let extensions: [Entry]
    /// 元数据垃圾(.DS_Store / __MACOSX / ._* / Thumbs.db / desktop.ini)的条目数与字节。
    let junkCount: Int
    let junkBytes: Int64
    /// 原始 / 压缩后总字节(后端没报的按 0 计 —— 是下限)。
    let totalBytes: Int64
    let packedBytes: Int64
    /// 加密条目数与其原始字节。
    let encryptedCount: Int
    let encryptedBytes: Int64
    let fileCount: Int

    /// 压缩率(packed/total,0~1);任一为 0 → nil(没数据,不显示假比率)。
    var compressionRatio: Double? {
        guard totalBytes > 0, packedBytes > 0 else { return nil }
        return Double(packedBytes) / Double(totalBytes)
    }

    nonisolated static func analyze(_ items: [ArchiveItem], topFileLimit: Int = 10) -> ArchiveSpaceAnalysis {
        let signpost = PerfSignpost.begin("archive.spaceAnalysis")
        defer { PerfSignpost.end("archive.spaceAnalysis", signpost) }
        var files: [(name: String, bytes: Int64)] = []
        var directoryBytes: [String: Int64] = [:]
        var extensionBytes: [String: Int64] = [:]
        var junkCount = 0
        var junkBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var packedBytes: Int64 = 0
        var encryptedCount = 0
        var encryptedBytes: Int64 = 0

        for item in items where !item.isDirectory {
            let bytes = item.size ?? 0
            totalBytes += bytes
            packedBytes += item.packedSize ?? 0
            if ArchiveJunkFiles.isJunkPath(item.name) {
                junkCount += 1
                junkBytes += bytes
                continue
            }
            if item.isEncrypted {
                encryptedCount += 1
                encryptedBytes += bytes
            }
            let path = normalized(item.name)
            files.append((path, bytes))
            let top = path.contains("/") ? String(path.split(separator: "/", maxSplits: 1)[0]) : ""
            directoryBytes[top, default: 0] += bytes
            let ext = (path as NSString).pathExtension.lowercased()
            extensionBytes[ext, default: 0] += bytes
        }

        let largest = files
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
            .prefix(topFileLimit)
            .map { Entry(name: $0.name, bytes: $0.bytes) }
        let directories = directoryBytes
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { Entry(name: $0.key, bytes: $0.value) }
        let extensions = extensionBytes
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(12)
            .map { Entry(name: $0.key, bytes: $0.value) }

        return ArchiveSpaceAnalysis(
            largestFiles: Array(largest),
            topLevelDirectories: directories,
            extensions: Array(extensions),
            junkCount: junkCount,
            junkBytes: junkBytes,
            totalBytes: totalBytes,
            packedBytes: packedBytes,
            encryptedCount: encryptedCount,
            encryptedBytes: encryptedBytes,
            fileCount: files.count + junkCount
        )
    }

    private nonisolated static func normalized(_ raw: String) -> String {
        var path = raw.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

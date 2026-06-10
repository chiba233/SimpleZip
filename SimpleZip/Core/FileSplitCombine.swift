//
//  FileSplitCombine.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  「拆分文件 / 合并分卷」—— 对齐官方 7-Zip GUI 的 Split / Combine 语义：**纯字节级**切分与拼接，
//  不经过任何压缩后端。`file.7z` 拆出的 `file.7z.001/002…` 跟 7-Zip / cat 拼回的结果逐字节一致，
//  与其它工具的分卷集互通。纯 Foundation 实现，放 Core 由 SwiftPM 单测覆盖。
//
//  数据安全：
//  - 拆分目标分片任何一个已存在 → 整个操作开始前就抛错，绝不覆盖；失败/取消时清掉已写出的半成品。
//  - 合并输出名 = 去掉 `.001` 的原名；已存在时用 UniqueFileName 起「名 2」，不覆盖。
//

import Foundation

enum FileSplitCombineError: LocalizedError, Equatable {
    case invalidVolumeSize
    case partAlreadyExists(String)
    case notFirstVolume

    var errorDescription: String? {
        switch self {
        case .invalidVolumeSize:
            return L10n.text("error.split.invalidVolumeSize")
        case .partAlreadyExists(let name):
            return L10n.format("error.split.partExists", name)
        case .notFirstVolume:
            return L10n.text("error.combine.notFirstVolume")
        }
    }
}

enum FileSplitCombine {

    /// 分片序号格式：001…999 后自然长到 1000（与 7-Zip 一致）。
    nonisolated private static func partName(base: String, index: Int) -> String {
        String(format: "%@.%03d", base, index)
    }

    /// `xxx.001` 才算分卷集首卷（合并入口只对它开放）。
    nonisolated static func isFirstVolume(_ url: URL) -> Bool {
        url.pathExtension == "001"
    }

    /// 从首卷开始枚举**连续**存在的分片（001、002…遇缺即停）。遇缺即停是有意的：
    /// 缺中段的集合拼出来必然是坏文件，宁可只认连续前缀让用户察觉。
    nonisolated static func volumeParts(for firstVolume: URL, fileManager: FileManager = .default) -> [URL] {
        guard isFirstVolume(firstVolume) else { return [] }
        let base = firstVolume.deletingPathExtension().lastPathComponent
        let directory = firstVolume.deletingLastPathComponent()
        var parts: [URL] = []
        var index = 1
        while true {
            let part = directory.appendingPathComponent(partName(base: base, index: index))
            guard fileManager.fileExists(atPath: part.path) else { break }
            parts.append(part)
            index += 1
        }
        return parts
    }

    /// 拆分：把 `source` 按 `volumeSize` 字节切成 `<原名>.001/002…`（同目录）。
    /// 返回写出的分片列表。可在 Task 内取消（块间检查），失败 / 取消时删除已写出的分片。
    @discardableResult
    nonisolated static func split(
        _ source: URL,
        volumeSize: Int64,
        fileManager: FileManager = .default,
        progress: @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) throws -> [URL] {
        guard volumeSize > 0 else { throw FileSplitCombineError.invalidVolumeSize }

        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        let totalSize = (attributes[.size] as? Int64) ?? 0
        let directory = source.deletingLastPathComponent()
        let base = source.lastPathComponent
        // 空文件也产出一个空 .001 —— 「拆了但什么都没有」比静默不动手更难解释。
        let partCount = max(1, Int((totalSize + volumeSize - 1) / volumeSize))

        // 开工前整组预检：任何一个目标分片已存在就拒绝，避免写到一半才撞名。
        let targets = (1...partCount).map { directory.appendingPathComponent(partName(base: base, index: $0)) }
        if let occupied = targets.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            throw FileSplitCombineError.partAlreadyExists(occupied.lastPathComponent)
        }

        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }

        var written: Int64 = 0
        var createdParts: [URL] = []
        do {
            for target in targets {
                try Task.checkCancellation()
                fileManager.createFile(atPath: target.path, contents: nil)
                createdParts.append(target)
                let writer = try FileHandle(forWritingTo: target)
                defer { try? writer.close() }

                var remainingInPart = volumeSize
                while remainingInPart > 0 {
                    try Task.checkCancellation()
                    let chunkLength = Int(min(remainingInPart, Self.chunkSize))
                    guard let chunk = try reader.read(upToCount: chunkLength), !chunk.isEmpty else { break }
                    try writer.write(contentsOf: chunk)
                    remainingInPart -= Int64(chunk.count)
                    written += Int64(chunk.count)
                    progress(written, totalSize)
                }
            }
        } catch {
            // 半成品不留：拆一半的分卷集既占空间又会误导下次拆分（撞名拒绝）。
            createdParts.forEach { try? fileManager.removeItem(at: $0) }
            throw error
        }
        progress(totalSize, totalSize)
        return createdParts
    }

    /// 合并：从 `firstVolume`（必须 `.001`）开始按序拼接所有连续分片，输出到同目录下去掉
    /// `.001` 的原名（已存在则自动「名 2」）。返回输出 URL。失败 / 取消时删除半成品输出。
    @discardableResult
    nonisolated static func combine(
        firstVolume: URL,
        fileManager: FileManager = .default,
        progress: @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) throws -> URL {
        guard isFirstVolume(firstVolume) else { throw FileSplitCombineError.notFirstVolume }
        let parts = volumeParts(for: firstVolume, fileManager: fileManager)
        guard !parts.isEmpty else { throw FileSplitCombineError.notFirstVolume }

        let totalSize = parts.reduce(Int64(0)) { sum, part in
            sum + (((try? fileManager.attributesOfItem(atPath: part.path))?[.size] as? Int64) ?? 0)
        }

        let preferredName = firstVolume.deletingPathExtension().lastPathComponent
        let output = UniqueFileName.numbered(
            in: firstVolume.deletingLastPathComponent(),
            preferredName: preferredName,
            exists: { fileManager.fileExists(atPath: $0.path) }
        )

        fileManager.createFile(atPath: output.path, contents: nil)
        do {
            let writer = try FileHandle(forWritingTo: output)
            defer { try? writer.close() }
            var written: Int64 = 0
            for part in parts {
                try Task.checkCancellation()
                let reader = try FileHandle(forReadingFrom: part)
                defer { try? reader.close() }
                while true {
                    try Task.checkCancellation()
                    guard let chunk = try reader.read(upToCount: Int(Self.chunkSize)), !chunk.isEmpty else { break }
                    try writer.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                    progress(written, totalSize)
                }
            }
        } catch {
            try? fileManager.removeItem(at: output)
            throw error
        }
        progress(totalSize, totalSize)
        return output
    }

    /// 流式块大小。4 MiB：足够摊薄系统调用，又不会让取消检查迟钝。
    nonisolated private static let chunkSize: Int64 = 4 * 1024 * 1024
}

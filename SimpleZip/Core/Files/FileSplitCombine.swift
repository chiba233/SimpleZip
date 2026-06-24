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

    // MARK: - 分卷集识别（0.4.2）

    /// 防御荒谬卷号（如把 `backup.2024` 误判成第 2024 卷）：超过此上限不做缺卷枚举。
    nonisolated private static let maxReasonableVolumeIndex = 5000

    /// 从任意一个成员的**文件名**出发，在同目录文件名集合里识别整个分卷家族。
    /// 纯名字逻辑（可单测）；大小 / 存在性等文件系统事实由调用方自取。
    ///
    /// 识别两种家族：
    /// - 数字尾缀 `name.001 / name.002 …`（7-Zip Split、本 app 自产；009 → 010、999 → 1000 自然增长）
    /// - `name.part1.rar / name.part2.rar`（RAR 现代分卷）
    ///
    /// 防误判：孤立的 `report.2024` 这类「碰巧全数字扩展名」**不算**分卷 ——
    /// 只有成员卷号为 1，或同目录还有同家族其它卷时才认。
    nonisolated static func volumeSet(forMemberNamed memberName: String, among siblingNames: [String]) -> SplitVolumeSet? {
        if let set = numericVolumeSet(memberName: memberName, siblingNames: siblingNames) { return set }
        return partRarVolumeSet(memberName: memberName, siblingNames: siblingNames)
    }

    /// 一次性算出 `siblingNames` 里**每个分卷成员名 → 它的 SplitVolumeSet**(非成员名不在 map 里 = nil)。
    /// 结果与对每个名字单独调 `volumeSet(forMemberNamed:among:)` **完全一致**,但整体 O(n) 而非 O(n²) ——
    /// 先一遍按 (类型, base) 把成员聚类,再逐名产出。文件表折叠 / 布局形状检查是渲染热路径,大目录 / 多分卷时
    /// 逐名扫全 sibling 会平方放大,故提供本批量入口。
    nonisolated static func volumeSets(among siblingNames: [String]) -> [String: SplitVolumeSet] {
        // 与逐个版本同优先级:先数字尾缀,再 .partN.rar(两者对同一名字互斥)。按 sibling 顺序入桶,
        // 保证成员顺序与逐个版本一致(makeSet 依赖顺序)。
        var numericFamilies: [String: [(index: Int, name: String)]] = [:]
        var partRarFamilies: [String: [(index: Int, name: String)]] = [:]
        for name in siblingNames {
            if let (base, index) = splitNumericSuffix(name) {
                numericFamilies[base, default: []].append((index, name))
            } else if let (base, index) = splitPartRar(name) {
                partRarFamilies[base, default: []].append((index, name))
            }
        }
        var result: [String: SplitVolumeSet] = [:]
        for name in siblingNames {
            if let (base, memberIndex) = splitNumericSuffix(name) {
                let members = numericFamilies[base] ?? []
                guard memberIndex == 1 || members.count >= 2 else { continue }
                result[name] = makeSet(baseName: base, memberIndex: memberIndex, members: members)
            } else if let (base, memberIndex) = splitPartRar(name) {
                let members = partRarFamilies[base] ?? []
                guard memberIndex == 1 || members.count >= 2 else { continue }
                result[name] = makeSet(baseName: base + ".rar", memberIndex: memberIndex, members: members)
            }
        }
        return result
    }

    nonisolated private static func numericVolumeSet(memberName: String, siblingNames: [String]) -> SplitVolumeSet? {
        guard let (base, memberIndex) = splitNumericSuffix(memberName) else { return nil }
        var members: [(index: Int, name: String)] = []
        for name in siblingNames {
            guard let (candidateBase, index) = splitNumericSuffix(name), candidateBase == base else { continue }
            members.append((index, name))
        }
        guard memberIndex == 1 || members.count >= 2 else { return nil }
        return makeSet(baseName: base, memberIndex: memberIndex, members: members)
    }

    /// `name.001` → ("name", 1)。扩展名必须 ≥3 位纯数字（7-Zip 卷号格式，999 后是 1000）。
    nonisolated private static func splitNumericSuffix(_ name: String) -> (base: String, index: Int)? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let suffix = name[name.index(after: dot)...]
        guard suffix.count >= 3, !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let index = Int(suffix) else { return nil }
        return (String(name[..<dot]), index)
    }

    nonisolated private static func partRarVolumeSet(memberName: String, siblingNames: [String]) -> SplitVolumeSet? {
        guard let (base, memberIndex) = splitPartRar(memberName) else { return nil }
        var members: [(index: Int, name: String)] = []
        for name in siblingNames {
            guard let (candidateBase, index) = splitPartRar(name), candidateBase == base else { continue }
            members.append((index, name))
        }
        guard memberIndex == 1 || members.count >= 2 else { return nil }
        return makeSet(baseName: base + ".rar", memberIndex: memberIndex, members: members)
    }

    /// `name.part2.rar` → ("name", 2)（大小写不敏感）。
    nonisolated private static func splitPartRar(_ name: String) -> (base: String, index: Int)? {
        let lower = name.lowercased()
        guard lower.hasSuffix(".rar") else { return nil }
        let withoutRar = String(name.dropLast(4))
        guard let partRange = withoutRar.range(of: #"\.[pP][aA][rR][tT]\d+$"#, options: .regularExpression) else { return nil }
        let digits = withoutRar[partRange].dropFirst(5)   // ".part" 后的数字
        guard let index = Int(digits) else { return nil }
        return (String(withoutRar[..<partRange.lowerBound]), index)
    }

    nonisolated private static func makeSet(baseName: String, memberIndex: Int, members: [(index: Int, name: String)]) -> SplitVolumeSet {
        var byIndex: [Int: String] = [:]
        for member in members { byIndex[member.index] = member.name }
        let presentIndices = byIndex.keys.sorted()
        let highest = presentIndices.last ?? 0
        // 缺卷 = 1...最大现存卷号之间的空洞。荒谬大的卷号（误判保护）不枚举。
        let missing: [Int]
        if highest <= maxReasonableVolumeIndex {
            missing = (1...max(highest, 1)).filter { byIndex[$0] == nil }
        } else {
            missing = []
        }
        return SplitVolumeSet(
            baseName: baseName,
            memberIndex: memberIndex,
            presentIndices: presentIndices,
            presentNames: presentIndices.compactMap { byIndex[$0] },
            missingIndices: missing
        )
    }
}

/// 分卷集识别结果（0.4.2）。`presentNames` 与 `presentIndices` 一一对应（升序）。
struct SplitVolumeSet: Equatable {
    let baseName: String        // 合并产物名（`a.7z` / `a.rar`）
    let memberIndex: Int        // 被查询成员的卷号
    let presentIndices: [Int]
    let presentNames: [String]
    let missingIndices: [Int]   // 1...最大现存卷号 之间缺失的卷号

    var volumeCount: Int { presentIndices.count }
    var highestIndex: Int { presentIndices.last ?? 0 }
    var isComplete: Bool { missingIndices.isEmpty }
}

// MARK: - 缺分卷搜索辅助(队列 #15)

extension FileSplitCombine {

    /// 这组卷在缺卷号 `index` 上**期望**的文件名(给「仍未找齐」的命名模式提示)。
    /// 数字卷:`base.001` 式;part-rar 卷:`base.part<N>.rar`(不补零 —— WinRAR 两种都产,
    /// 搜索按解析匹配不靠这个名,提示用最常见形)。
    nonisolated static func expectedVolumeName(for set: SplitVolumeSet, index: Int) -> String {
        if set.baseName.lowercased().hasSuffix(".rar"),
           set.presentNames.first?.lowercased().contains(".part") == true {
            let stem = String(set.baseName.dropLast(4))
            return "\(stem).part\(index).rar"
        }
        return String(format: "%@.%03d", set.baseName, index)
    }

    /// #15:在另选目录(递归,跳过隐藏与包内部)搜属于同一组的**缺失卷**。
    /// 匹配按命名解析(`splitNumericSuffix` / `splitPartRar`),数字宽度 / part 是否补零都兼容;
    /// 同一卷号撞到多个候选时取第一个(确定性:enumerator 顺序)。返回 缺卷号 → 找到的 URL。
    nonisolated static func searchForMissingVolumes(
        of set: SplitVolumeSet,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [Int: URL] {
        guard !set.missingIndices.isEmpty else { return [:] }
        let wanted = Set(set.missingIndices)
        var found: [Int: URL] = [:]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [:] }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let name = url.lastPathComponent
            let parsedBase: String
            let parsedIndex: Int
            if let (base, index) = splitNumericSuffix(name) {
                parsedBase = base
                parsedIndex = index
            } else if let (base, index) = splitPartRar(name) {
                parsedBase = base + ".rar"
                parsedIndex = index
            } else {
                continue
            }
            guard parsedBase == set.baseName, wanted.contains(parsedIndex), found[parsedIndex] == nil else { continue }
            found[parsedIndex] = url
            if found.count == wanted.count { break }
        }
        return found
    }
}

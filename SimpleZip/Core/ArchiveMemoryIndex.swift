//
//  ArchiveMemoryIndex.swift
//  SimpleZip
//
//  0.4.5 #80:归档记忆索引(路线图建议九 / 建议二十)。从**非加密**清单缓存(ArchiveListingCacheEntry)
//  派生更适合 AI / 搜索的记录:结构摘要、画像、样本路径、最大文件、位置上下文。供归档查找、AI 工作区、
//  动态按钮复用,不替代 ArchiveListingCacheStore。
//
//  **隐私**:数据源(清单缓存)本就**只存非加密条目名**、加密条目只留计数;本层在其上派生,绝不引入新的
//  敏感面。AI 面向记录**不含完整磁盘路径** —— 只用稳定 archiveID(hash)+ 文件名 + 位置类别 / 目录名 token
//  (完整路径属当次上下文,不进长期学习)。纯函数,SwiftPM 可断言。
//

import Foundation

nonisolated struct ArchiveMemoryRecord: Codable, Equatable, Identifiable, Sendable {
    struct EntryStats: Codable, Equatable, Sendable {
        let totalEntries: Int
        let visibleEntries: Int
        let encryptedEntriesOmitted: Int
        let truncated: Bool
    }

    struct FileSample: Codable, Equatable, Sendable {
        let name: String
        let bytes: Int64?
    }

    /// 稳定 id(archivePath 的 FNV 哈希,`arch-xxxxxxxx`)。AI 引用它,App 回查映射到真实缓存条目。
    let archiveID: String
    /// 归档文件名(非敏感 basename,可给 AI);**不含完整路径**。
    let archiveName: String
    let archiveExtension: String
    /// 归档所在**目录**的低敏位置上下文(类别 + 哈希 + 目录名 token)。
    let location: AILocationContext
    let recordedAt: Date
    let archiveByteSize: Int64?
    let entryStats: EntryStats
    /// 复用确定性画像(结构 / 语义标签 / marker / 扩展分布 / 风险 hints)。
    let profile: ArchiveProfile
    /// 非加密条目样本路径(供命中展示)。
    let samplePaths: [String]
    /// 最大文件样本(size 降序)。
    let largestFiles: [FileSample]
    let omissions: [AIContextOmission]

    var id: String { archiveID }
}

nonisolated enum ArchiveMemoryIndex {
    /// 批量派生(整份缓存 → 记忆记录集)。
    static func derive(from cacheEntries: [ArchiveListingCacheEntry],
                       home: String = NSHomeDirectory(),
                       budget: AIBudget = .archiveMemory) -> [ArchiveMemoryRecord] {
        cacheEntries.map { derive(from: $0, home: home, budget: budget) }
    }

    /// 单条派生。缓存条目里的 `entries` 全是非加密条目(缓存层已过滤),加密只剩计数。
    static func derive(from entry: ArchiveListingCacheEntry,
                       home: String = NSHomeDirectory(),
                       budget: AIBudget = .archiveMemory) -> ArchiveMemoryRecord {
        // 缓存条目 → ArchiveItem(全部非加密),交给画像器。
        // 注(审计 #14):缓存只存 name/isDirectory/size,没有 attributes / symlinkTarget,所以画像的
        // contains-symlink / contains-executable 风险 hint 对缓存派生记录天然不会触发(只有 .app 路径痕迹
        // 驱动的 contains-app-bundle 仍有效)—— 这是缓存粒度的固有限制,非缺陷。
        let items = entry.entries.map {
            ArchiveItem(name: $0.name, isDirectory: $0.isDirectory, size: $0.size, modified: nil,
                        sizeText: "", modifiedText: "", method: "", isEncrypted: false)
        }
        let profile = ArchiveProfile.derive(from: items, budget: budget)

        let directory = (entry.archivePath as NSString).deletingLastPathComponent
        let location = AILocationClassifier.classify(directoryPath: directory, home: home)

        // 最大文件样本(非目录,size 降序、name 升序;nil size 最后)。
        let largest = entry.entries
            .filter { !$0.isDirectory }
            .sorted { lhs, rhs in
                switch (lhs.size, rhs.size) {
                case let (l?, r?): return l != r ? l > r : lhs.name < rhs.name
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.name < rhs.name
                }
            }
            .prefix(budget.maxSamplesPerGroup)
            .map { ArchiveMemoryRecord.FileSample(
                name: AISensitiveRedactor.redactFileNameSecrets(($0.name as NSString).lastPathComponent),
                bytes: $0.size) }

        var omissions: [AIContextOmission] = []
        if entry.encryptedEntryCount > 0 {
            omissions.append(.encryptedEntryNames(count: entry.encryptedEntryCount))
        }
        if entry.truncated {
            // 审计 #15:缓存只知道「被截断」、不知道省了多少 → count 用 nil,不谎报 omitted:0。
            omissions.append(AIContextOmission(type: "archive_entries", count: nil, policy: "per_archive_cap"))
        }

        return ArchiveMemoryRecord(
            archiveID: archiveID(forPath: entry.archivePath),
            archiveName: AISensitiveRedactor.redactFileNameSecrets(entry.archiveName),
            archiveExtension: (entry.archiveName as NSString).pathExtension.lowercased(),
            location: location,
            recordedAt: entry.recordedAt,
            archiveByteSize: entry.archiveByteSize,
            entryStats: ArchiveMemoryRecord.EntryStats(
                totalEntries: entry.totalEntryCount,
                visibleEntries: entry.entries.count,
                encryptedEntriesOmitted: entry.encryptedEntryCount,
                truncated: entry.truncated
            ),
            profile: profile,
            samplePaths: entry.filePaths(limit: budget.maxSamplesPerGroup).map(AISensitiveRedactor.redactFileNameSecrets),
            largestFiles: Array(largest),
            omissions: omissions
        )
    }

    /// archivePath(已规范化)→ 稳定 id。确定性、不暴露路径(复用 AIStableHash,A2)。
    static func archiveID(forPath path: String) -> String {
        "arch-" + AIStableHash.fnv1a32Hex(path)
    }
}

//
//  AIBackgroundIndexer.swift
//  SimpleZip
//
//  0.4.5 #80 #89:后台 AI 文件预索引扫描器(白皮书工程补充六)。**security-sensitive。**
//
//  硬约束(全部满足才跑,且实现层层兜底):
//  - **opt-in 门控**:`AIBackgroundIndexStore.folderPreindexEnabled`(AI 主开关 + 活跃度≠off + 子开关 + 有白名单)。
//  - **白名单**:只走 `AIArchivePrefetchScope` 列出的目录。
//  - **只读 + 仅元数据**:只取文件名 / 大小 / mtime / 是否目录;**绝不读内容**(内容门控另在 readability policy)。
//  - **排除**:`AIPrefetchExclusions`(系统 / 密钥 / 缓存 / 开发依赖 / 临时目录)+ 跳过隐藏文件(避开 .ssh/.env)。
//  - **不跟符号链接**(防逃逸白名单 / 环);外置 / 网络卷默认不进(scope 未显式允许)。
//  - **预算化**:每轮 scope 数 + 每 scope 文件 / 目录上限,按活跃度档位;**可取消**;**全程 off-main**(A18)。
//  - 文件名经 `AIFileMemoryRecord.make` 脱敏(疑似密钥名抹除)。
//

import Foundation

@MainActor
final class AIBackgroundIndexer {
    static let shared = AIBackgroundIndexer()

    private var running = false
    private var task: Task<Void, Never>?

    /// 跑一轮预索引(门控未过则直接返回 —— 默认 opt-in 关闭即什么都不做)。完成后通知发现编排者刷新。
    func runIfEnabled() {
        let store = AIBackgroundIndexStore.shared
        guard !running, store.folderPreindexEnabled, let budget = store.budget else { return }
        running = true

        let scopes = Array(store.scopes.prefix(max(1, budget.maxDirectoriesPerRound)))
        let home = NSHomeDirectory()
        let fileBudget = min(budget.maxEntriesPerArchive, 3_000)

        task = Task.detached(priority: .background) {
            var results: [(UUID, [AIFileMemoryRecord])] = []
            for scope in scopes {
                if Task.isCancelled { break }
                let records = AIBackgroundIndexer.scanScope(scope, home: home, fileBudget: fileBudget)
                results.append((scope.id, records))
            }
            await MainActor.run {
                let now = Date()
                for (id, records) in results {
                    store.ingest(records: records, folders: [], scopeID: id, at: now)
                    store.markScanned(id, at: now)
                }
                AIWorkspaceDiscoveryCoordinator.shared.refresh()
                AIBackgroundIndexer.shared.running = false
            }
        }
    }

    func cancel() { task?.cancel(); task = nil; running = false }

    // MARK: - 只读元数据扫描(off-main;纯静态,不碰 UI 状态)

    /// 每 scope 最多访问的目录数(防超大递归目录把一轮拖垮 —— 白皮书禁「超出预算的大型递归目录」)。
    private static let maxDirectoriesPerScope = 600

    /// 走一个白名单 scope,深度受限、排除敏感、只取元数据、不跟符号链接。返回脱敏后的文件记录。
    nonisolated static func scanScope(_ scope: AIArchivePrefetchScope, home: String,
                                      fileBudget: Int) -> [AIFileMemoryRecord] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var records: [AIFileMemoryRecord] = []
        var visitedDirs = 0
        var queue: [(url: URL, depth: Int)] = [(URL(fileURLWithPath: scope.directoryPath), 0)]

        while !queue.isEmpty, records.count < fileBudget, visitedDirs < maxDirectoriesPerScope {
            let (dir, depth) = queue.removeFirst()
            // 目录级排除(系统 / 密钥 / 缓存 / 开发依赖 / 临时)。
            if AIPrefetchExclusions.shouldExclude(directoryPath: dir.path, home: home) { continue }
            // 外置 / 网络卷默认不进(scope 未显式允许)。
            if !scope.includeExternalVolumes, dir.path.hasPrefix("/Volumes/") { continue }
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            visitedDirs += 1

            let loc = AILocationClassifier.classify(directoryPath: dir.path, home: home)
            for entry in entries {
                if records.count >= fileBudget { break }
                let vals = try? entry.resourceValues(forKeys: Set(keys))
                if vals?.isSymbolicLink == true { continue }   // 不跟符号链接(防逃逸 / 环)
                if !scope.includeExternalVolumes, entry.path.hasPrefix("/Volumes/") { continue }
                if vals?.isDirectory == true {
                    if AIPrefetchExclusions.shouldExclude(directoryName: entry.lastPathComponent) { continue }
                    if scope.recursive, depth + 1 < scope.maxDepth { queue.append((entry, depth + 1)) }
                } else {
                    records.append(AIFileMemoryRecord.make(
                        fileName: entry.lastPathComponent, isDirectory: false,
                        byteSize: vals?.fileSize.map(Int64.init), modifiedAt: vals?.contentModificationDate,
                        location: loc))
                }
            }
        }
        return records
    }
}

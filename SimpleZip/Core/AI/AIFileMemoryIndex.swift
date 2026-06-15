//
//  AIFileMemoryIndex.swift
//  SimpleZip
//
//  0.4.5 #80 #89:白名单目录的**持久文件预索引容器**(白皮书工程补充五 4803 / 工程补充六)。
//
//  后台 AI 预索引文件夹时,把普通文件记录(`AIFileMemoryRecord`,轻量、无完整路径)、文件夹画像
//  (`AIFolderProfile`)按白名单 scope 汇进这里;AI 文件夹的后台发现从它读跨位置文件候选。**只存派生元数据**
//  (脱敏文件名 / 类型 / 角色 / marker / 安全文本摘要 / 位置哈希),**绝不存绝对路径 / 口令 / 密钥 / 加密内容**。
//
//  本类只是**确定性容器**(upsert / 去重 / 封顶 / 按 scope 或全量清空 / 取发现候选),不读文件系统 —— 真实扫描
//  由 App 侧 opt-in 白名单扫描器填入(security-sensitive,另建)。纯 Codable 值类型,SwiftPM 可断言。
//

import Foundation

nonisolated struct AIFileMemoryIndex: Codable, Equatable, Sendable {
    /// 一条文件记录 + 它来自哪个白名单 scope + 索引时间(供按 scope 清空 / 封顶淘汰最旧)。
    nonisolated struct FileEntry: Codable, Equatable, Sendable {
        let record: AIFileMemoryRecord
        let scopeID: UUID?
        let indexedAt: Date

        init(record: AIFileMemoryRecord, scopeID: UUID?, indexedAt: Date) {
            self.record = record
            self.scopeID = scopeID
            self.indexedAt = indexedAt
        }
    }

    private(set) var files: [FileEntry]
    private(set) var folders: [AIFolderProfile]
    /// 文件记录总量上限(超出淘汰最旧 indexedAt)。
    let maxFiles: Int

    init(files: [FileEntry] = [], folders: [AIFolderProfile] = [], maxFiles: Int = 5_000) {
        self.files = files
        self.folders = folders
        self.maxFiles = max(1, maxFiles)
    }

    // MARK: - 写入(不可变变换)

    /// upsert 一批文件记录(按 `record.id` 去重 —— 同路径同名稳定 id)。封顶按 `indexedAt` 淘汰最旧。
    func upserting(_ records: [AIFileMemoryRecord], scopeID: UUID?, at date: Date) -> AIFileMemoryIndex {
        var byID = Dictionary(files.map { ($0.record.id, $0) }, uniquingKeysWith: { _, b in b })
        for r in records { byID[r.id] = FileEntry(record: r, scopeID: scopeID, indexedAt: date) }
        // 稳定排序:索引时间新→旧,同时按 id 兜底(确定性)。
        var merged = Array(byID.values).sorted {
            $0.indexedAt != $1.indexedAt ? $0.indexedAt > $1.indexedAt : $0.record.id < $1.record.id
        }
        if merged.count > maxFiles { merged = Array(merged.prefix(maxFiles)) }
        return AIFileMemoryIndex(files: merged, folders: folders, maxFiles: maxFiles)
    }

    /// upsert 一批文件夹画像(按 `id` 去重)。
    func upsertingFolders(_ profiles: [AIFolderProfile]) -> AIFileMemoryIndex {
        var byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for p in profiles { byID[p.id] = p }
        let merged = byID.values.sorted { $0.id < $1.id }
        return AIFileMemoryIndex(files: files, folders: merged, maxFiles: maxFiles)
    }

    // MARK: - 清空(白皮书 4533:清空后台文件预索引,不删任何真实文件)

    /// 清掉某 scope 的所有记录(用户从白名单移除一个目录时)。文件夹画像同 location 也一并清。
    func clearingScope(_ scopeID: UUID) -> AIFileMemoryIndex {
        let keptFiles = files.filter { $0.scopeID != scopeID }
        // 文件夹画像没带 scopeID,按「是否还有该 scope 外的文件引用其 location」无法判断 → 保守:只清文件,
        // 文件夹画像留待全量清空。(folders 体量小,且不含路径,留存无害。)
        return AIFileMemoryIndex(files: keptFiles, folders: folders, maxFiles: maxFiles)
    }

    /// 全量清空(白皮书 4533)。
    func cleared() -> AIFileMemoryIndex {
        AIFileMemoryIndex(files: [], folders: [], maxFiles: maxFiles)
    }

    // MARK: - 读取

    /// 全部文件记录(供后台发现组装候选)。
    var records: [AIFileMemoryRecord] { files.map(\.record) }

    /// 取最近索引的 N 条文件记录(发现预算用)。
    func recentRecords(limit: Int) -> [AIFileMemoryRecord] {
        Array(files.prefix(max(0, limit)).map(\.record))
    }

    var fileCount: Int { files.count }
    var folderCount: Int { folders.count }
    var isEmpty: Bool { files.isEmpty && folders.isEmpty }
}

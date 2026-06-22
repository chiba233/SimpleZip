//
//  ReleaseLedger.swift
//  SimpleZip
//
//  0.4.4 #2:发布历史(Release Ledger)。发布助手每次**成功**跑完追加一条账面记录 ——
//  哪个产物 / 哪个版本 / SHA-256 / 结构指纹 / 卫生计数 / 步骤耗时,供历史回看与
//  「本次 vs 上次」对比(#3)。失败的运行留在活动中心历史,不进账本。
//  存取走 ReleaseWorkspacePresetStore 同款 UserDefaults JSON 习语,上限 100 条裁旧。
//

import Foundation

nonisolated struct ReleaseLedgerEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    /// 产物完整路径(对比时若文件还在可直接跑文件级 diff)。
    var artifactPath: String
    /// 版本标签(sheet 可填;空则用文件名推导)。
    var versionLabel: String
    /// ArchiveCreateFormat.rawValue(zip / sevenZip)—— 与工作区预设同形态,不给枚举强加 Codable。
    var formatRawValue: String
    var sha256: String?
    var structuralFingerprint: String?
    var reproducible: Bool
    var excludeJunk: Bool
    /// 这次跑有没有开发布检查(关了则下面的检查侧字段全为 nil)。
    var inspectionRan: Bool
    var testPassed: Bool?
    var suspiciousPathCount: Int?
    var junkCount: Int?
    var emptyDirectoryCount: Int?
    var fileCount: Int?
    var totalBytes: Int64?
    var wroteChecksums: Bool
    /// 用户勾了「签名为 .szs」(签名本身是交互式后续步骤,这里只记意图)。
    var signRequested: Bool
    var appVersion: String
    var backendVersion: String?
    /// F3 步骤耗时记录。
    var steps: [ReleaseRunStep]

    /// 产物文件现在还在不在(账面对比不依赖它;文件级对比需要)。
    var artifactExists: Bool {
        FileManager.default.fileExists(atPath: artifactPath)
    }
}

/// 发布账本的 UserDefaults JSON 存取。新条目插最前(越新越靠上),超过上限裁掉最旧的。
nonisolated final class ReleaseLedgerStore {
    static let maxEntries = 100

    private let defaults: KeyValueDataStore
    private let storageKey = AppPreferences.Key.releaseLedger

    init(defaults: KeyValueDataStore = UserDefaults.standard) {
        self.defaults = defaults
    }

    func loadAll() -> [ReleaseLedgerEntry] {
        guard let data = defaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([ReleaseLedgerEntry].self, from: data) else { return [] }
        return entries
    }

    // 重要:每次 append/delete 改动账本后,调用方必须调 `ReleasePackageSpotlightIndexer.reindex()`
    // 把 Spotlight 发布包索引同步成当前账本(超上限裁旧 / 删除条目都要让旧索引项消失)。Core 不便直接
    // 引用 app 层 indexer,故由调用点负责(现有 append 两个调用点已照做;将来加「删除发布记录」UI 时勿忘)。
    func append(_ entry: ReleaseLedgerEntry) {
        var all = loadAll()
        all.insert(entry, at: 0)
        if all.count > Self.maxEntries {
            all.removeLast(all.count - Self.maxEntries)
        }
        persist(all)
    }

    /// 删除一条发布记录。调用方随后必须 `ReleasePackageSpotlightIndexer.reindex()`(见 `append` 上方说明)。
    func delete(id: UUID) {
        persist(loadAll().filter { $0.id != id })
    }

    private func persist(_ all: [ReleaseLedgerEntry]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

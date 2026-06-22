//
//  ArchiveFileEntity.swift
//  SimpleZip
//
//  0.4.4 #72:把缓存归档里的**每个非加密文件**单独暴露成 AppEntity + Spotlight 项 —— 让用户在系统 Spotlight
//  里直接搜到「压缩包内的某个文档」,结果标题=文件名、下方小字「在 XXX 压缩包内」,点开:
//   - 关「Finder 打开时自动解压」→ 打开归档、跳进该文件所在目录、选中并滚动到它(#72 reveal 基建)。
//   - 开「Finder 打开时自动解压」→ 只解压**这一个文件**(不是整包),完成后在 Finder 里显示它。
//
//  **隐私红线**:只来自 #34 缓存里的非加密条目(加密条目从不入缓存);per-file 索引每归档封顶 `perArchiveLimit`
//  条,封顶 OS 索引体积。Spotlight 捐献双门控同 #35(`spotlightIndexingEnabled && archiveListingCacheEnabled`)。
//

import AppKit
import AppIntents
import CoreSpotlight
import Foundation

/// 缓存归档里的一个文件条目。id = `archivePath` + 分隔符 + `entryPath`(都来自缓存,稳定)。
struct ArchiveFileEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Archived File")
    static let defaultQuery = ArchiveFileQuery()

    /// id 分隔符:SOH(U+0001),正常文件路径里不会出现。
    private static let separator = "\u{1}"

    let id: String
    /// 归档磁盘路径 + 条目归档内完整路径(打开 / 解压定位用)。不作 @Property 暴露。
    let archivePath: String
    let entryPath: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Archive")
    var archiveName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(L10n.format("spotlight.archivedFile.in", archiveName))",
            image: .init(systemName: "doc")
        )
    }

    init(archivePath: String, archiveName: String, entryPath: String) {
        // 先初始化 plain 存储属性(id / archivePath / entryPath),再赋 @Property(setter 是对 self 的调用)。
        id = Self.makeID(archivePath: archivePath, entryPath: entryPath)
        self.archivePath = archivePath
        self.entryPath = entryPath
        name = (entryPath as NSString).lastPathComponent
        self.archiveName = archiveName
    }

    static func makeID(archivePath: String, entryPath: String) -> String {
        archivePath + separator + entryPath
    }

    static func parseID(_ id: String) -> (archivePath: String, entryPath: String)? {
        // 按**第一个**分隔符切:archivePath 是磁盘路径(不会含 \u{1}),entryPath 是不可信归档条目名 ——
        // 可能含控制字符(含 \u{1} 自身)。整段切会让 parts 数错位、Spotlight 点击失效;只切第一处则 entryPath
        // 原样保留(含其中的 \u{1}),仍能正确路由。
        guard let range = id.range(of: separator) else { return nil }
        let archivePath = String(id[..<range.lowerBound])
        let entryPath = String(id[range.upperBound...])
        guard !archivePath.isEmpty, !entryPath.isEmpty else { return nil }
        return (archivePath, entryPath)
    }
}

struct ArchiveFileQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ArchiveFileEntity] {
        identifiers.compactMap { id in
            guard let parsed = ArchiveFileEntity.parseID(id) else { return nil }
            let archiveName = (parsed.archivePath as NSString).lastPathComponent
            return ArchiveFileEntity(archivePath: parsed.archivePath, archiveName: archiveName, entryPath: parsed.entryPath)
        }
    }

    func suggestedEntities() async throws -> [ArchiveFileEntity] {
        var result: [ArchiveFileEntity] = []
        for archive in ArchiveListingCacheStore().loadAll().prefix(5) {
            for path in archive.filePaths(limit: 4) {
                result.append(ArchiveFileEntity(archivePath: archive.archivePath, archiveName: archive.archiveName, entryPath: path))
            }
        }
        return result
    }
}

// MARK: - 打开文件(OpenIntent:点 Spotlight 单文件结果 → 跳转 / 单文件解压)

struct OpenArchiveFileIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open File in SimpleZip"

    @Parameter(title: "File")
    var target: ArchiveFileEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let url = URL(fileURLWithPath: target.archivePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 归档已被移走 → 清缓存与索引,报错。
            ArchiveListingCacheStore().remove(archivePath: target.archivePath)
            CachedArchiveSpotlightIndexer.reindex()
            ArchiveFileSpotlightIndexer.reindex()
            throw SimpleZipIntentError(message: L10n.format("intent.error.missingFile", url.path))
        }
        if AppPreferences.finderOpenAutoExtract {
            // 开了自动解压 → 只解压搜到的这一个文件,完成后在 Finder 显示(不是解压整包)。
            try await ArchiveSingleFileExtractor.extractAndReveal(archiveURL: url, entryPath: target.entryPath)
        } else {
            // 关了自动解压 → 在浏览器里打开归档并跳到该文件所在目录、选中高亮。
            AppDelegate.openExternalArchive(url, revealEntryPath: target.entryPath)
        }
        return .result()
    }
}

/// #72:从归档里只解压**一个条目**到归档旁的唯一命名文件夹,完成后在 Finder 里选中它。Spotlight 单文件结果
/// 在「Finder 打开时自动解压」开启时走这里 —— 整包不动,只取那一个文件。无人值守:绝不弹密码框,只在配了
/// 预设密码且允许自动化用预设时静默重试一次。
@MainActor
enum ArchiveSingleFileExtractor {
    static func extractAndReveal(archiveURL: URL, entryPath: String) async throws {
        let entry = ArchiveItem(name: entryPath, isDirectory: false, size: nil, modified: nil,
                                sizeText: "", modifiedText: "", method: "")
        let fileBase = (entryPath as NSString).lastPathComponent
        let archiveBase = archiveURL.deletingPathExtension().lastPathComponent
        let preferred = archiveURL.deletingLastPathComponent()
            .appendingPathComponent("\(archiveBase) — \(fileBase)")
        let destination = UniqueFileName.suffixed(for: preferred, suffix: "") {
            FileManager.default.fileExists(atPath: $0.path)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let operationID = UUID()
        let task = TaskCenter.shared.begin(
            category: .archive,
            kind: .extract,
            source: .intent,
            title: L10n.format("intent.task.extractFile", fileBase),
            cancellable: false,
            operationID: operationID
        )
        do {
            try await extractHonoringPresetPassword(archiveURL, entry: entry, to: destination, operationID: operationID)
            TaskCenter.shared.finish(task, outcome: .succeeded(destination))
            // 揭示解压出来的文件(.preserve 保留路径 → 落在 destination/entryPath);找不到就退回目录。
            let extracted = destination.appendingPathComponent(entryPath)
            let revealURL = FileManager.default.fileExists(atPath: extracted.path) ? extracted : destination
            NSApp.activate(ignoringOtherApps: true)
            NSWorkspace.shared.activateFileViewerSelecting([revealURL])
        } catch {
            // 失败:把空目录清掉,别留垃圾。
            try? FileManager.default.removeItem(at: destination)
            TaskCenter.shared.finish(task, outcome: .failed(error.localizedDescription))
            throw SimpleZipIntentError(message: error.localizedDescription)
        }
    }

    private static func extractHonoringPresetPassword(_ url: URL, entry: ArchiveItem, to destination: URL, operationID: UUID) async throws {
        do {
            try await ArchiveService.extract(url, entries: [entry], to: destination, operationID: operationID)
        } catch {
            guard ArchiveService.errorSuggestsPasswordRequirement(error),
                  AppPreferences.hasUsablePresetPassword,
                  AppPreferences.automationAllowPresetPassword else { throw error }
            try await ArchiveService.extract(url, entries: [entry], to: destination,
                                             password: AppPreferences.presetPassword, operationID: operationID)
        }
    }
}

// MARK: - Spotlight 语义索引(macOS 15+,每归档封顶,双门控)

@available(macOS 15.0, *)
extension ArchiveFileEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .content)
        set.title = name
        set.displayName = name
        // 下方小字:在「XXX」压缩包内 · 路径。
        set.contentDescription = L10n.format("spotlight.archivedFile.inPath", archiveName, entryPath)
        set.keywords = ["SimpleZip", name]
        return set
    }
}

/// 把缓存归档里的文件逐个同步进 Spotlight。每归档封顶 `perArchiveLimit` 条(封顶 OS 索引体积);双门控同 #35。
/// 触发:启动全量重建、每次某归档缓存更新后增量、设置里切换 Spotlight / 缓存开关或改上限 / TTL / 清空时。
nonisolated enum ArchiveFileSpotlightIndexer {
    /// 单个归档最多索引这么多文件(常见「找文档」够用,又不让大包把系统索引撑爆)。
    static let perArchiveLimit = 400

    private static var donationAllowed: Bool {
        AppPreferences.spotlightIndexingEnabled && AppPreferences.archiveListingCacheEnabled
    }

    static func reindex() {
        Task.detached(priority: .utility) {
            guard #available(macOS 15.0, *) else { return }
            await reindexIfNeeded()
        }
    }

    /// 串行协调器调用(已在单一后台任务里顺序 await)。**指纹没变就整轮跳过**(启动卡顿修复:不再每次冷启动
    /// 全量删 + 全量写上千条)。门控关 → 清索引 + 复位指纹(重新开启时一定会重建)。
    @available(macOS 15.0, *)
    static func reindexIfNeeded() async {
        let key = "archiveFiles"
        guard donationAllowed else {
            await clearIndex()
            SpotlightReindexGuard.reset(key: key)
            return
        }
        // 电源档时间闸:间隔内不重查(省电一天一次)→ 后台占用低,慢点没事。
        guard SpotlightReindexGuard.shouldCheckNow(key: key, interval: SpotlightIndexingPower.current.recheckInterval) else { return }
        SpotlightReindexGuard.markChecked(key: key)
        // 指纹 = 归档缓存原始数据(读文件后端,已迁出 UserDefaults.standard)+ 单包封顶(影响条目数);
        // 没变 → 跳过(不解码、不建项、不打 IPC)。
        let fp = SpotlightReindexGuard.fingerprint(of: ArchiveListingCacheStore().persistedFingerprintData())
            + ":\(perArchiveLimit)"
        guard !SpotlightReindexGuard.isUpToDate(key: key, fingerprint: fp) else { return }
        if await performReindex() {
            SpotlightReindexGuard.markIndexed(key: key, fingerprint: fp)
        }
    }

    /// 增量:某归档刚打开 / 缓存更新后,只索引它的文件。
    static func indexArchive(at url: URL) {
        guard #available(macOS 15.0, *), donationAllowed,
              SpotlightIndexingPower.current.allowsRealtimeIncremental else { return }   // 省电:不实时增量,靠周期重查兜底
        let path = ArchiveListingCacheStore.canonicalPath(for: url)
        Task.detached(priority: .utility) {
            guard let archive = ArchiveListingCacheStore().loadAll().first(where: { $0.archivePath == path }) else { return }
            let items = makeItems(for: archive)
            if !items.isEmpty {
                try? await CSSearchableIndex.default().indexSearchableItems(items)
            }
        }
    }

    /// #73:每文件一条手动 CSSearchableItem(uniqueIdentifier 编码 archivePath+entryPath),点击 → 跳到该文件 / 单文件解压。
    @available(macOS 15.0, *)
    private static func makeItems(for archive: ArchiveListingCacheEntry) -> [CSSearchableItem] {
        archive.filePaths(limit: perArchiveLimit).map { path in
            let entity = ArchiveFileEntity(archivePath: archive.archivePath, archiveName: archive.archiveName, entryPath: path)
            return makeSpotlightItem(route: .archiveFile(archivePath: archive.archivePath, entryPath: path),
                                     attributeSet: entity.attributeSet)
        }
    }

    /// 全量重建。返回是否成功(成功才记录指纹 → 失败的轮次下次冷启动会重试,不会被错误地跳过)。
    /// DevTools 全量 dump 用:返回当前会捐献的全部归档内文件条目(与 performReindex 同源,逐包封顶)。
    @available(macOS 15.0, *)
    static func dumpItems() -> [CSSearchableItem] {
        ArchiveListingCacheStore().loadAll().flatMap { makeItems(for: $0) }
    }

    @available(macOS 15.0, *)
    private static func performReindex() async -> Bool {
        let items = dumpItems()
        let index = CSSearchableIndex.default()
        do {
            try? await index.deleteAppEntities(ofType: ArchiveFileEntity.self)  // #73 迁移:清旧 indexAppEntities 残留
            try await index.deleteSearchableItems(withDomainIdentifiers: [SpotlightRoute.Domain.file])
            if !items.isEmpty {
                try await index.indexSearchableItems(items)
            }
            return true
        } catch {
            return false   // 索引失败不影响 app;不记指纹,下轮重试。
        }
    }

    @available(macOS 15.0, *)
    private static func clearIndex() async {
        do {
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [SpotlightRoute.Domain.file])
        } catch {
            // 清索引失败不影响 app。
        }
    }
}

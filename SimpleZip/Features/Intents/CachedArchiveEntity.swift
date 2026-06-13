//
//  CachedArchiveEntity.swift
//  SimpleZip
//
//  0.4.4 #35:把「打开过、记下了非加密条目名」的归档(ArchiveListingCache)暴露成 AppEntity,
//  让 Spotlight / Siri / Shortcuts 能按**归档内文件名**找到「这个文件在哪个压缩包里」,一点即开那个包。
//
//  **隐私红线**:只用 #34 缓存里的**非加密**条目名(加密条目从不入缓存,见 ArchiveListingCache);
//  绝不读取内容、绝不解压。OS 级 Spotlight 捐献**双门控** —— Spotlight 索引总开关 `spotlightIndexingEnabled`
//  + 缓存开关 `archiveListingCacheEnabled`,任一关闭都不向系统索引捐献(并清空已捐献的归档项)。
//  Siri/Shortcuts 的「查文件在哪个包」只读本机缓存,不依赖 OS 索引,只受缓存开关约束。
//
//  本地化口径同 SimpleZipAppIntents:静态元数据用字面 LocalizedStringResource(英文即键,各 .lproj 补译);
//  运行期 dialog / 错误走 app 的 L10n。AppEntity / EntityQuery / OpenIntent 自 macOS 13 可用(= 部署目标);
//  IndexedEntity(Spotlight)是 macOS 15,放单独 @available extension。
//

import AppIntents
import CoreSpotlight
import Foundation

/// 一个被缓存了清单的归档。id = 规范化磁盘路径(`ArchiveListingCacheEntry.archivePath`)。
struct CachedArchiveEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Archive")
    static let defaultQuery = CachedArchiveQuery()

    /// 规范化磁盘路径,既是稳定 id 也是打开时定位文件用的路径。
    let id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "File Count")
    var entryCount: Int

    @Property(title: "Last Opened")
    var lastOpened: Date

    /// 归档内条目的**文件名**(去重、仅 basename、有上限)——给 Spotlight 当关键词,让搜某个文件名能命中本归档。
    /// 不作为 @Property 暴露(Shortcuts 里不需要看到一长串文件名),只在 Spotlight attributeSet 里用。
    let keywordNames: [String]
    /// 展示用的**完整相对路径**(不去重,保留结构),给 Spotlight 结果描述列出包里到底有哪些文件。
    let displayPaths: [String]
    /// 非加密文件总数(判断描述是否还有更多没列出)。
    let fileEntryCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(URL(fileURLWithPath: id).deletingLastPathComponent().path)",
            image: .init(systemName: "doc.zipper")
        )
    }

    init(entry: ArchiveListingCacheEntry) {
        // 先初始化所有 plain 存储属性(id / keywordNames),再赋 @Property 包装值 —— 包装值 setter 是对 self
        // 的方法调用,要求此时所有存储属性已就绪(同 ReleasePackageEntity)。
        id = entry.archivePath
        // 关键词抽取(去重 basename + 跳目录 + 封顶)是 Core 里的纯逻辑,带单测。
        keywordNames = entry.fileBaseNames()
        displayPaths = entry.filePaths(limit: 24)
        fileEntryCount = entry.fileEntryCount
        name = entry.archiveName
        entryCount = entry.entries.count
        lastOpened = entry.recordedAt
    }
}

/// 缓存归档查询:全部读自 `ArchiveListingCacheStore`(nonisolated UserDefaults JSON,已是新→旧)。
struct CachedArchiveQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [CachedArchiveEntity] {
        let byPath = Dictionary(
            ArchiveListingCacheStore().loadAll().map { ($0.archivePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return identifiers.compactMap { byPath[$0].map(CachedArchiveEntity.init(entry:)) }
    }

    func suggestedEntities() async throws -> [CachedArchiveEntity] {
        ArchiveListingCacheStore().loadAll().prefix(20).map(CachedArchiveEntity.init(entry:))
    }
}

// MARK: - 打开缓存归档(OpenIntent:点 Spotlight 结果 / Shortcuts 接收实体都走这里)

/// 打开一个缓存归档(浏览它的内容)。点 Spotlight 命中的归档项、或在 Shortcuts 里把「查找」结果接到这里,
/// 都会让 SimpleZip 按外部打开语义打开该归档。文件已不在 → 顺手从缓存 / 索引清掉并报错。
struct OpenCachedArchiveIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Archive in SimpleZip"

    @Parameter(title: "Archive")
    var target: CachedArchiveEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let url = URL(fileURLWithPath: target.id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 归档已被移走 / 删除:清掉这条缓存与它的 Spotlight 项,别再把死链留在搜索结果里。
            ArchiveListingCacheStore().remove(archivePath: target.id)
            CachedArchiveSpotlightIndexer.reindex()
            throw SimpleZipIntentError(message: L10n.format("intent.error.missingFile", url.path))
        }
        AppDelegate.openExternalArchive(url)
        return .result()
    }
}

// MARK: - 查找含某文件名的归档(Siri / Shortcuts)

/// 在「打开过的归档」里按文件名找出「这个文件在哪个压缩包里」。只读本机缓存(不依赖 OS Spotlight),
/// 只搜**非加密**条目名,绝不解压。返回命中的归档实体(可直接接到「Open Archive」动作)。
struct FindArchiveContainingFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Archive Containing File"
    static let description = IntentDescription(
        "Searches the archives you've opened in SimpleZip for a file name and returns which archives contain it. Only non-encrypted entry names are searched; nothing is extracted."
    )

    @Parameter(title: "File Name")
    var fileName: String

    static var parameterSummary: some ParameterSummary {
        Summary("Find which archive contains \(\.$fileName)")
    }

    // 稳定返回契约(发版后不得改类型/语义):ReturnsValue<[CachedArchiveEntity]> = 含该文件名的归档(去重到归档级,
    // 无匹配 = 空数组)。命中数量在 dialog。
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[CachedArchiveEntity]> & ProvidesDialog {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SimpleZipIntentError(message: L10n.text("intent.search.emptyQuery"))
        }
        let store = ArchiveListingCacheStore()
        let byPath = Dictionary(store.loadAll().map { ($0.archivePath, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var archives: [CachedArchiveEntity] = []
        for hit in store.search(trimmed, limit: 500) where seen.insert(hit.archivePath).inserted {
            if let entry = byPath[hit.archivePath] {
                archives.append(CachedArchiveEntity(entry: entry))
            }
        }
        if archives.isEmpty {
            return .result(value: [], dialog: IntentDialog("\(L10n.format("intent.findArchive.none", trimmed))"))
        }
        return .result(
            value: archives,
            dialog: IntentDialog("\(L10n.format("intent.findArchive.results", "\(archives.count)", trimmed))")
        )
    }
}

// MARK: - Spotlight 语义索引(macOS 15+,双门控,克制)

/// 让缓存归档进 Spotlight:**只**索引归档名 + 其中非加密条目的**文件名**(关键词),让用户在系统 Spotlight
/// 里搜一个文件名就能找到含它的压缩包,点开即在 SimpleZip 里打开。绝不索引加密条目名 / 任何内容(隐私红线)。
@available(macOS 15.0, *)
extension CachedArchiveEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .content)
        set.title = name
        set.displayName = name
        set.contentCreationDate = lastOpened
        // 关键词 = 归档内文件名,让搜文件名命中本归档。SimpleZip 标识便于按 app 过滤。
        set.keywords = ["SimpleZip"] + keywordNames
        // 描述里**列出实际文件的完整相对路径**(前若干个,超出加 …),让 Spotlight 结果一眼看到包里到底有
        // 哪些文件、各在什么路径(比去重 basename 颗粒度细)。都是非加密条目(加密条目从不入缓存),展示合规。
        var preview = displayPaths.joined(separator: ", ")
        if fileEntryCount > displayPaths.count { preview += " …" }
        set.contentDescription = preview.isEmpty
            ? L10n.format("spotlight.cachedArchive.description", "\(fileEntryCount)")
            : L10n.format("spotlight.cachedArchive.descriptionWithNames", "\(fileEntryCount)", preview)
        return set
    }
}

/// 把缓存归档同步进 Spotlight 语义索引。旧系统(< macOS 15)no-op;失败静默(增益功能,绝不影响 app)。
/// **双门控**:`spotlightIndexingEnabled && archiveListingCacheEnabled` 都开才捐献,任一关 → 清空已捐献的归档项。
/// 触发点:app 启动(全量重建)、每次缓存更新后(增量索引单个归档)、设置里切换任一开关。
nonisolated enum CachedArchiveSpotlightIndexer {
    private static var donationAllowed: Bool {
        AppPreferences.spotlightIndexingEnabled && AppPreferences.archiveListingCacheEnabled
    }

    /// 全量:开 → 按当前缓存重建;关 → 清空已捐献的归档项。
    static func reindex() {
        guard #available(macOS 15.0, *) else { return }
        let allowed = donationAllowed
        Task.detached(priority: .utility) {
            if allowed {
                await performReindex()
            } else {
                await clearIndex()
            }
        }
    }

    /// 增量:打开一个归档、缓存更新后只索引这一条(避免每次打开都全量重建)。门控同上。
    static func indexArchive(at url: URL) {
        guard #available(macOS 15.0, *), donationAllowed else { return }
        let path = ArchiveListingCacheStore.canonicalPath(for: url)
        Task.detached(priority: .utility) {
            guard let entry = ArchiveListingCacheStore().loadAll().first(where: { $0.archivePath == path }) else { return }
            let item = makeSpotlightItem(route: .archive(archivePath: entry.archivePath),
                                         attributeSet: CachedArchiveEntity(entry: entry).attributeSet)
            try? await CSSearchableIndex.default().indexSearchableItems([item])
        }
    }

    @available(macOS 15.0, *)
    private static func performReindex() async {
        // #73:手动 CSSearchableItem,点击 → 在浏览器里打开归档(根目录)。
        let items = ArchiveListingCacheStore().loadAll().map { entry -> CSSearchableItem in
            makeSpotlightItem(route: .archive(archivePath: entry.archivePath),
                              attributeSet: CachedArchiveEntity(entry: entry).attributeSet)
        }
        let index = CSSearchableIndex.default()
        do {
            try? await index.deleteAppEntities(ofType: CachedArchiveEntity.self)  // #73 迁移:清旧 indexAppEntities 残留
            try await index.deleteSearchableItems(withDomainIdentifiers: [SpotlightRoute.Domain.archive])
            if !items.isEmpty {
                try await index.indexSearchableItems(items)
            }
        } catch {
            // 索引失败不影响 app。
        }
    }

    @available(macOS 15.0, *)
    private static func clearIndex() async {
        do {
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [SpotlightRoute.Domain.archive])
        } catch {
            // 清索引失败不影响 app。
        }
    }
}

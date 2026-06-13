//
//  ReleasePackageEntity.swift
//  SimpleZip
//
//  0.4.4 · macOS 26 AI 第一批:把发布账本(ReleaseLedger)里每条**成功发布**暴露成 AppEntity,
//  让 Shortcuts / Siri(及后续 Spotlight 索引)能引用「上次那个发布包」。数据源只读自
//  ReleaseLedgerStore,纯账面字段;绝不暴露归档内文件名 / 内容,也不触发任何写入或安全判定。
//
//  本地化口径同 SimpleZipAppIntents:静态元数据用字面 LocalizedStringResource(英文字面量即键,
//  各 .lproj 补译)。AppEntity / EntityQuery 自 macOS 13 起可用(= 部署目标),无需 @available;
//  IndexedEntity(Spotlight,macOS 15)放后续单独门控的 extension,不在本文件。
//

import AppKit
import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// 一个已记入账本的发布包。id 复用 `ReleaseLedgerEntry.id`(稳定 UUID)。
struct ReleasePackageEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Release Package")
    static let defaultQuery = ReleasePackageQuery()

    let id: UUID

    /// 版本标签(空则展示时回退到产物文件名)。
    @Property(title: "Version")
    var version: String

    @Property(title: "Date")
    var date: Date

    @Property(title: "Format")
    var format: String

    @Property(title: "SHA-256")
    var sha256: String?

    @Property(title: "File Count")
    var fileCount: Int?

    @Property(title: "Reproducible")
    var reproducible: Bool

    @Property(title: "Checksums Written")
    var wroteChecksums: Bool

    /// 产物完整路径 —— 内部用(供后续接收本实体的 intent 定位文件),不作为 @Property 暴露给用户。
    let artifactPath: String

    var displayRepresentation: DisplayRepresentation {
        let fileName = URL(fileURLWithPath: artifactPath).lastPathComponent
        let title = version.isEmpty ? fileName : version
        var parts: [String] = [Self.dateFormatter.string(from: date)]
        if !fileName.isEmpty { parts.append(fileName) }
        if let sha = sha256, sha.count >= 8 { parts.append(String(sha.prefix(8))) }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(parts.joined(separator: " · "))",
            image: .init(systemName: "shippingbox")
        )
    }

    init(entry: ReleaseLedgerEntry) {
        // 先初始化所有 plain 存储属性(两个 let),再赋 @Property 包装值 ——
        // 包装值的 setter 是对 self 的方法调用,要求此时所有存储属性已就绪。
        id = entry.id
        artifactPath = entry.artifactPath
        version = entry.versionLabel
        date = entry.date
        format = Self.friendlyFormat(entry.formatRawValue)
        sha256 = entry.sha256
        fileCount = entry.fileCount
        reproducible = entry.reproducible
        wroteChecksums = entry.wroteChecksums
    }

    private static func friendlyFormat(_ raw: String) -> String {
        switch raw {
        case "zip": return "ZIP"
        case "sevenZip": return "7-Zip"
        default: return raw
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// 发布包查询:全部读自 `ReleaseLedgerStore`(nonisolated UserDefaults JSON,账本已是新→旧)。
/// 用普通 `EntityQuery`(macOS 13);`IndexedEntityQuery`(macOS 27)留到 27。
struct ReleasePackageQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ReleasePackageEntity] {
        let byID = Dictionary(
            ReleaseLedgerStore().loadAll().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return identifiers.compactMap { byID[$0].map(ReleasePackageEntity.init(entry:)) }
    }

    func suggestedEntities() async throws -> [ReleasePackageEntity] {
        // 账本已是新→旧;只建议最近 20 条,避免 Shortcuts 选择器过长。
        ReleaseLedgerStore().loadAll().prefix(20).map(ReleasePackageEntity.init(entry:))
    }
}

// MARK: - 打开发布包(OpenIntent:#49 点 Spotlight 结果 → 在 Finder 里显示产物)

/// 点 Spotlight 里搜到的发布包 → 在 Finder 里选中它的产物文件(产物已不在则只把 app 带到前台)。
/// 只定位文件,不打开 / 不校验 / 不改任何东西。
struct OpenReleasePackageIntent: OpenIntent {
    static let title: LocalizedStringResource = "Show Release Package in Finder"

    @Parameter(title: "Release Package")
    var target: ReleasePackageEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let url = URL(fileURLWithPath: target.artifactPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // 产物已被移走 / 删除 → 不报错,只把 app 带到前台(OpenIntent 已会前台化)。
            NSApp.activate(ignoringOtherApps: true)
        }
        return .result()
    }
}

// MARK: - Spotlight 语义索引(macOS 15+,克制)

/// 让发布包进 Spotlight。**只**索引可公开的发布元数据(标题=版本/产物文件名、创建日期、
/// 产物文件名、SHA-256 前 8 位、格式)—— 绝不含完整用户路径、结构指纹、归档内文件名/内容(隐私红线)。
@available(macOS 15.0, *)
extension ReleasePackageEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .content)
        let fileName = URL(fileURLWithPath: artifactPath).lastPathComponent
        let displayTitle = version.isEmpty ? fileName : version
        set.title = displayTitle
        set.displayName = displayTitle
        set.contentCreationDate = date
        var lines: [String] = []
        if !fileName.isEmpty { lines.append(fileName) }
        if let sha = sha256, sha.count >= 8 { lines.append("SHA-256 " + String(sha.prefix(8))) }
        if !lines.isEmpty { set.contentDescription = lines.joined(separator: "\n") }
        set.keywords = ["SimpleZip", format]
        return set
    }
}

/// 把发布账本同步进 Spotlight 语义索引。旧系统(< macOS 15)是 no-op;索引失败静默
/// (Spotlight 是增益功能,绝不影响发布流程,也不弹错 / 不崩)。
/// 触发点:app 启动(全量重建)、每次成功记入账本之后。
enum ReleasePackageSpotlightIndexer {
    /// 索引开关开 → 全量重建;关 → 清空已捐献的索引。两条路径都按 `AppPreferences.spotlightIndexingEnabled`
    /// 分支,所以启动、记入账本、设置里切换开关都调它即可即时生效。
    static func reindex() {
        guard #available(macOS 15.0, *) else { return }
        Task.detached(priority: .utility) {
            if AppPreferences.spotlightIndexingEnabled {
                await performReindex()
            } else {
                await clearIndex()
            }
        }
    }

    @available(macOS 15.0, *)
    private static func performReindex() async {
        // #73:手动 CSSearchableItem(uniqueIdentifier 由 SpotlightRoute 编码),点击能解回来跳转(在 Finder 显示产物)。
        let items = ReleaseLedgerStore().loadAll().map { entry -> CSSearchableItem in
            makeSpotlightItem(route: .release(artifactPath: entry.artifactPath),
                              attributeSet: ReleasePackageEntity(entry: entry).attributeSet)
        }
        let index = CSSearchableIndex.default()
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [SpotlightRoute.Domain.release])
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
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [SpotlightRoute.Domain.release])
        } catch {
            // 清索引失败不影响 app。
        }
    }
}

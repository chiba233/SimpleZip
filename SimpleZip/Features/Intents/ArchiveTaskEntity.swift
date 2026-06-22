//
//  ArchiveTaskEntity.swift
//  SimpleZip
//
//  0.4.4 · macOS 26 AI 第一批:把活动中心历史里的任务暴露成 AppEntity,让 Shortcuts / Siri
//  (及后续 Spotlight 索引)能引用「昨天失败的那个解压任务」。数据源是 nonisolated 的
//  ActivityHistoryStore(只读 activityHistory 的 UserDefaults JSON),不碰 @MainActor 的
//  TaskCenter 运行态;只暴露任务元数据,绝不触发任何写入或安全判定。
//
//  本地化:静态字段标题用字面 LocalizedStringResource(英文字面量即键,各 .lproj 补译);
//  source / status 的展示值在构造时走 app L10n(tasks.source.* 复用现有键、tasks.status.* 新增)。
//

import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

struct ArchiveTaskEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Archive Task")
    static let defaultQuery = ArchiveTaskQuery()

    let id: UUID

    @Property(title: "Source")
    var source: String

    @Property(title: "Status")
    var status: String

    @Property(title: "Started")
    var started: Date

    /// 任务标题(创建时已本地化,如「快捷指令:解压 X」)—— 作 displayRepresentation 标题。
    let taskTitle: String
    let outcome: ArchiveTaskSnapshot.Outcome
    /// #49:任务分类 —— 点 Spotlight 结果跳活动中心时选对分类页。不作 @Property 暴露(用户无需看到)。
    let category: OperationTask.Category

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(taskTitle)",
            subtitle: "\(source) · \(status) · \(Self.dateFormatter.string(from: started))",
            image: .init(systemName: Self.symbol(for: outcome))
        )
    }

    init(snapshot: ArchiveTaskSnapshot) {
        // 先初始化 plain 存储属性,再赋 @Property 包装值(setter 是对 self 的调用)。
        id = snapshot.id
        taskTitle = snapshot.title
        outcome = snapshot.outcome
        category = snapshot.category
        source = L10n.text("tasks.source.\(snapshot.source.rawValue)")
        status = L10n.text("tasks.status.\(snapshot.outcome.rawValue)")
        started = snapshot.startedAt
    }

    private static func symbol(for outcome: ArchiveTaskSnapshot.Outcome) -> String {
        switch outcome {
        case .succeeded: return "checkmark.circle"
        case .skipped: return "minus.circle"
        case .failed: return "xmark.octagon"
        case .cancelled: return "slash.circle"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// 历史任务查询:读自 nonisolated `ActivityHistoryStore`(已是新→旧)。普通 `EntityQuery`(macOS 13)。
struct ArchiveTaskQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ArchiveTaskEntity] {
        let byID = Dictionary(
            ActivityHistoryStore.snapshot().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return identifiers.compactMap { byID[$0].map(ArchiveTaskEntity.init(snapshot:)) }
    }

    func suggestedEntities() async throws -> [ArchiveTaskEntity] {
        // 只建议最近 20 条,避免选择器过长。
        ActivityHistoryStore.snapshot().prefix(20).map(ArchiveTaskEntity.init(snapshot:))
    }
}

// MARK: - 打开任务(OpenIntent:#49 点 Spotlight 结果 → 开活动中心并滚动定位高亮)

/// 点 Spotlight 里搜到的活动中心任务 → 打开活动中心、切到它所在分类页、滚到这条并闪一圈。
/// 只读历史,不重跑任何任务、不做安全判定。
struct OpenArchiveTaskIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Task in Activity Center"

    @Parameter(title: "Task")
    var target: ArchiveTaskEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        ActivityWindowController.shared.show(category: target.category, locateTaskID: target.id)
        return .result()
    }
}

// MARK: - Spotlight 语义索引(macOS 15+,活动中心任务可搜)

/// 让活动中心历史任务进 Spotlight。隐私口径(用户 2026-06-13 放宽):任务标题 / 操作 / 状态 / 日期
/// 都是非加密、登录用户本就可见的元数据,可索引;**不放 detail**(可能含完整路径,虽非敏感但索引无谓),
/// 更不会有加密归档的条目名 / 内容(任务元数据本就不含)。
@available(macOS 15.0, *)
extension ArchiveTaskEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .content)
        set.title = taskTitle
        set.displayName = taskTitle
        set.contentCreationDate = started
        set.contentDescription = "\(source) · \(status)"
        set.keywords = ["SimpleZip", source, status]
        return set
    }
}

/// 把活动中心历史任务同步进 Spotlight。受 `AppPreferences.spotlightIndexingEnabled` gate;旧系统 no-op;
/// 失败静默。触发:app 启动(全量重建)、每个任务收尾后(单条增量,不全量重建以免高频 finish 抖动)。
enum ArchiveTaskSpotlightIndexer {
    /// 开关开 → 全量重建;关 → 清空。启动与设置里切换开关都调它。
    static func reindex() {
        Task.detached(priority: .utility) {
            guard #available(macOS 15.0, *) else { return }
            await reindexIfNeeded()
        }
    }

    /// 串行协调器调用。**指纹(活动历史原始数据)没变就跳过**(启动卡顿修复)。门控关 → 清索引 + 复位指纹。
    @available(macOS 15.0, *)
    static func reindexIfNeeded() async {
        let key = "tasks"
        guard AppPreferences.spotlightIndexingEnabled else {
            await clearIndex()
            SpotlightReindexGuard.reset(key: key)
            return
        }
        guard SpotlightReindexGuard.shouldCheckNow(key: key, interval: SpotlightIndexingPower.current.recheckInterval) else { return }
        SpotlightReindexGuard.markChecked(key: key)
        let fp = SpotlightReindexGuard.fingerprint(of: TaskCenter.loadActivityHistoryData())
        guard !SpotlightReindexGuard.isUpToDate(key: key, fingerprint: fp) else { return }
        if await performReindex() {
            SpotlightReindexGuard.markIndexed(key: key, fingerprint: fp)
        }
    }

    /// 单条增量:任务收尾时调(@MainActor —— 从 @MainActor 的 OperationTask 取快照)。
    @MainActor
    static func index(_ task: OperationTask) {
        guard #available(macOS 15.0, *), AppPreferences.spotlightIndexingEnabled,
              SpotlightIndexingPower.current.allowsRealtimeIncremental else { return }   // 省电:不实时增量,靠周期重查兜底
        guard let snapshot = ArchiveTaskSnapshot(task: task) else { return }
        Task.detached(priority: .utility) {
            let item = makeSpotlightItem(
                route: .task(id: snapshot.id, categoryRaw: snapshot.category.rawValue),
                attributeSet: ArchiveTaskEntity(snapshot: snapshot).attributeSet
            )
            try? await CSSearchableIndex.default().indexSearchableItems([item])
        }
    }

    /// DevTools 全量 dump 用:返回当前会捐献的全部任务条目(与 performReindex 同源)。
    @available(macOS 15.0, *)
    static func dumpItems() -> [CSSearchableItem] {
        ActivityHistoryStore.snapshot().map { snapshot in
            makeSpotlightItem(route: .task(id: snapshot.id, categoryRaw: snapshot.category.rawValue),
                              attributeSet: ArchiveTaskEntity(snapshot: snapshot).attributeSet)
        }
    }

    @available(macOS 15.0, *)
    private static func performReindex() async -> Bool {
        // #73:手动 CSSearchableItem,点击 → 开活动中心定位到该任务。
        let items = dumpItems()
        let index = CSSearchableIndex.default()
        do {
            try? await index.deleteAppEntities(ofType: ArchiveTaskEntity.self)  // #73 迁移:清旧 indexAppEntities 残留
            try await index.deleteSearchableItems(withDomainIdentifiers: [SpotlightRoute.Domain.task])
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
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [SpotlightRoute.Domain.task])
        } catch {
            // 清索引失败不影响 app。
        }
    }
}

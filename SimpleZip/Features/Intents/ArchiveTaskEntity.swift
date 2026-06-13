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
import Foundation

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

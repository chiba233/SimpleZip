//
//  AISchemaMigration.swift
//  SimpleZip
//
//  0.4.5 #80:AI 持久化 Schema 版本与迁移契约(白皮书工程补充十三)。这套方案会新增很多持久化结构
//  (工作区 / 反馈 / 习惯摘要 / 归档画像缓存 …),所有持久化 schema 必须从第一版就带版本号、有迁移策略。
//
//  关键原则(补十三):
//  - 派生缓存迁移失败 → 直接丢弃重建(重建廉价)。
//  - 用户创建的工作区**不能静默丢弃** → 迁移失败时保留标题 / prompt 这层用户可见外壳,只重建派生部分。
//  - 读到比当前更新的版本(降级打开)→ 无法理解,按上面两类分别处理。
//
//  纯值类型 + 确定性决策,SwiftPM 可断言。
//

import Foundation

/// 带版本号的持久化结构。每个 AI 持久化类型都应实现它。
nonisolated protocol AISchemaVersioned: Codable {
    static var currentSchemaVersion: Int { get }
    var schemaVersion: Int { get }
}

/// 读取一条持久化记录时该走的迁移策略(稳定英文 token)。
nonisolated enum AISchemaMigrationDecision: String, Codable, Equatable, Sendable {
    /// 版本一致,直接用。
    case useAsIs = "use-as-is"
    /// 旧版派生缓存:丢弃重建。
    case discardAndRebuild = "discard-and-rebuild"
    /// 用户创建数据:保留用户可见外壳(标题 / prompt),重建派生部分。
    case preserveUserShell = "preserve-user-shell"
}

/// 迁移执行结果(泛型携带迁移后的值或重建提示)。
nonisolated enum AISchemaMigrationResult<Value: Sendable>: Sendable {
    case upToDate(Value)
    case migrated(Value)
    case discardAndRebuild(reason: String)
    case preserveUserFacingShell(reason: String)
}

nonisolated enum AISchemaMigrator {
    /// 确定性决策:从存储版本 vs 当前版本 + 是否派生缓存,决定迁移策略。
    /// - 版本一致 → useAsIs。
    /// - 版本不一致(无论旧 / 新):派生缓存 → discardAndRebuild;用户数据 → preserveUserShell。
    static func decide(storedVersion: Int, currentVersion: Int, isDerivedCache: Bool) -> AISchemaMigrationDecision {
        guard storedVersion != currentVersion else { return .useAsIs }
        return isDerivedCache ? .discardAndRebuild : .preserveUserShell
    }

    /// 便捷:对一个已解码的 `AISchemaVersioned` 值给出决策(用它自带的版本字段)。
    static func decide<T: AISchemaVersioned>(for value: T, isDerivedCache: Bool) -> AISchemaMigrationDecision {
        decide(storedVersion: value.schemaVersion, currentVersion: T.currentSchemaVersion, isDerivedCache: isDerivedCache)
    }
}

//
//  ReleaseWorkspacePresetEntity.swift
//  SimpleZip
//
//  0.4.4 · macOS 26 AI:发布工作区预设作为 Shortcuts/Siri 的**参数选择器**。
//  让「创建发布包」intent 从已存的工作区预设里挑(而不是凭记忆敲名字)。
//  EntityStringQuery 让它同时支持「列表选」与「按名字动态匹配」(Shortcuts 变量传入)。
//  只读 ReleaseWorkspacePresetStore(nonisolated UserDefaults JSON);不触发任何写入。
//

import AppIntents
import Foundation

struct ReleaseWorkspacePresetEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Workspace Preset")
    static let defaultQuery = ReleaseWorkspacePresetQuery()

    let id: UUID

    @Property(title: "Name")
    var name: String

    let fileName: String
    let format: String

    var displayRepresentation: DisplayRepresentation {
        var parts: [String] = []
        if !fileName.isEmpty { parts.append(fileName) }
        parts.append(format)
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(parts.joined(separator: " · "))",
            image: .init(systemName: "shippingbox.and.arrow.backward")
        )
    }

    init(preset: ReleaseWorkspacePreset) {
        id = preset.id
        fileName = preset.fileName
        switch preset.formatRawValue {
        case "zip": format = "ZIP"
        case "sevenZip": format = "7-Zip"
        default: format = preset.formatRawValue
        }
        name = preset.name
    }
}

/// 工作区预设查询。`EntityStringQuery` 让 Shortcuts 既能从列表选,也能按名字(变量/动态)匹配。
struct ReleaseWorkspacePresetQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [ReleaseWorkspacePresetEntity] {
        let byID = Dictionary(
            ReleaseWorkspacePresetStore().loadAll().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return identifiers.compactMap { byID[$0].map(ReleaseWorkspacePresetEntity.init(preset:)) }
    }

    func suggestedEntities() async throws -> [ReleaseWorkspacePresetEntity] {
        ReleaseWorkspacePresetStore().loadAll().map(ReleaseWorkspacePresetEntity.init(preset:))
    }

    func entities(matching string: String) async throws -> [ReleaseWorkspacePresetEntity] {
        ReleaseWorkspacePresetStore().loadAll()
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(ReleaseWorkspacePresetEntity.init(preset:))
    }
}

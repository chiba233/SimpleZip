//
//  ReleaseWorkspacePreset.swift
//  SimpleZip
//
//  发布助手的命名「工作区预设」(队列 #18)—— 与压缩无关,从 CompressionPreset.swift 切出独立成文件(P1c)。
//

import Foundation

/// 发布助手的命名「工作区预设」:产物目录 / 文件名 / 格式 / 输出目录 / 五个步骤开关一把存,
/// 一键回到某个项目的发布配置。密码与 GPG 私钥从不入库(发布助手本就不收密码;
/// 签名密钥在「创建签名清单」sheet 里现选,不进预设)。
struct ReleaseWorkspacePreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var sourceFolderPath: String?
    var fileName: String
    /// #2:版本标签(0.4.4 新增,Optional —— 旧预设 JSON 没有此键,解码兼容)。
    var versionLabel: String?
    /// ArchiveCreateFormat.rawValue(zip / sevenZip)。存原始值避免给枚举强加 Codable 形态。
    var formatRawValue: String
    var destinationFolderPath: String?
    var excludeJunk: Bool
    var reproducible: Bool
    var runInspection: Bool
    var writeChecksums: Bool
    /// #4:写 release-manifest.json(0.4.4 新增,Optional 解码兼容旧预设)。
    var writeManifest: Bool?
    var createSignedManifest: Bool
    /// #10:质量门规则(0.4.4 新增,Optional 解码兼容;nil = 全关)。
    var gateRules: ReleaseGateRules?
}

/// 工作区预设的 UserDefaults JSON 存取(与 CompressionDefaultsStore 同款形态:
/// 存 JSON Data、备份导出 / 导入 / 恢复默认在 AppPreferences 侧单独处理)。
nonisolated final class ReleaseWorkspacePresetStore {
    private let defaults: UserDefaults
    private let storageKey = AppPreferences.Key.releaseWorkspacePresets

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAll() -> [ReleaseWorkspacePreset] {
        guard let data = defaults.data(forKey: storageKey),
              let presets = try? JSONDecoder().decode([ReleaseWorkspacePreset].self, from: data) else { return [] }
        return presets
    }

    /// 同名覆盖(用户重存同一项目的配置就是想更新),否则追加;按名字排序持久化。
    func save(_ preset: ReleaseWorkspacePreset) {
        var all = loadAll().filter { $0.name != preset.name }
        all.append(preset)
        persist(all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    func delete(id: UUID) {
        persist(loadAll().filter { $0.id != id })
    }

    private func persist(_ all: [ReleaseWorkspacePreset]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

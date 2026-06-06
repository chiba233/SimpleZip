//
//  CompressionPreset.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/06.
//
//  #115 模板化压缩 Presets —— **纯 Core 模型 + 持久化**。一个 preset = 给一组
//  `ArchiveCreationOptions` 起个名存起来（「工作用 zip」「高压缩 7z」「加密分发」「signed .siz」），
//  创建对话框一键套用。复用现有 `ArchiveCreationOptions`（不另造镜像 DTO），存进 UserDefaults。
//  套用 / 保存的 UI 接入另行处理，不在此文件。
//

import Foundation

/// 一条命名的压缩预设。`options` 直接复用 `ArchiveCreationOptions`，所以新增创建选项会自动可存。
struct CompressionPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var options: ArchiveCreationOptions

    init(id: UUID = UUID(), name: String, options: ArchiveCreationOptions) {
        self.id = id
        self.name = name
        self.options = options
    }

    /// 去掉**不该随预设持久化**的逐次操作字段。见 `ArchiveCreationOptions.sanitizedForStorage()`。
    func sanitized() -> CompressionPreset {
        CompressionPreset(id: id, name: name, options: options.sanitizedForStorage())
    }
}

extension ArchiveCreationOptions {
    /// 抹掉**不该随「默认值 / 预设」持久化**的逐次操作字段：明文密码 / 密码确认 / 显示密码 / UI 展开态 /
    /// GPG 私钥指纹 / 收件人 / 对称密码 / 给收件人的留言。保留格式 / 等级 / 方法 / 7z 全套 / 排除规则 /
    /// 更新模式 / 加密方式等所有「可复用」设置 —— 这些就是「默认值」要绝对覆盖全的通用选项。
    func sanitizedForStorage() -> ArchiveCreationOptions {
        var clean = self
        clean.password = ""
        clean.passwordConfirmation = ""
        clean.showPassword = false
        clean.showDetails = false
        clean.gpgSigningKeyFingerprint = ""
        clean.gpgRecipientFingerprints = []
        clean.gpgSymmetricPassphrase = ""
        clean.gpgDeliveryNote = ""
        return clean
    }
}

/// #115（重做）**按格式**存一份完整的默认压缩选项：每个格式（zip / 7z / rar / tar.gz …）最多一份。
/// 「默认值」= 该格式下所有可复用选项的整套配置。Finder / NSService 一键压缩按**目标格式**取其默认值；
/// 创建对话框可「套用本格式默认值」。密码 / GPG 私钥永不入库（见 `sanitizedForStorage()`）。
final class CompressionDefaultsStore {
    private let defaults: UserDefaults
    private let storageKey = "SimpleZip.CompressionDefaults.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 全部已存的「格式 → 默认选项」。损坏 / 缺失 → 空。
    func loadAll() -> [ArchiveCreateFormat: ArchiveCreationOptions] {
        guard let data = defaults.data(forKey: storageKey),
              let raw = try? JSONDecoder().decode([String: ArchiveCreationOptions].self, from: data) else { return [:] }
        var result: [ArchiveCreateFormat: ArchiveCreationOptions] = [:]
        for (key, value) in raw {
            guard let format = ArchiveCreateFormat(rawValue: key) else { continue }
            var options = value
            options.format = format
            result[format] = options
        }
        return result
    }

    /// 该格式存过的默认选项（已 sanitize）。没存过 → nil（调用方退回内建默认）。
    func options(for format: ArchiveCreateFormat) -> ArchiveCreationOptions? {
        loadAll()[format]
    }

    /// 是否给该格式配过默认值。
    func hasOptions(for format: ArchiveCreateFormat) -> Bool {
        loadAll()[format] != nil
    }

    /// 存 / 覆盖某格式的默认选项（自动 sanitize + 把 format 钉成该格式）。
    func setOptions(_ options: ArchiveCreationOptions, for format: ArchiveCreateFormat) {
        var all = loadAll()
        var clean = options.sanitizedForStorage()
        clean.format = format
        all[format] = clean
        persist(all)
    }

    /// 清掉某格式的默认值（回到内建默认）。
    func reset(for format: ArchiveCreateFormat) {
        var all = loadAll()
        all[format] = nil
        persist(all)
    }

    private func persist(_ all: [ArchiveCreateFormat: ArchiveCreationOptions]) {
        let raw = Dictionary(uniqueKeysWithValues: all.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

/// 预设的持久化仓库。UserDefaults 注入，方便测试用独立 suite。无 UI、无副作用（除写 defaults）。
final class CompressionPresetStore {
    private let defaults: UserDefaults
    private let storageKey = "SimpleZip.CompressionPresets.v1"
    /// 「默认预设」id —— Finder / NSService 一键「简化压缩」自动套用它的等级 / 方法 / 加密设置（格式仍由各入口决定）。
    private let defaultIDKey = "SimpleZip.CompressionPresets.defaultID.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 当前默认预设的 id（没设 / 已被删 → nil）。
    func defaultPresetID() -> UUID? {
        guard let raw = defaults.string(forKey: defaultIDKey), let id = UUID(uuidString: raw) else { return nil }
        // 防御：默认 id 指向的预设已被删 → 视为未设。
        return load().contains { $0.id == id } ? id : nil
    }

    /// 设 / 清默认预设。传 nil 清除；传不存在的 id 不写入（保持「默认指向真实预设」不变量）。
    func setDefaultPresetID(_ id: UUID?) {
        guard let id else {
            defaults.removeObject(forKey: defaultIDKey)
            return
        }
        guard load().contains(where: { $0.id == id }) else { return }
        defaults.set(id.uuidString, forKey: defaultIDKey)
    }

    /// 取默认预设（已 sanitized，不含密码 / GPG 私钥）。没设 / 没有预设 → nil。
    func defaultPreset() -> CompressionPreset? {
        guard let id = defaultPresetID() else { return nil }
        return load().first { $0.id == id }
    }

    /// 读出全部预设。数据缺失 / 损坏 → 返回空数组（不抛、不崩）。
    func load() -> [CompressionPreset] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([CompressionPreset].self, from: data)) ?? []
    }

    /// 覆盖写入全部预设。每条先 `sanitized()` 抹掉敏感字段 —— **绝不把明文密码 / GPG 私钥写进 defaults**。
    func save(_ presets: [CompressionPreset]) {
        let safe = presets.map { $0.sanitized() }
        guard let data = try? JSONEncoder().encode(safe) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// 追加一条（同名不去重，调用方按需校验）。返回写入后的完整列表。
    @discardableResult
    func add(_ preset: CompressionPreset) -> [CompressionPreset] {
        var all = load()
        all.append(preset.sanitized())
        save(all)
        return all
    }

    /// 按 id 原地替换；id 不存在则不动。返回写入后的完整列表。
    @discardableResult
    func update(_ preset: CompressionPreset) -> [CompressionPreset] {
        var all = load()
        guard let index = all.firstIndex(where: { $0.id == preset.id }) else { return all }
        all[index] = preset.sanitized()
        save(all)
        return all
    }

    /// 按 id 删除。返回写入后的完整列表。删的若是默认预设 → 一并清掉默认指向。
    @discardableResult
    func remove(id: UUID) -> [CompressionPreset] {
        var all = load()
        all.removeAll { $0.id == id }
        save(all)
        if defaults.string(forKey: defaultIDKey) == id.uuidString {
            defaults.removeObject(forKey: defaultIDKey)
        }
        return all
    }
}

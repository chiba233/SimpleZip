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

    /// 去掉**不该随预设持久化**的逐次操作字段：明文密码 / GPG 私钥指纹 / 收件人 / 对称密码 / 给收件人的留言 /
    /// 纯 UI 展开态。保留格式 / 等级 / 方法 / 是否签名等「可复用」设置（签名 key 仍由用户在创建时选）。
    func sanitized() -> CompressionPreset {
        var clean = options
        clean.password = ""
        clean.passwordConfirmation = ""
        clean.showPassword = false
        clean.showDetails = false
        clean.gpgSigningKeyFingerprint = ""
        clean.gpgRecipientFingerprints = []
        clean.gpgSymmetricPassphrase = ""
        clean.gpgDeliveryNote = ""
        return CompressionPreset(id: id, name: name, options: clean)
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

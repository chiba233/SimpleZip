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

    nonisolated init(id: UUID = UUID(), name: String, options: ArchiveCreationOptions) {
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

/// #115 一条可复用压缩选项 —— 预设里**可选**包含哪些。用户在编辑器里逐项勾选「启用」，只有启用的字段
/// 才会进预设、才会在创建 / 一键压缩时覆盖默认值；没勾的字段保持创建时的内建默认（「可以选择不配置某个选项」）。
enum CompressionOptionField: String, Codable, CaseIterable, Identifiable, Sendable {
    case level, updateMode, encryptionMethod
    case sevenZipMethod, dictionarySize, wordSize, threadCount, solid, solidBlockSize, pathMode
    case encryptFileNames, storeSymlinks, storeHardlinks, compressShared
    case rawParameters, skipDSStore, skipHiddenFiles, customExcludes

    public var id: String { rawValue }
}

/// 某格式的「默认值预设」：一组**被启用**的字段 + 它们的值。每个格式最多一份（id = 格式）。
struct CompressionFormatPreset: Codable, Identifiable, Equatable {
    var format: ArchiveCreateFormat
    /// 这份模板是否启用。列表里的开关绑它：关掉 → 模板还在列表但不生效（Finder / 创建对话框不套用）。
    var enabled: Bool
    /// 用户勾选「启用」的字段；只有这些会覆盖。空集 = 这个格式有预设但不覆盖任何字段（合法，等于全用默认）。
    var includedFields: Set<CompressionOptionField>
    /// 各字段的值（仅 `includedFields` 里的有意义；其它忽略）。已 sanitize（无密码 / GPG）。
    var options: ArchiveCreationOptions

    var id: String { format.rawValue }

    init(format: ArchiveCreateFormat, enabled: Bool = true, includedFields: Set<CompressionOptionField> = [], options: ArchiveCreationOptions = ArchiveCreationOptions()) {
        self.format = format
        self.enabled = enabled
        self.includedFields = includedFields
        var clean = options.sanitizedForStorage()
        clean.format = format
        self.options = clean
    }

    /// 把**已启用**的字段值覆盖到 target（其余字段不动，保留 target 的默认）。
    /// `nonisolated`:CLI companion 在非主隔离上下文套用(app target 默认 MainActor 隔离)。
    nonisolated func apply(to target: inout ArchiveCreationOptions) {
        for field in includedFields {
            switch field {
            case .level: target.compressionLevel = options.compressionLevel
            case .updateMode: target.updateMode = options.updateMode
            case .encryptionMethod: target.encryptionMethod = options.encryptionMethod
            case .sevenZipMethod: target.sevenZipMethod = options.sevenZipMethod
            case .dictionarySize: target.sevenZipDictionarySizeMB = options.sevenZipDictionarySizeMB
            case .wordSize: target.sevenZipWordSize = options.sevenZipWordSize
            case .threadCount: target.sevenZipThreadCount = options.sevenZipThreadCount
            case .solid: target.sevenZipSolidArchive = options.sevenZipSolidArchive
            case .solidBlockSize: target.sevenZipSolidBlockSize = options.sevenZipSolidBlockSize
            case .pathMode: target.sevenZipPathMode = options.sevenZipPathMode
            case .encryptFileNames: target.sevenZipEncryptFileNames = options.sevenZipEncryptFileNames
            case .storeSymlinks: target.sevenZipStoreSymbolicLinks = options.sevenZipStoreSymbolicLinks
            case .storeHardlinks: target.sevenZipStoreHardLinks = options.sevenZipStoreHardLinks
            case .compressShared: target.sevenZipCompressSharedFiles = options.sevenZipCompressSharedFiles
            case .rawParameters: target.rawParameters = options.rawParameters
            case .skipDSStore: target.skipDSStore = options.skipDSStore
            case .skipHiddenFiles: target.skipHiddenFiles = options.skipHiddenFiles
            case .customExcludes: target.customExcludes = options.customExcludes
            }
        }
    }
}

/// #115（重做）**按格式**存预设：每个格式（zip / 7z / rar / tar.gz …）最多一份 `CompressionFormatPreset`。
/// Finder / NSService 一键压缩按**目标格式**取其预设并 `apply`；创建对话框可勾选「套用本格式默认值」。
/// 密码 / GPG 私钥永不入库（见 `sanitizedForStorage()`）。
/// `nonisolated`:UserDefaults 线程安全,CLI companion 也要在非主隔离上下文读它。
nonisolated final class CompressionDefaultsStore {
    private let defaults: UserDefaults
    /// 与 `AppPreferences.Key.compressionFormatPresets` 同一个 key —— 备份导出 / 导入 / 恢复默认据此覆盖。
    private let storageKey = AppPreferences.Key.compressionFormatPresets

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 全部已存的「格式 → 预设」。损坏 / 缺失 → 空。
    func loadAll() -> [ArchiveCreateFormat: CompressionFormatPreset] {
        guard let data = defaults.data(forKey: storageKey),
              let raw = try? JSONDecoder().decode([String: CompressionFormatPreset].self, from: data) else { return [:] }
        var result: [ArchiveCreateFormat: CompressionFormatPreset] = [:]
        for (key, value) in raw {
            guard let format = ArchiveCreateFormat(rawValue: key) else { continue }
            result[format] = value
        }
        return result
    }

    /// 所有已配置的格式预设（按格式枚举顺序，方便 UI 稳定列出）。
    func allPresets() -> [CompressionFormatPreset] {
        let map = loadAll()
        return ArchiveCreateFormat.allCases.compactMap { map[$0] }
    }

    func preset(for format: ArchiveCreateFormat) -> CompressionFormatPreset? {
        loadAll()[format]
    }

    func hasPreset(for format: ArchiveCreateFormat) -> Bool {
        loadAll()[format] != nil
    }

    func save(_ preset: CompressionFormatPreset) {
        var all = loadAll()
        all[preset.format] = preset
        persist(all)
    }

    func reset(for format: ArchiveCreateFormat) {
        var all = loadAll()
        all[format] = nil
        persist(all)
    }

    private func persist(_ all: [ArchiveCreateFormat: CompressionFormatPreset]) {
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

// MARK: - 内置任务模板（0.4.2 #17）

extension CompressionPreset {
    /// 内置一键模板：常见发包场景的预拌配置。**不进 store**（永远可用、删不掉、改不坏），
    /// 套用后所有字段照常可微调。名字走 L10n（`template.<key>`）。模板**绝不带密码**。
    nonisolated static func builtInTemplates() -> [CompressionPreset] {
        [
            // 发 GitHub Release 的 ZIP：最大压缩 + 排除 macOS 垃圾和隐藏文件。
            template("githubRelease") { options in
                options.format = .zip
                options.compressionLevel = .maximum
                options.skipDSStore = true
                options.skipHiddenFiles = true
                options.customExcludes = "__MACOSX"
            },
            // 给 Windows 用户的 ZIP：排除 AppleDouble / __MACOSX，对方解开不见一地 `._*`。
            template("windowsFriendly") { options in
                options.format = .zip
                options.skipDSStore = true
                options.customExcludes = "._*, __MACOSX, Thumbs.db"
            },
            // 最大压缩 7z：体积优先（solid + maximum）。
            template("max7z") { options in
                options.format = .sevenZip
                options.compressionLevel = .maximum
                options.sevenZipSolidArchive = true
            },
            // 加密投递包：7z + 文件名加密（密码当场填，模板不存任何口令）。
            template("encryptedDelivery") { options in
                options.format = .sevenZip
                options.sevenZipEncryptFileNames = true
            },
            // 源码包：tar.gz + 排除依赖 / 构建产物目录。
            template("sourceCode") { options in
                options.format = .tarGzip
                options.skipDSStore = true
                options.customExcludes = "node_modules, .git, build, dist, target, .venv, __pycache__, DerivedData"
            },
            // 备份包：7z 快速档 + 保留符号链接 / 硬链接（忠实快照优先于压缩率）。
            template("backup") { options in
                options.format = .sevenZip
                options.compressionLevel = .fast
                options.sevenZipStoreSymbolicLinks = true
                options.sevenZipStoreHardLinks = true
            }
        ]
    }

    nonisolated private static func template(_ key: String, configure: (inout ArchiveCreationOptions) -> Void) -> CompressionPreset {
        var options = ArchiveCreationOptions()
        configure(&options)
        return CompressionPreset(name: L10n.text("template.\(key)"), options: options)
    }
}

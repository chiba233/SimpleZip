//
//  CompressionUsageStore.swift
//  SimpleZip
//
//  0.4.4 · 本地使用频率统计:记用户在创建对话框里**实际选过**的压缩选项,供「按我最常用的来」一键填默认值。
//
//  隐私(见隐私口径):只统计非加密的离散压缩旋钮(压缩率 / 更新模式 / 路径模式 / 加密文件名开关 / 跳过项 等),
//  **绝不**统计口令、GPG 任何字段、自由文本(rawParameters / customExcludes 众数无意义也不存)。全本地、不外发。
//  这是本地频率启发式(非 FoundationModels)。受「允许使用统计」开关 gate。
//

import Foundation

/// 压缩选项使用频率统计:`format.rawValue → field.rawValue → 值key → 次数`。
/// `record` 在创建对话框成功发起创建时调;`mostUsedPreset` 取每字段众数组成一个 CompressionFormatPreset。
nonisolated final class CompressionUsageStore {
    typealias Counts = [String: [String: [String: Int]]]

    private let defaults: UserDefaults
    private let storageKey = AppPreferences.Key.compressionUsageStats

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 只统计这些离散字段(与 CompressionFormatPreset.apply 同集合,但去掉自由文本 rawParameters / customExcludes)。
    /// 注意:`CompressionOptionField` 不含 password / GPG —— 敏感字段从来不在可统计集合里。
    static let trackedFields: [CompressionOptionField] = [
        .level, .updateMode, .encryptionMethod, .sevenZipMethod, .dictionarySize, .wordSize,
        .threadCount, .solid, .solidBlockSize, .pathMode, .encryptFileNames,
        .storeSymlinks, .storeHardlinks, .compressShared, .skipDSStore, .skipHiddenFiles
    ]

    /// 记一次创建实际用的选项(开关 gate 在调用点 / 这里都查一次,双保险)。
    func record(_ options: ArchiveCreationOptions) {
        guard AppPreferences.compressionUsageTrackingEnabled else { return }
        var counts = load()
        let formatKey = options.format.rawValue
        for field in Self.trackedFields {
            guard let valueKey = Self.valueKey(field, options) else { continue }
            counts[formatKey, default: [:]][field.rawValue, default: [:]][valueKey, default: 0] += 1
        }
        persist(counts)
    }

    /// 该格式「最常用」的预设:每个有数据的字段取众数;一个字段都没有则返回 nil(没数据可推荐)。
    func mostUsedPreset(for format: ArchiveCreateFormat) -> CompressionFormatPreset? {
        let counts = load()
        guard let perField = counts[format.rawValue], !perField.isEmpty else { return nil }
        var options = ArchiveCreationOptions()
        options.format = format
        var included: Set<CompressionOptionField> = []
        for field in Self.trackedFields {
            guard let valueCounts = perField[field.rawValue], !valueCounts.isEmpty else { continue }
            // 众数;平票时取值 key 较小者,保证确定性。
            guard let modeKey = valueCounts.max(by: { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
            })?.key else { continue }
            Self.applyValueKey(field, modeKey, to: &options)
            included.insert(field)
        }
        guard !included.isEmpty else { return nil }
        return CompressionFormatPreset(format: format, includedFields: included, options: options)
    }

    /// 是否有该格式的统计数据(调用点据此决定「按我最常用的来」按钮是否出现)。
    func hasData(for format: ArchiveCreateFormat) -> Bool {
        guard let perField = load()[format.rawValue] else { return false }
        return perField.values.contains { !$0.isEmpty }
    }

    /// 清空全部统计(设置里「清除使用数据」用)。
    func clear() {
        defaults.removeObject(forKey: storageKey)
    }

    // MARK: - 字段 ↔ 值key

    /// 离散字段取一个稳定的字符串值 key(自由文本字段返回 nil 不统计)。
    static func valueKey(_ field: CompressionOptionField, _ o: ArchiveCreationOptions) -> String? {
        switch field {
        case .level: return String(o.compressionLevel.rawValue)
        case .updateMode: return o.updateMode.rawValue
        case .encryptionMethod: return o.encryptionMethod.rawValue
        case .sevenZipMethod: return o.sevenZipMethod.rawValue
        case .dictionarySize: return String(o.sevenZipDictionarySizeMB)
        case .wordSize: return String(o.sevenZipWordSize)
        case .threadCount: return String(o.sevenZipThreadCount)
        case .solid: return o.sevenZipSolidArchive ? "1" : "0"
        case .solidBlockSize: return o.sevenZipSolidBlockSize.rawValue
        case .pathMode: return o.sevenZipPathMode.rawValue
        case .encryptFileNames: return o.sevenZipEncryptFileNames ? "1" : "0"
        case .storeSymlinks: return o.sevenZipStoreSymbolicLinks ? "1" : "0"
        case .storeHardlinks: return o.sevenZipStoreHardLinks ? "1" : "0"
        case .compressShared: return o.sevenZipCompressSharedFiles ? "1" : "0"
        case .skipDSStore: return o.skipDSStore ? "1" : "0"
        case .skipHiddenFiles: return o.skipHiddenFiles ? "1" : "0"
        case .rawParameters, .customExcludes: return nil
        }
    }

    /// 把众数值 key 写回选项(解析失败则保持默认,不崩)。
    static func applyValueKey(_ field: CompressionOptionField, _ key: String, to o: inout ArchiveCreationOptions) {
        switch field {
        case .level: if let raw = Int(key), let value = CompressionLevel(rawValue: raw) { o.compressionLevel = value }
        case .updateMode: if let value = ArchiveUpdateMode(rawValue: key) { o.updateMode = value }
        case .encryptionMethod: if let value = ArchiveEncryptionMethod(rawValue: key) { o.encryptionMethod = value }
        case .sevenZipMethod: if let value = SevenZipCompressionMethod(rawValue: key) { o.sevenZipMethod = value }
        case .dictionarySize: if let raw = Int(key) { o.sevenZipDictionarySizeMB = raw }
        case .wordSize: if let raw = Int(key) { o.sevenZipWordSize = raw }
        case .threadCount: if let raw = Int(key) { o.sevenZipThreadCount = raw }
        case .solid: o.sevenZipSolidArchive = (key == "1")
        case .solidBlockSize: if let value = SevenZipSolidBlockSize(rawValue: key) { o.sevenZipSolidBlockSize = value }
        case .pathMode: if let value = SevenZipPathMode(rawValue: key) { o.sevenZipPathMode = value }
        case .encryptFileNames: o.sevenZipEncryptFileNames = (key == "1")
        case .storeSymlinks: o.sevenZipStoreSymbolicLinks = (key == "1")
        case .storeHardlinks: o.sevenZipStoreHardLinks = (key == "1")
        case .compressShared: o.sevenZipCompressSharedFiles = (key == "1")
        case .skipDSStore: o.skipDSStore = (key == "1")
        case .skipHiddenFiles: o.skipHiddenFiles = (key == "1")
        case .rawParameters, .customExcludes: break
        }
    }

    // MARK: - 持久化

    private func load() -> Counts {
        guard let data = defaults.data(forKey: storageKey),
              let counts = try? JSONDecoder().decode(Counts.self, from: data) else { return [:] }
        return counts
    }

    private func persist(_ counts: Counts) {
        guard let data = try? JSONEncoder().encode(counts) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

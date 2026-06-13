//
//  ExtractionUsageStore.swift
//  SimpleZip
//
//  0.4.4 #71 · 本地解压习惯统计:记用户在解压对话框里**实际选过**的行为开关,供「用你常用的设置」一键填。
//
//  隐私(见隐私口径):只统计 6 个非敏感的行为开关(跳过垃圾 / 符号链接、解到同名子文件夹、冲突自动重命名、
//  完成后在 Finder 显示 / 移到废纸篓)。**绝不**统计口令、GPG 任何字段、解压目标路径(每次都不同、不是习惯)。
//  也不统计「去单层壳」—— 它是按归档结构条件出现的上下文开关,不算全局习惯。全本地、不外发。
//  这是本地频率启发式(非 FoundationModels),受「记录解压习惯」开关 gate。与 CompressionUsageStore 同款架构。
//

import Foundation

/// 可统计的解压行为开关(全是布尔;敏感字段从不在此集合)。
nonisolated enum ExtractionOptionField: String, CaseIterable {
    case skipJunk, skipSymlinks, extractIntoSubfolder, autoRenameConflicts, revealWhenDone, trashOriginalWhenDone
}

/// 一份「你常用的」解压行为推荐(每个有数据的字段取众数)。套用时只改这些字段,目标 / 密码 / GPG / 去壳一律不碰。
/// `nonisolated`:要在 `ExtractionUsageStore`(nonisolated)的 record 里同步调 currentValue;否则 app target
/// 默认 MainActor 隔离会把它锁到主线程。View(MainActor)依旧能调 apply/wouldChange。
nonisolated struct ExtractionUsageRecommendation: Equatable {
    var values: [ExtractionOptionField: Bool]

    /// 当前请求里某个字段的实际布尔值(用于「套用会改变什么」判断与套用)。
    static func currentValue(_ field: ExtractionOptionField, _ r: ExtractArchiveRequest) -> Bool {
        switch field {
        case .skipJunk: return r.skipJunk
        case .skipSymlinks: return r.skipSymlinks
        case .extractIntoSubfolder: return r.extractIntoSubfolder
        case .autoRenameConflicts: return r.autoRenameConflicts
        case .revealWhenDone: return r.revealWhenDone
        case .trashOriginalWhenDone: return r.trashOriginalWhenDone
        }
    }

    /// 套用推荐到一个解压请求(只改有推荐的字段)。
    func apply(to request: inout ExtractArchiveRequest) {
        for (field, value) in values {
            switch field {
            case .skipJunk: request.skipJunk = value
            case .skipSymlinks: request.skipSymlinks = value
            case .extractIntoSubfolder: request.extractIntoSubfolder = value
            case .autoRenameConflicts: request.autoRenameConflicts = value
            case .revealWhenDone: request.revealWhenDone = value
            case .trashOriginalWhenDone: request.trashOriginalWhenDone = value
            }
        }
    }

    /// 套用是否会改变当前请求(全部相同则没必要露出按钮)。
    func wouldChange(_ request: ExtractArchiveRequest) -> Bool {
        values.contains { field, value in Self.currentValue(field, request) != value }
    }
}

/// 解压行为使用频率统计:`field.rawValue → "0"/"1" → 次数`。
/// `record` 在用户**确认解压对话框**时调(自动解压等默认选项路径绝不记,避免偏向默认);`mostUsed` 取众数。
nonisolated final class ExtractionUsageStore {
    typealias Counts = [String: [String: Int]]

    private let defaults: UserDefaults
    private let storageKey = AppPreferences.Key.extractionUsageStats

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 记一次解压对话框实际确认的行为开关(开关 gate 在调用点 / 这里都查一次,双保险)。
    func record(_ request: ExtractArchiveRequest) {
        guard AppPreferences.extractionUsageTrackingEnabled else { return }
        var counts = load()
        for field in ExtractionOptionField.allCases {
            let key = ExtractionUsageRecommendation.currentValue(field, request) ? "1" : "0"
            counts[field.rawValue, default: [:]][key, default: 0] += 1
        }
        persist(counts)
    }

    /// 每个有数据的字段取众数(平票偏向 false=更保守);一个字段都没有则返回 nil(没数据可推荐)。
    func mostUsed() -> ExtractionUsageRecommendation? {
        let counts = load()
        guard !counts.isEmpty else { return nil }
        var values: [ExtractionOptionField: Bool] = [:]
        for field in ExtractionOptionField.allCases {
            guard let valueCounts = counts[field.rawValue], !valueCounts.isEmpty else { continue }
            let trueCount = valueCounts["1"] ?? 0
            let falseCount = valueCounts["0"] ?? 0
            values[field] = trueCount > falseCount   // 平票(含 trueCount==falseCount)取 false
        }
        guard !values.isEmpty else { return nil }
        return ExtractionUsageRecommendation(values: values)
    }

    /// 是否有任何统计数据(调用点据此决定按钮是否出现)。
    func hasData() -> Bool {
        load().values.contains { !$0.isEmpty }
    }

    /// 清空全部统计。
    func clear() {
        defaults.removeObject(forKey: storageKey)
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

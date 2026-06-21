//
//  AIDerivedCaches.swift
//  SimpleZip
//
//  AI 后台预烘焙的**派生缓存值类型**(原定义在 App 的 AIBackgroundIndexStore;下沉 Core 供 App 前台 + 后台 agent
//  共用 —— agent 迁入完整烘焙后也要按同一布局写这些缓存)。纯 Codable 值类型,落 AIDerivedDataStore。
//

import Foundation

/// 文件夹「成组建议」/「整理进新文件夹」一组:成员路径 + 批量动作 token(+ 整理建议的新文件夹名 title)。
nonisolated struct CachedFolderGroup: Codable, Equatable, Sendable {
    let title: String?
    let memberPaths: [String]
    let actionToken: String

    init(title: String?, memberPaths: [String], actionToken: String) {
        self.title = title
        self.memberPaths = memberPaths
        self.actionToken = actionToken
    }
}

/// 建议六 v2 模块⑤:活动中心「建议筛选」chip 的模型排序缓存(每个任务分类一条)。`fingerprint` = 当时 chip 池的指纹
/// (chip id + 匹配数);前台只在指纹匹配当前 chip 池时套用 `orderedIDs`(否则退确定性顺序),保证幂等、不烤旧的。
nonisolated struct CachedChipRanking: Codable, Equatable, Sendable {
    let fingerprint: String
    let orderedIDs: [String]

    init(fingerprint: String, orderedIDs: [String]) {
        self.fingerprint = fingerprint
        self.orderedIDs = orderedIDs
    }
}

/// 建议六 v2 模块1「需要处理」AI 解读 + 模块①「失败解释」的后台预烘焙缓存。`fingerprint` = 当时输入事实的指纹
/// (模块1 = 未读失败任务 id 集;模块① = 该失败任务的脱敏诊断);前台只在指纹匹配当前输入时套用 `text`,否则退回
/// 确定性文案 → 保证幂等、不显示旧任务的解读。`text` = 端上模型用界面语言写的一小段(模型不可用 / 失败 → 不写,前台自然退确定性)。
nonisolated struct CachedExplanation: Codable, Equatable, Sendable {
    let fingerprint: String
    let text: String

    init(fingerprint: String, text: String) {
        self.fingerprint = fingerprint
        self.text = text
    }
}

/// 建议六 v2「真建议」chip:模型在 App 确定性发现的**真实聚集**上择优+命名的产物。`displayName` = 模型起的
/// 自然语言名;`filter` = 点它要应用的安全 filter(App 确定性匹配);后台预烘焙、幂等、前台只读。
nonisolated struct CachedClusterChip: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let filter: ActivityAIWorkbenchFilterSpec
    let matchCount: Int

    init(id: String, displayName: String, filter: ActivityAIWorkbenchFilterSpec, matchCount: Int) {
        self.id = id
        self.displayName = displayName
        self.filter = filter
        self.matchCount = matchCount
    }
}

nonisolated struct CachedClusterChips: Codable, Equatable, Sendable {
    let fingerprint: String
    let chips: [CachedClusterChip]

    init(fingerprint: String, chips: [CachedClusterChip]) {
        self.fingerprint = fingerprint
        self.chips = chips
    }
}

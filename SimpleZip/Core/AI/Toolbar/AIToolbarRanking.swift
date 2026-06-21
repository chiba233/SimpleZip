//
//  AIToolbarRanking.swift
//  SimpleZip
//
//  0.4.5 #80 建议七 Phase2:工具栏动作的**AI 预烘焙排序缓存**(后台 agent 写、前台只读)。
//
//  颗粒度(用户拍板):**文件级** `byFile`(path → 有序动作 id)只覆盖 AI suggestion list 里「重要」的文件
//  (复用现有注意力机制,不另跑重要性判定);**类型级** `byType`(扩展名 → 有序动作 id)覆盖其余按后缀。
//  渲染:AI 开 + 单选 → 选中文件命中 byFile 用之、否则用其扩展名 byType;叠进 `AINextActionRanker`(习惯当权重)。
//  AI 关 → 不用此缓存(纯习惯排序)。复选 → 不查(走统一池,见 ToolbarActionUsageStore 桶粒度)。
//
//  动作 id 都是 `ContextualToolbarAction.ID.rawValue`(稳定英文 token);渲染前由 ranker 在候选池内校验,
//  缓存里的陌生 id 自然被忽略(白名单兜底)。纯值 + Codable,落 AIDerivedDataStore。
//

import Foundation

nonisolated struct AIToolbarRanking: Codable, Equatable, Sendable {
    /// path → 有序动作 id(文件级;只 AI suggestion list 里的重要文件)。
    var byFile: [String: [String]]
    /// 扩展名(小写,无点)→ 有序动作 id(类型级;其余文件按后缀)。
    var byType: [String: [String]]

    init(byFile: [String: [String]] = [:], byType: [String: [String]] = [:]) {
        self.byFile = byFile
        self.byType = byType
    }

    /// AIDerivedDataStore 里的 key(派生数据,不进偏好备份)。
    static let derivedKey = "SimpleZip.ai.toolbarRanking.v1"

    /// 单选文件的烘焙序:命中文件级优先,否则用扩展名类型级,都没有 → nil(渲染退回纯习惯排序)。
    func order(forPath path: String, pathExtension ext: String) -> [String]? {
        if let f = byFile[path], !f.isEmpty { return f }
        let e = ext.lowercased()
        if let t = byType[e], !t.isEmpty { return t }
        return nil
    }
}

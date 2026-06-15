//
//  AISelectionQuery.swift
//  SimpleZip
//
//  0.4.5 #80:AI 自然语言选择器(白皮书 Feat 14)。用户常想的不是「搜文件名」,而是「选中这批东西」
//  (如「选中所有像发布产物但还没测试过的包」)。模型**不返回路径**,只把一句话改写成结构化 selection query;
//  App 用本地索引执行 query、高亮结果或进入虚拟文件夹。
//
//  安全:`semanticTags` 经 `AISemanticTag` 受控词表过滤(模型不能发明标签);空 query 选中**零**项(绝不「全选」);
//  执行只看条目的低敏属性(扩展名 / 标签 / 任务状态),不读条目内容。纯值 + 确定性执行器,SwiftPM 可断言。
//

import Foundation

/// 选择时的任务状态过滤(稳定英文 token)。
nonisolated enum AISelectionTaskState: String, Codable, CaseIterable, Equatable, Sendable {
    case any
    case untested
    case noSuccessfulTest = "no-successful-test"
    case testedOk = "tested-ok"
    case testFailed = "test-failed"
}

/// 选择后的动作(稳定英文 token)。都不破坏数据 —— 只改 UI 选择 / 视图。
nonisolated enum AISelectionAction: String, Codable, CaseIterable, Equatable, Sendable {
    case highlight
    case showOnly = "show-only"
    case openVirtualFolder = "open-virtual-folder"
}

/// 结构化选择查询。模型产出后必须过 `normalized(...)`(过滤受控标签、小写扩展名、去重)。
nonisolated struct AISelectionQuery: Codable, Equatable, Sendable {
    var semanticTags: [String]
    var extensions: [String]
    var keywords: [String]
    var taskState: AISelectionTaskState
    var actionAfterSelection: AISelectionAction

    init(semanticTags: [String] = [], extensions: [String] = [], keywords: [String] = [],
         taskState: AISelectionTaskState = .any, actionAfterSelection: AISelectionAction = .highlight) {
        self.semanticTags = semanticTags
        self.extensions = extensions
        self.keywords = keywords
        self.taskState = taskState
        self.actionAfterSelection = actionAfterSelection
    }

    /// 所有过滤维度都空 —— 调用点据此显示「没有可选的」而非误「全选」。
    var isEmpty: Bool {
        semanticTags.isEmpty && extensions.isEmpty && keywords.isEmpty && taskState == .any
    }

    /// 归一化模型输出:`semanticTags` 只留 `AISemanticTag` 受控词表内的;扩展名 / 关键词小写去重。
    func normalized() -> AISelectionQuery {
        AISelectionQuery(
            semanticTags: Self.dedup(semanticTags.filter { AISemanticTag(token: $0) != nil }),
            extensions: Self.dedup(extensions.map { $0.lowercased() }.filter { !$0.isEmpty }),
            keywords: Self.dedup(keywords.map { $0.lowercased() }.filter { !$0.isEmpty }),
            taskState: taskState, actionAfterSelection: actionAfterSelection)
    }

    private static func dedup(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for x in xs where seen.insert(x).inserted { out.append(x) }
        return out
    }
}

/// 执行选择查询的候选条目(低敏属性;App 从已索引数据填充,不含条目内容)。
nonisolated struct AISelectionCandidate: Codable, Equatable, Sendable {
    let id: String
    let fileExtension: String?
    let nameTokens: [String]
    let semanticTags: [String]
    let taskState: AISelectionTaskState

    init(id: String, fileExtension: String? = nil, nameTokens: [String] = [],
         semanticTags: [String] = [], taskState: AISelectionTaskState = .any) {
        self.id = id
        self.fileExtension = fileExtension
        self.nameTokens = nameTokens
        self.semanticTags = semanticTags
        self.taskState = taskState
    }
}

/// 确定性选择执行器。非空过滤维度按 AND 组合;空 query 选中零项。
nonisolated enum AISelectionQueryExecutor {
    static func matches(_ c: AISelectionCandidate, _ q: AISelectionQuery) -> Bool {
        if q.isEmpty { return false }
        if !q.semanticTags.isEmpty, Set(q.semanticTags).isDisjoint(with: Set(c.semanticTags)) { return false }
        if !q.extensions.isEmpty {
            guard let ext = c.fileExtension?.lowercased(), q.extensions.contains(ext) else { return false }
        }
        if !q.keywords.isEmpty {
            let hay = c.nameTokens.map { $0.lowercased() }
            let hit = q.keywords.contains { kw in hay.contains { $0.contains(kw) } }
            if !hit { return false }
        }
        if q.taskState != .any, c.taskState != q.taskState { return false }
        return true
    }

    /// 返回命中的候选(保持输入顺序,稳定)。
    static func select(_ candidates: [AISelectionCandidate], with query: AISelectionQuery) -> [AISelectionCandidate] {
        let q = query.normalized()
        guard !q.isEmpty else { return [] }
        return candidates.filter { matches($0, q) }
    }
}

//
//  AIWorkspaceCandidate.swift
//  SimpleZip
//
//  0.4.5 #80:AI 工作区候选池模型(白皮书工程补充七)。后台预读 / 预索引得到的文件夹画像、普通文件记录、
//  归档画像、归档内条目、活动任务、报告都汇进**同一个候选池**:主题候选 + 虚拟节点候选。AI 工作区不是
//  只读活动中心,也不是只读归档缓存,而是读「本机工作空间图谱」。
//
//  分工:App 从预索引数据**确定性生成候选**并打分,模型只负责给主题命名 / 排序 / 写分组标题。这里给:
//  ① 两个候选值类型;② 主题候选确定性排序(按命中信号数);③ 虚拟节点候选 → `AIVirtualNode`(确定性 UUID,
//  可复现)。纯值 + 确定性,SwiftPM 可断言。
//

import Foundation

/// 一个推荐工作区主题的候选。App 从预索引信号生成,模型只命名 / 排序。
nonisolated struct AIWorkspaceThemeCandidate: Codable, Equatable, Sendable {
    let id: String
    /// 给模型起名的种子(英文短语)。
    let titleSeed: String
    let themeTokens: [String]
    let sourceRefs: [AIContextSourceRef]
    /// 命中的评分信号(folderRole=release / marker=SHA256SUMS / archiveRole=release-package …)。
    let scoreSignals: [String]
    let evidence: [AIEvidenceFact]

    init(id: String, titleSeed: String, themeTokens: [String] = [], sourceRefs: [AIContextSourceRef] = [],
         scoreSignals: [String] = [], evidence: [AIEvidenceFact] = []) {
        self.id = id
        self.titleSeed = titleSeed
        self.themeTokens = themeTokens
        self.sourceRefs = sourceRefs
        self.scoreSignals = scoreSignals
        self.evidence = evidence
    }
}

/// 一个虚拟树节点的候选。混合来源:普通文件 / 文件夹 / 归档 / 归档内条目 / 任务 / 报告 / 动作。
nonisolated struct AIVirtualNodeCandidate: Codable, Equatable, Sendable {
    let id: String
    let kind: AIVirtualNode.Kind
    let displayName: String
    let sourceRefs: [AIContextSourceRef]
    let roleTags: [String]
    let location: AILocationContext?
    let relatedTaskIDs: [String]
    let relatedArchiveIDs: [String]
    let scoreSignals: [String]
    let evidence: [AIEvidenceFact]

    init(id: String, kind: AIVirtualNode.Kind, displayName: String,
         sourceRefs: [AIContextSourceRef] = [], roleTags: [String] = [],
         location: AILocationContext? = nil, relatedTaskIDs: [String] = [],
         relatedArchiveIDs: [String] = [], scoreSignals: [String] = [], evidence: [AIEvidenceFact] = []) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.sourceRefs = sourceRefs
        self.roleTags = roleTags
        self.location = location
        self.relatedTaskIDs = relatedTaskIDs
        self.relatedArchiveIDs = relatedArchiveIDs
        self.scoreSignals = scoreSignals
        self.evidence = evidence
    }

    /// 落成一个虚拟树叶子节点。节点 id 由候选 id 确定性派生(可复现),理由取命中信号。
    /// `primaryAction` 不在此层赋值 —— 由调用点按 kind + source ref 安全推导(模型不发明路径)。
    func toNode() -> AIVirtualNode {
        AIVirtualNode(
            id: AIStableHash.deterministicUUID(id),
            kind: kind,
            title: displayName,
            reason: scoreSignals.isEmpty ? nil : scoreSignals.joined(separator: ", "),
            sourceRefs: sourceRefs)
    }
}

nonisolated enum AIWorkspaceCandidateRanker {
    /// 主题候选确定性排序:命中信号越多越强,同分按 id 稳定升序。
    static func rankThemes(_ candidates: [AIWorkspaceThemeCandidate]) -> [AIWorkspaceThemeCandidate] {
        candidates.sorted {
            $0.scoreSignals.count != $1.scoreSignals.count
                ? $0.scoreSignals.count > $1.scoreSignals.count
                : $0.id < $1.id
        }
    }

    /// 节点候选确定性排序(同主题分组内):命中信号数降序,同分按 displayName 再按 id。
    static func rankNodes(_ candidates: [AIVirtualNodeCandidate]) -> [AIVirtualNodeCandidate] {
        candidates.sorted {
            if $0.scoreSignals.count != $1.scoreSignals.count { return $0.scoreSignals.count > $1.scoreSignals.count }
            if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
            return $0.id < $1.id
        }
    }
}

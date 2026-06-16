//
//  AINodeFeedback.swift
//  SimpleZip
//
//  0.4.5 #80 #89:AI 文件夹**节点级反馈账本**(白皮书建议四:文件夹动态加入 AI 觉得可能需要的文件,
//  用户可右键「我很喜欢 / 我不喜欢」训练边界)。
//
//  语义:
//    - AI 文件夹里的每个成员默认是**AI 建议**(UI 打 AI 角标);
//    - 「我很喜欢」(like)= 确认保留 → 不再是待定建议(去角标),正反馈;
//    - 「我不喜欢」(dislike)= 移出文件夹 + 不再自动加入(负反馈);下一轮发现把该 ref 从成员里剔掉。
//
//  账本按**工作区 × source ref** 记,纯值 + 确定性,SwiftPM 可断言。只存已脱敏的 source ref(kind + 派生 id),
//  绝不含路径 / 内容。like / dislike 互斥(标一个自动清掉另一个)。
//

import Foundation

nonisolated struct AINodeFeedbackLedger: Codable, Equatable, Sendable {
    /// workspace id → 喜欢的成员 ref。
    private var liked: [UUID: Set<AIContextSourceRef>]
    /// workspace id → 不喜欢(已移出)的成员 ref。
    private var disliked: [UUID: Set<AIContextSourceRef>]

    init(liked: [UUID: Set<AIContextSourceRef>] = [:], disliked: [UUID: Set<AIContextSourceRef>] = [:]) {
        self.liked = liked
        self.disliked = disliked
    }

    // MARK: - 查询

    func isLiked(_ workspace: UUID, _ ref: AIContextSourceRef) -> Bool {
        liked[workspace]?.contains(ref) ?? false
    }

    func isDisliked(_ workspace: UUID, _ ref: AIContextSourceRef) -> Bool {
        disliked[workspace]?.contains(ref) ?? false
    }

    /// 某工作区被移出(不喜欢)的成员 ref 集合 —— 发现 / 建树时据此剔除。
    func dislikedRefs(_ workspace: UUID) -> Set<AIContextSourceRef> { disliked[workspace] ?? [] }

    /// 一个节点是否「已被喜欢确认」(它的任一 ref 被 like)—— UI 据此决定是否还打 AI 建议角标。
    func nodeIsLiked(_ workspace: UUID, refs: [AIContextSourceRef]) -> Bool {
        guard let set = liked[workspace], !set.isEmpty else { return false }
        return refs.contains { set.contains($0) }
    }

    /// 一个节点是否被移出(任一 ref 被 dislike)—— 防御性:正常情况下被移出的节点已不在树里。
    func nodeIsDisliked(_ workspace: UUID, refs: [AIContextSourceRef]) -> Bool {
        guard let set = disliked[workspace], !set.isEmpty else { return false }
        return refs.contains { set.contains($0) }
    }

    // MARK: - 变换(纯值,返回新账本)

    /// 标「我很喜欢」:加入 liked,并从 disliked 移除(互斥)。
    func liking(_ workspace: UUID, _ refs: [AIContextSourceRef]) -> AINodeFeedbackLedger {
        mutate(workspace, refs, addTo: \.liked, removeFrom: \.disliked)
    }

    /// 标「我不喜欢」:加入 disliked(下一轮剔除),并从 liked 移除(互斥)。
    func disliking(_ workspace: UUID, _ refs: [AIContextSourceRef]) -> AINodeFeedbackLedger {
        mutate(workspace, refs, addTo: \.disliked, removeFrom: \.liked)
    }

    /// 清掉这些 ref 的所有反馈(撤销喜欢 / 不喜欢)。
    func clearing(_ workspace: UUID, _ refs: [AIContextSourceRef]) -> AINodeFeedbackLedger {
        guard !refs.isEmpty else { return self }
        var copy = self
        copy.remove(refs, from: workspace, in: \.liked)
        copy.remove(refs, from: workspace, in: \.disliked)
        return copy
    }

    /// 删一个工作区的全部反馈(工作区被删 / 标长期时清理)。
    func clearingWorkspace(_ workspace: UUID) -> AINodeFeedbackLedger {
        guard liked[workspace] != nil || disliked[workspace] != nil else { return self }
        var copy = self
        copy.liked[workspace] = nil
        copy.disliked[workspace] = nil
        return copy
    }

    // MARK: - 内部

    private func mutate(_ workspace: UUID, _ refs: [AIContextSourceRef],
                        addTo add: WritableKeyPath<AINodeFeedbackLedger, [UUID: Set<AIContextSourceRef>]>,
                        removeFrom remove: WritableKeyPath<AINodeFeedbackLedger, [UUID: Set<AIContextSourceRef>]>)
        -> AINodeFeedbackLedger {
        guard !refs.isEmpty else { return self }
        var copy = self
        copy[keyPath: add][workspace, default: []].formUnion(refs)
        copy.remove(refs, from: workspace, in: remove)
        return copy
    }

    private mutating func remove(_ refs: [AIContextSourceRef], from workspace: UUID,
                                 in keyPath: WritableKeyPath<AINodeFeedbackLedger, [UUID: Set<AIContextSourceRef>]>) {
        guard var set = self[keyPath: keyPath][workspace] else { return }
        set.subtract(refs)
        self[keyPath: keyPath][workspace] = set.isEmpty ? nil : set
    }
}

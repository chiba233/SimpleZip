//
//  AIWorkspaceStructureEdits.swift
//  SimpleZip
//
//  0.4.5 #80 #89:AI 工作区**虚拟结构的用户编辑层**(白皮书建议四:虚拟文件夹可改名、可把成员移到别的分组)。
//
//  虚拟树本身是确定性派生(每会话重建),用户的「改名 / 移动」不能丢 → 存成**覆盖层**,在派生完成后套用:
//   - `groupTitles`:分组节点 id → 用户改的标题(派生分组保留自己的 id,据此回贴)。
//   - `nodeAssignments`:成员 source ref → 目标分组节点 id(把该成员移进那个分组)。
//
//  只动**虚拟结构**,绝不碰硬盘文件。纯值 + 确定性,套用是纯函数(`AIVirtualFolderTree.applyingStructureEdits`),
//  SwiftPM 可断言。覆盖指向的分组 / 成员若已不存在(树变了),静默忽略(优雅降级,不报错不崩)。
//

import Foundation

nonisolated struct AIWorkspaceStructureEdits: Codable, Equatable, Sendable {
    /// workspace id → (分组节点 id → 用户标题)。
    private var groupTitles: [UUID: [UUID: String]]
    /// workspace id → (成员 source ref → 目标分组节点 id)。
    private var nodeAssignments: [UUID: [AIContextSourceRef: UUID]]

    init(groupTitles: [UUID: [UUID: String]] = [:],
         nodeAssignments: [UUID: [AIContextSourceRef: UUID]] = [:]) {
        self.groupTitles = groupTitles
        self.nodeAssignments = nodeAssignments
    }

    // MARK: - 查询

    func groupTitle(_ workspace: UUID, _ group: UUID) -> String? { groupTitles[workspace]?[group] }
    func groupTitles(_ workspace: UUID) -> [UUID: String] { groupTitles[workspace] ?? [:] }
    func assignments(_ workspace: UUID) -> [AIContextSourceRef: UUID] { nodeAssignments[workspace] ?? [:] }
    var isEmpty: Bool { groupTitles.isEmpty && nodeAssignments.isEmpty }

    // MARK: - 变换(纯值,返回新覆盖层)

    /// 给一个分组节点起用户标题(空白 → 清除覆盖,回到派生标题)。
    func renamingGroup(_ workspace: UUID, _ group: UUID, to title: String?) -> AIWorkspaceStructureEdits {
        var copy = self
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = trimmed, !t.isEmpty {
            copy.groupTitles[workspace, default: [:]][group] = t
        } else {
            copy.groupTitles[workspace]?[group] = nil
            if copy.groupTitles[workspace]?.isEmpty == true { copy.groupTitles[workspace] = nil }
        }
        return copy
    }

    /// 把一组成员(source ref)移进目标分组节点。
    func assigning(_ workspace: UUID, _ refs: [AIContextSourceRef], toGroup group: UUID) -> AIWorkspaceStructureEdits {
        guard !refs.isEmpty else { return self }
        var copy = self
        for ref in refs { copy.nodeAssignments[workspace, default: [:]][ref] = group }
        return copy
    }

    /// 删一个工作区的全部结构编辑(工作区被删 / 重置时)。
    func clearingWorkspace(_ workspace: UUID) -> AIWorkspaceStructureEdits {
        guard groupTitles[workspace] != nil || nodeAssignments[workspace] != nil else { return self }
        var copy = self
        copy.groupTitles[workspace] = nil
        copy.nodeAssignments[workspace] = nil
        return copy
    }
}

extension AIVirtualFolderTree {
    /// 套用用户结构编辑(改名 + 移动),返回新树。先按 ref 把成员移进目标分组,再回贴分组标题;移动后变空的
    /// **派生**分组丢弃(用户改过名的分组保留,哪怕空了 —— 那是用户刻意建的容器)。目标分组不存在的移动忽略。
    func applyingStructureEdits(groupTitles: [UUID: String],
                                assignments: [AIContextSourceRef: UUID]) -> AIVirtualFolderTree {
        guard !groupTitles.isEmpty || !assignments.isEmpty else { return self }

        // 目标分组必须真实存在(防移到幽灵分组)。
        var groupIDs = Set<UUID>()
        func collectGroups(_ ns: [AIVirtualNode]) {
            for n in ns where n.kind == .group { groupIDs.insert(n.id); collectGroups(n.children) }
        }
        collectGroups(nodes)
        let validAssignments = assignments.filter { groupIDs.contains($0.value) }

        var movedNodes: [UUID: [AIVirtualNode]] = [:]   // 目标分组 id → 被移入的节点
        // 1. 摘出被分配走的成员(叶子指针节点;按首个 source ref 判定)。
        func strip(_ ns: [AIVirtualNode]) -> [AIVirtualNode] {
            ns.compactMap { node in
                if node.kind == .group {
                    return node.replacingChildren(strip(node.children))
                }
                if let ref = node.sourceRefs.first, let target = validAssignments[ref], target != node.id {
                    movedNodes[target, default: []].append(node)
                    return nil   // 从原位摘掉
                }
                return node
            }
        }
        let stripped = strip(nodes)

        // 2. 把摘出的成员塞进目标分组(去重),并回贴分组标题;空了的派生分组丢弃。
        func rebuild(_ ns: [AIVirtualNode]) -> [AIVirtualNode] {
            ns.compactMap { node -> AIVirtualNode? in
                guard node.kind == .group else { return node }
                var children = rebuild(node.children)
                if let incoming = movedNodes[node.id] {
                    let existing = Set(children.map(\.id))
                    children.append(contentsOf: incoming.filter { !existing.contains($0.id) })
                }
                let renamed = groupTitles[node.id]
                // 用户改过名的分组即便空了也保留(刻意的容器);纯派生分组空了则丢弃。
                if children.isEmpty && renamed == nil { return nil }
                let titled = renamed.map { node.withTitle($0) } ?? node
                return titled.replacingChildren(children)
            }
        }
        let newNodes = rebuild(stripped)
        return AIVirtualFolderTree(id: id, workspaceID: workspaceID, title: title, prompt: prompt,
                                   generatedAt: generatedAt, generationMode: generationMode,
                                   nodes: newNodes, sourceRefs: sourceRefs, omissions: omissions)
    }
}

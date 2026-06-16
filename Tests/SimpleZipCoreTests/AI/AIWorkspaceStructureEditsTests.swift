//
//  AIWorkspaceStructureEditsTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80 #89:虚拟结构用户编辑(改名 + 移动)的覆盖层 + 套用纯函数。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIWorkspaceStructureEditsTests {
    private let ws = UUID()
    private func ref(_ id: String) -> AIContextSourceRef { AIContextSourceRef(kind: .file, id: id) }

    private func fileNode(_ name: String, _ refID: String) -> AIVirtualNode {
        AIVirtualNode(id: UUID(), kind: .file, title: name, sourceRefs: [ref(refID)])
    }
    private func group(_ id: UUID, _ title: String, _ children: [AIVirtualNode]) -> AIVirtualNode {
        AIVirtualNode(id: id, kind: .group, title: title, children: children)
    }

    @Test func renamingAndAssigningRoundTrips() {
        var edits = AIWorkspaceStructureEdits()
        let g = UUID()
        edits = edits.renamingGroup(ws, g, to: "  My Folder  ")
        edits = edits.assigning(ws, [ref("a"), ref("b")], toGroup: g)
        #expect(edits.groupTitle(ws, g) == "My Folder")   // 去空白
        #expect(edits.assignments(ws)[ref("a")] == g)
        // 空白改名 → 清除覆盖。
        edits = edits.renamingGroup(ws, g, to: "   ")
        #expect(edits.groupTitle(ws, g) == nil)
    }

    @Test func clearingWorkspaceWipesAll() {
        let g = UUID()
        var edits = AIWorkspaceStructureEdits().renamingGroup(ws, g, to: "X").assigning(ws, [ref("a")], toGroup: g)
        edits = edits.clearingWorkspace(ws)
        #expect(edits.isEmpty)
    }

    @Test func applyMovesNodeIntoTargetGroup() {
        let gA = UUID(), gB = UUID()
        let tree = AIVirtualFolderTree(
            id: UUID(), workspaceID: ws, title: "T", generatedAt: Date(timeIntervalSince1970: 1),
            nodes: [group(gA, "A", [fileNode("a.txt", "a"), fileNode("b.txt", "b")]),
                    group(gB, "B", [fileNode("c.txt", "c")])],
            sourceRefs: [ref("a"), ref("b"), ref("c")])
        // 把 a 移进 B。
        let out = tree.applyingStructureEdits(groupTitles: [:], assignments: [ref("a"): gB])
        let a = out.nodes.first { $0.id == gA }!
        let b = out.nodes.first { $0.id == gB }!
        #expect(a.children.map(\.title) == ["b.txt"])           // a 走了
        #expect(b.children.map(\.title).sorted() == ["a.txt", "c.txt"])  // a 进了 B
    }

    @Test func applyRenamesGroupAndKeepsEmptiedRenamedGroup() {
        let gA = UUID(), gB = UUID()
        let tree = AIVirtualFolderTree(
            id: UUID(), workspaceID: ws, title: "T", generatedAt: Date(timeIntervalSince1970: 1),
            nodes: [group(gA, "A", [fileNode("a.txt", "a")]),
                    group(gB, "B", [fileNode("c.txt", "c")])],
            sourceRefs: [ref("a"), ref("c")])
        // 改名 A,且把 A 唯一成员移走 → A 空了但因改过名而保留。
        let out = tree.applyingStructureEdits(groupTitles: [gA: "Renamed"], assignments: [ref("a"): gB])
        let a = out.nodes.first { $0.id == gA }
        #expect(a?.title == "Renamed")
        #expect(a?.children.isEmpty == true)   // 空了但保留(用户改过名)
    }

    @Test func emptiedDerivedGroupIsDropped() {
        let gA = UUID(), gB = UUID()
        let tree = AIVirtualFolderTree(
            id: UUID(), workspaceID: ws, title: "T", generatedAt: Date(timeIntervalSince1970: 1),
            nodes: [group(gA, "A", [fileNode("a.txt", "a")]),
                    group(gB, "B", [fileNode("c.txt", "c")])],
            sourceRefs: [ref("a"), ref("c")])
        // 不改名,只把 A 的唯一成员移走 → 派生分组 A 空了 → 丢弃。
        let out = tree.applyingStructureEdits(groupTitles: [:], assignments: [ref("a"): gB])
        #expect(out.nodes.first { $0.id == gA } == nil)
    }

    @Test func assignmentToNonexistentGroupIsIgnored() {
        let gA = UUID()
        let tree = AIVirtualFolderTree(
            id: UUID(), workspaceID: ws, title: "T", generatedAt: Date(timeIntervalSince1970: 1),
            nodes: [group(gA, "A", [fileNode("a.txt", "a")])], sourceRefs: [ref("a")])
        let out = tree.applyingStructureEdits(groupTitles: [:], assignments: [ref("a"): UUID()])
        // 目标分组不存在 → 忽略,a 留在原位。
        #expect(out.nodes.first { $0.id == gA }?.children.map(\.title) == ["a.txt"])
    }
}

//
//  AIVirtualFolderTreeTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:虚拟文件夹树容器 + 节点 secondaryActions / automation kind(白皮书建议四)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIVirtualFolderTreeTests {
    private let ws = AIStableHash.deterministicUUID("ws-1")
    private let validRef = AIContextSourceRef(kind: .file, id: "file-1")
    private let invented = AIContextSourceRef(kind: .file, id: "file-INVENTED")
    private let gen = Date(timeIntervalSince1970: 1_000)

    // MARK: - 节点扩展

    @Test func nodeSupportsAutomationKindAndSecondaryActions() {
        let node = AIVirtualNode(
            id: AIStableHash.deterministicUUID("n1"), kind: .automation, title: "建个检查 Shortcut",
            primaryAction: .openActivityCenter,
            secondaryActions: [.dismissRecommendedWorkspace(ws)])
        #expect(node.kind == .automation)
        #expect(node.secondaryActions.count == 1)
    }

    @Test func nodeDefaultsSecondaryActionsEmpty() {
        let node = AIVirtualNode(id: AIStableHash.deterministicUUID("n2"), kind: .note, title: "说明")
        #expect(node.secondaryActions.isEmpty)
    }

    // MARK: - 树容器

    private func sampleTree(nodes: [AIVirtualNode], refs: [AIContextSourceRef]) -> AIVirtualFolderTree {
        AIVirtualFolderTree(id: AIStableHash.deterministicUUID("tree-1"), workspaceID: ws,
                            title: "我的论文", prompt: "论文相关", generatedAt: gen,
                            nodes: nodes, sourceRefs: refs)
    }

    @Test func totalNodeCountCountsNested() {
        let leaf = AIVirtualNode(id: AIStableHash.deterministicUUID("leaf"), kind: .file, title: "a",
                                 sourceRefs: [validRef])
        let group = AIVirtualNode(id: AIStableHash.deterministicUUID("g"), kind: .group, title: "组",
                                  children: [leaf])
        let tree = sampleTree(nodes: [group], refs: [validRef])
        #expect(tree.totalNodeCount == 2)        // group + leaf
        #expect(!tree.isEmpty)
    }

    @Test func sanitizedDropsInventedRefAndEmptyGroup() {
        let validLeaf = AIVirtualNode(id: AIStableHash.deterministicUUID("ok"), kind: .file, title: "ok",
                                      sourceRefs: [validRef])
        let inventedLeaf = AIVirtualNode(id: AIStableHash.deterministicUUID("bad"), kind: .file, title: "bad",
                                         sourceRefs: [invented])
        let mixedGroup = AIVirtualNode(id: AIStableHash.deterministicUUID("g1"), kind: .group, title: "混合",
                                       children: [validLeaf, inventedLeaf])
        let allInventedGroup = AIVirtualNode(id: AIStableHash.deterministicUUID("g2"), kind: .group,
                                             title: "全非法", children: [inventedLeaf])
        let tree = sampleTree(nodes: [mixedGroup, allInventedGroup], refs: [validRef])
        let clean = tree.sanitized()
        #expect(clean.nodes.count == 1)                       // 全非法组被清空丢弃
        #expect(clean.nodes[0].children.count == 1)           // 混合组只剩合法叶
        #expect(clean.nodes[0].children[0].title == "ok")
    }

    @Test func sanitizedDropsDestructiveNode() {
        let danger = AIVirtualNode(
            id: AIStableHash.deterministicUUID("danger"), kind: .file, title: "危险",
            sourceRefs: [validRef],
            safety: AISuggestionSafety(destructive: true, requiresConfirmation: true))
        let tree = sampleTree(nodes: [danger], refs: [validRef])
        #expect(tree.sanitized().nodes.isEmpty)               // 破坏性节点不进虚拟树
    }

    @Test func sanitizedDropsEmptyRefPointerNodeButKeepsNote() {
        // 指针类(.file)节点没有 ref → 指向不到真实对象,丢弃(边界二:默认拒绝空 ref)。
        let refless = AIVirtualNode(id: AIStableHash.deterministicUUID("refless"), kind: .file, title: "空指针")
        // 注解类(.note)节点本就无 node 级 ref,保留。
        let note = AIVirtualNode(id: AIStableHash.deterministicUUID("note"), kind: .note, title: "说明")
        let tree = sampleTree(nodes: [refless, note], refs: [validRef])
        let clean = tree.sanitized()
        #expect(clean.nodes.count == 1)
        #expect(clean.nodes[0].kind == .note)
    }

    @Test func treeCodableRoundTrips() throws {
        let leaf = AIVirtualNode(id: AIStableHash.deterministicUUID("leaf"), kind: .archive, title: "x.zip",
                                 sourceRefs: [validRef], primaryAction: .openArchive(path: "/x.zip", revealEntry: nil))
        let tree = sampleTree(nodes: [leaf], refs: [validRef])
        let data = try JSONEncoder().encode(tree)
        let back = try JSONDecoder().decode(AIVirtualFolderTree.self, from: data)
        #expect(back == tree)
    }
}

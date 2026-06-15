//
//  AIWorkspaceThemeEngineTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80 #89:跨位置语义聚类器(白皮书建议四 — 把五湖四海、八竿子打不着的文件按语义聚成一个主题)。
//  这些测试的重点是证明**位置不进成员资格、主题可跨位置**(我之前反复做成「单文件夹分桶」)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIWorkspaceThemeEngineTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func loc(_ kind: AILocationKind) -> AILocationContext {
        AILocationContext(kind: kind, pathHash: "loc-" + kind.rawValue, folderNameTokens: [])
    }

    private func cand(_ id: String, name: String, kind: AIVirtualNode.Kind = .file,
                      at locKind: AILocationKind = .other, role: String = "document",
                      tasks: [String] = [], archives: [String] = []) -> AIVirtualNodeCandidate {
        let refKind: AIContextSourceRef.Kind = {
            switch kind {
            case .archive: return .archive
            case .archiveEntry: return .archiveEntry
            case .task: return .task
            case .report: return .report
            default: return .file
            }
        }()
        return AIVirtualNodeCandidate(
            id: id, kind: kind, displayName: name,
            sourceRefs: [AIContextSourceRef(kind: refKind, id: "ref-" + id)],
            roleTags: [role], location: loc(locKind),
            relatedTaskIDs: tasks, relatedArchiveIDs: archives)
    }

    // MARK: - 跨位置(核心证明)

    @Test func sharedEnglishTokenClustersAcrossLocations() {
        // 一个在 Desktop、一个在 Downloads,共享名字 token「paper」→ 聚成一个跨位置主题。
        let pool = [
            cand("a", name: "paper-draft.docx", at: .desktop),
            cand("b", name: "paper-figures.zip", kind: .archive, at: .downloads, role: "archive")
        ]
        let themes = AIWorkspaceThemeEngine.discoverThemes(from: pool, now: now)
        #expect(themes.count == 1)
        #expect(themes[0].sourceRefs.count == 2)
        #expect(themes[0].titleSeed == "paper")
        // 真·跨位置:命中两个不同位置类别。
        #expect(themes[0].scoreSignals.contains("cross-location=2"))
    }

    @Test func cjkCompoundNamesClusterAcrossLocations() {
        // 「论文.docx」(Desktop)和「论文修订意见.pdf」(Downloads):中文复合词无分隔,靠 CJK 子串连通。
        let pool = [
            cand("p1", name: "论文.docx", at: .desktop),
            cand("p2", name: "论文修订意见.pdf", at: .downloads)
        ]
        let themes = AIWorkspaceThemeEngine.discoverThemes(from: pool, now: now)
        #expect(themes.count == 1)
        #expect(themes[0].sourceRefs.count == 2)
        #expect(themes[0].scoreSignals.contains("cross-location=2"))
    }

    @Test func sharedTaskLinksFilesWithNoCommonName() {
        // 「报告.docx」和「screenshot.png」名字毫不相关(八竿子打不着),但同一任务处理过 → 聚到一起。
        let pool = [
            cand("t1", name: "报告.docx", at: .desktop, tasks: ["task-9"]),
            cand("t2", name: "screenshot.png", at: .downloads, role: "media", tasks: ["task-9"])
        ]
        let themes = AIWorkspaceThemeEngine.discoverThemes(from: pool, now: now)
        #expect(themes.count == 1)
        #expect(themes[0].sourceRefs.count == 2)
        #expect(themes[0].scoreSignals.contains("has-task") == false)  // 任务节点才算 has-task;这俩是文件
    }

    @Test func archiveAndItsEntryCluster() {
        let pool = [
            cand("arc", name: "bundle.zip", kind: .archive, at: .downloads, role: "archive", archives: ["arch-1"]),
            cand("ent", name: "bundle.zip/readme.md", kind: .archiveEntry, at: .downloads, archives: ["arch-1"])
        ]
        let themes = AIWorkspaceThemeEngine.discoverThemes(from: pool, now: now)
        #expect(themes.count == 1)
        #expect(themes[0].scoreSignals.contains("has-archive"))
    }

    @Test func unrelatedSingletonsProduceNoTheme() {
        // 无共享 token / 任务 / 归档 → 各自成单件 → 不出主题(单件不成主题)。
        let pool = [cand("x", name: "alpha.txt"), cand("y", name: "beta.csv", role: "data")]
        #expect(AIWorkspaceThemeEngine.discoverThemes(from: pool, now: now).isEmpty)
    }

    // MARK: - 位置不进成员资格 / id

    @Test func themeIDIsLocationIndependent() {
        // 同一批成员(同 sourceRef),换不同物理位置 → 主题 id 必须相同(位置不进 id/成员资格)。
        func pool(_ l1: AILocationKind, _ l2: AILocationKind) -> [AIVirtualNodeCandidate] {
            [cand("m1", name: "paper-a.docx", at: l1), cand("m2", name: "paper-b.docx", at: l2)]
        }
        let t1 = AIWorkspaceThemeEngine.discoverThemes(from: pool(.desktop, .downloads), now: now)
        let t2 = AIWorkspaceThemeEngine.discoverThemes(from: pool(.documents, .externalDrive), now: now)
        #expect(t1.first?.id == t2.first?.id)
    }

    @Test func clusteringIsDeterministicRegardlessOfOrder() {
        let pool = [
            cand("a", name: "paper-1.docx", at: .desktop),
            cand("b", name: "paper-2.pdf", at: .downloads),
            cand("c", name: "paper-3.png", at: .documents, role: "media")
        ]
        let forward = AIWorkspaceThemeEngine.discoverThemes(from: pool, now: now)
        let reversed = AIWorkspaceThemeEngine.discoverThemes(from: pool.reversed(), now: now)
        #expect(forward.map(\.id) == reversed.map(\.id))
        #expect(forward.first?.sourceRefs.count == 3)
    }

    // MARK: - 注意力加权(只影响排序,不影响成员)

    @Test func currentFocusAddsAttentionSignal() {
        let pool = [cand("a", name: "paper-a.docx", at: .desktop),
                    cand("b", name: "paper-b.pdf", at: .downloads)]
        let attention = AIAttentionContext(focusedSourceRefs: [AIContextSourceRef(kind: .file, id: "ref-a")])
        let themes = AIWorkspaceThemeEngine.discoverThemes(from: pool, attention: attention, now: now)
        #expect(themes.first?.scoreSignals.contains("attention:current-focus") == true)
        // 成员不变(注意力不改成员资格)。
        #expect(themes.first?.sourceRefs.count == 2)
    }

    @Test func habitLocationAddsAttentionSignal() {
        let pool = [cand("a", name: "paper-a.docx", at: .downloads),
                    cand("b", name: "paper-b.pdf", at: .downloads)]
        let attention = AIAttentionContext(locationAffinityKinds: ["downloads"])
        let themes = AIWorkspaceThemeEngine.discoverThemes(from: pool, attention: attention, now: now)
        #expect(themes.first?.scoreSignals.contains("attention:habit-location") == true)
    }

    @Test func recommendedWorkspaceUsesDeterministicID() {
        let pool = [cand("a", name: "paper-a.docx", at: .desktop),
                    cand("b", name: "paper-b.pdf", at: .downloads)]
        let theme = AIWorkspaceThemeEngine.discoverThemes(from: pool, now: now).first!
        let ws1 = theme.toRecommendedWorkspace(generatedAt: now)
        let ws2 = theme.toRecommendedWorkspace(generatedAt: now)
        #expect(ws1.id == ws2.id)
        #expect(ws1.origin == .recommended)
    }

    @Test func emptyOrTinyPoolProducesNoThemes() {
        #expect(AIWorkspaceThemeEngine.discoverThemes(from: [], now: now).isEmpty)
        #expect(AIWorkspaceThemeEngine.discoverThemes(from: [cand("a", name: "x.txt")], now: now).isEmpty)
    }
}

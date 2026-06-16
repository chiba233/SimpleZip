//
//  AIWorkspaceDiscoveryTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80 #89:多源候选组装 + 发现流水线(全局数据层 → 聚类 → 衰减抑制)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIWorkspaceDiscoveryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func loc(_ kind: AILocationKind) -> AILocationContext {
        AILocationContext(kind: kind, pathHash: "loc-" + kind.rawValue, folderNameTokens: [])
    }

    private func fileRec(_ name: String, at kind: AILocationKind) -> AIFileMemoryRecord {
        AIFileMemoryRecord.make(fileName: name, isDirectory: false, byteSize: 1000,
                                modifiedAt: now, location: loc(kind))
    }

    @Test func fileRecordsClusterAcrossLocations() {
        // 3 文件跨 3 个位置(跨位置 = 有质量)→ 通过默认质量门控。
        let files = [fileRec("paper-draft.docx", at: .desktop),
                     fileRec("paper-figures.pdf", at: .downloads),
                     fileRec("paper-notes.md", at: .documents)]
        let out = AIWorkspaceDiscovery.discover(files: files, now: now)
        #expect(out.themes.count == 1)
        #expect(out.themes[0].sourceRefs.count == 3)
        #expect(out.themes[0].scoreSignals.contains("cross-location=3"))
    }

    @Test func taskClustersWithItsArchive() {
        // 归档文件记录 + 处理它的任务,靠归档名派生 id 连通(任务标题 / 归档名毫不相干也能连)。
        // 用 permissive 策略测「连通机制」本身(不卡质量门控)。
        let files = [fileRec("release.zip", at: .downloads)]
        let task = AITaskRecord.make(
            id: "task-1", category: "archive", kind: "test", source: "app", status: "failed",
            title: "verify", startedAt: nil, finishedAt: nil,
            archivePath: "/Users/me/Downloads/release.zip")
        let out = AIWorkspaceDiscovery.discover(files: files, tasks: [task], now: now, policy: .permissive)
        #expect(out.themes.count == 1)
        // 主题混合了「归档 + 任务」两类节点(白皮书:工作区内容必须混合文件/归档/任务…)。
        let kinds = Set(out.themes[0].sourceRefs.map(\.kind))
        #expect(kinds.contains(.archive))
        #expect(kinds.contains(.task))
        #expect(out.themes[0].scoreSignals.contains("has-task"))
        #expect(out.themes[0].scoreSignals.contains("has-archive"))
    }

    @Test func dismissedThemeIsSuppressed() {
        let files = [fileRec("paper-a.docx", at: .desktop), fileRec("paper-b.pdf", at: .downloads),
                     fileRec("paper-c.md", at: .documents)]
        let first = AIWorkspaceDiscovery.discover(files: files, now: now)
        let fp = first.themes[0].fingerprint!
        let ledger = AIThemeSuppressionLedger().recordingDismissal(fp, at: now)
        let second = AIWorkspaceDiscovery.discover(files: files, suppression: ledger, now: now)
        #expect(second.themes.isEmpty)               // 刚不感兴趣 → 压住
        #expect(second.suppressed.count == 1)
        #expect(second.suppressed[0].theme.fingerprint == fp)
    }

    // MARK: - 质量 + 数量门控

    @Test func qualityGateDropsThinSameFolderTheme() {
        // 3 个同位置纯文本文件(无跨位置 / 无任务归档 / 未上规模)→ 不够「完整」→ 默认不推荐。
        let files = [fileRec("note-a.txt", at: .downloads),
                     fileRec("note-b.txt", at: .downloads),
                     fileRec("note-c.txt", at: .downloads)]
        let out = AIWorkspaceDiscovery.discover(files: files, now: now)
        #expect(out.themes.isEmpty)
        // permissive 下(不卡质量)同一批能聚出主题 —— 证明被门控挡掉的是「质量」而非「聚类失败」。
        #expect(!AIWorkspaceDiscovery.discover(files: files, now: now, policy: .permissive).themes.isEmpty)
    }

    @Test func policyDefaultClusterSizeMatchesThemeEngineMinimum() throws {
        let files = [fileRec("paper-draft.docx", at: .downloads),
                     fileRec("paper-figures.zip", at: .desktop)]
        let policy = AIRecommendationPolicy(minMembers: 2, gateQuality: false)

        let out = AIWorkspaceDiscovery.discover(files: files, now: now, policy: policy)
        let theme = try #require(out.themes.first)

        #expect(out.themes.count == 1)
        #expect(theme.sourceRefs.count == 2)
    }

    @Test func isQualityPredicate() {
        let thin = AIWorkspaceThemeCandidate(id: "t", titleSeed: "x",
            sourceRefs: [AIContextSourceRef(kind: .file, id: "a"), AIContextSourceRef(kind: .file, id: "b")],
            scoreSignals: ["cluster-size=2", "shared-token:x"])
        #expect(!AIRecommendationPolicy.default.isQuality(thin))          // 2 成员 + 无跨源 → 否
        let crossLoc = AIWorkspaceThemeCandidate(id: "t2", titleSeed: "x",
            sourceRefs: (0..<3).map { AIContextSourceRef(kind: .file, id: "r\($0)") },
            scoreSignals: ["cluster-size=3", "cross-location=2"])
        #expect(AIRecommendationPolicy.default.isQuality(crossLoc))       // 跨位置 → 是
        let big = AIWorkspaceThemeCandidate(id: "t3", titleSeed: "x",
            sourceRefs: (0..<5).map { AIContextSourceRef(kind: .file, id: "b\($0)") },
            scoreSignals: ["cluster-size=5", "shared-token:x"])
        #expect(AIRecommendationPolicy.default.isQuality(big))            // 上规模 → 是
    }

    @Test func assemblePoolDedupsByID() {
        let files = [fileRec("a.txt", at: .desktop), fileRec("a.txt", at: .desktop)]  // 同名同位置 → 同 id
        #expect(AIWorkspaceDiscovery.assemblePool(files: files).count == 1)
    }

    @Test func emptyInputProducesNoThemes() {
        #expect(AIWorkspaceDiscovery.discover(now: now).themes.isEmpty)
    }
}

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
        let files = [fileRec("paper-draft.docx", at: .desktop), fileRec("paper-figures.pdf", at: .downloads)]
        let out = AIWorkspaceDiscovery.discover(files: files, now: now)
        #expect(out.themes.count == 1)
        #expect(out.themes[0].sourceRefs.count == 2)
        #expect(out.themes[0].scoreSignals.contains("cross-location=2"))
    }

    @Test func taskClustersWithItsArchive() {
        // 归档文件记录 + 处理它的任务,靠归档名派生 id 连通(任务标题 / 归档名毫不相干也能连)。
        let files = [fileRec("release.zip", at: .downloads)]
        let task = AITaskRecord.make(
            id: "task-1", category: "archive", kind: "test", source: "app", status: "failed",
            title: "verify", startedAt: nil, finishedAt: nil,
            archivePath: "/Users/me/Downloads/release.zip")
        let out = AIWorkspaceDiscovery.discover(files: files, tasks: [task], now: now)
        #expect(out.themes.count == 1)
        // 主题混合了「归档 + 任务」两类节点(白皮书:工作区内容必须混合文件/归档/任务…)。
        let kinds = Set(out.themes[0].sourceRefs.map(\.kind))
        #expect(kinds.contains(.archive))
        #expect(kinds.contains(.task))
        #expect(out.themes[0].scoreSignals.contains("has-task"))
        #expect(out.themes[0].scoreSignals.contains("has-archive"))
    }

    @Test func dismissedThemeIsSuppressed() {
        let files = [fileRec("paper-a.docx", at: .desktop), fileRec("paper-b.pdf", at: .downloads)]
        // 先发现一次拿到主题指纹。
        let first = AIWorkspaceDiscovery.discover(files: files, now: now)
        let fp = first.themes[0].fingerprint!
        // 用户不感兴趣 → 写衰减抑制账本。
        let ledger = AIThemeSuppressionLedger().recordingDismissal(fp, at: now)
        let second = AIWorkspaceDiscovery.discover(files: files, suppression: ledger, now: now)
        #expect(second.themes.isEmpty)               // 刚不感兴趣 → 压住
        #expect(second.suppressed.count == 1)
        #expect(second.suppressed[0].theme.fingerprint == fp)
    }

    @Test func assemblePoolDedupsByID() {
        let files = [fileRec("a.txt", at: .desktop), fileRec("a.txt", at: .desktop)]  // 同名同位置 → 同 id
        #expect(AIWorkspaceDiscovery.assemblePool(files: files).count == 1)
    }

    @Test func emptyInputProducesNoThemes() {
        #expect(AIWorkspaceDiscovery.discover(now: now).themes.isEmpty)
    }
}

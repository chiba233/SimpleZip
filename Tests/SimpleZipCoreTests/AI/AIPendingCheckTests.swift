//
//  AIPendingCheckTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:只读自动检查 pending 队列的幂等去重 / 取下一个 / 标记 / 指纹变重排 / 修剪 / 间隔映射。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIPendingCheckTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func enqueueDedupesSameFileSameBehaviorSameFingerprint() {
        var q = AIPendingCheckQueue()
        let first = q.enqueue(path: "/a.zip", behavior: .test, fingerprint: "10:5", now: t0)
        #expect(first)
        // 同路径 + 同行为 + 同指纹 → 不重复入队。
        let again = q.enqueue(path: "/a.zip", behavior: .test, fingerprint: "10:5", now: t0.addingTimeInterval(1))
        #expect(!again)
        #expect(q.checks.count == 1)
        #expect(q.pendingCount == 1)
    }

    @Test func differentBehaviorIsSeparateEntry() {
        var q = AIPendingCheckQueue()
        q.enqueue(path: "/a.zip", behavior: .test, fingerprint: "10:5", now: t0)
        q.enqueue(path: "/a.zip", behavior: .hash, fingerprint: "10:5", now: t0)
        #expect(q.checks.count == 2)
    }

    @Test func doneBlocksRerunUntilFingerprintChanges() {
        var q = AIPendingCheckQueue()
        q.enqueue(path: "/a.zip", behavior: .inspect, fingerprint: "10:5", now: t0)
        let id = AIPendingCheck.identity(path: "/a.zip", behavior: .inspect)
        q.mark(id: id, status: .done, executedAt: t0.addingTimeInterval(60))
        #expect(q.isDone(path: "/a.zip", behavior: .inspect, fingerprint: "10:5"))
        // 文件没改(同指纹)→ 不重排。
        let sameFingerprint = q.enqueue(path: "/a.zip", behavior: .inspect, fingerprint: "10:5", now: t0.addingTimeInterval(120))
        #expect(!sameFingerprint)
        #expect(q.pendingCount == 0)
        // 文件改了(指纹变)→ 替换成新的 pending,重新检查。
        let changed = q.enqueue(path: "/a.zip", behavior: .inspect, fingerprint: "11:6", now: t0.addingTimeInterval(180))
        #expect(changed)
        #expect(q.checks.count == 1)            // 仍只一条(替换而非新增)
        #expect(q.pendingCount == 1)
        #expect(!q.isDone(path: "/a.zip", behavior: .inspect, fingerprint: "11:6"))
    }

    @Test func nextPendingIsEarliestQueued() {
        var q = AIPendingCheckQueue()
        q.enqueue(path: "/b.zip", behavior: .hash, fingerprint: "1:1", now: t0.addingTimeInterval(50))
        q.enqueue(path: "/a.zip", behavior: .hash, fingerprint: "1:1", now: t0)
        #expect(q.nextPending()?.path == "/a.zip")   // 最早入队的先执行
        let id = AIPendingCheck.identity(path: "/a.zip", behavior: .hash)
        q.mark(id: id, status: .done, executedAt: t0.addingTimeInterval(100))
        #expect(q.nextPending()?.path == "/b.zip")   // a 做完 → 轮到 b
    }

    @Test func pruneDropsOldFinishedKeepsPending() {
        var q = AIPendingCheckQueue()
        q.enqueue(path: "/old.zip", behavior: .test, fingerprint: "1:1", now: t0)
        q.mark(id: AIPendingCheck.identity(path: "/old.zip", behavior: .test), status: .done, executedAt: t0)
        q.enqueue(path: "/fresh.zip", behavior: .test, fingerprint: "1:1", now: t0.addingTimeInterval(10_000))
        // 保留期 1 小时,从 t0+2小时 看:old 的 done 过期清掉,fresh 的 pending 留着。
        q.prune(doneRetention: 3_600, now: t0.addingTimeInterval(7_200))
        #expect(q.checks.count == 1)
        #expect(q.checks.first?.path == "/fresh.zip")
        #expect(q.pendingCount == 1)
    }

    @Test func fingerprintFromMetadataIsStable() {
        let a = AIPendingCheck.fingerprint(byteSize: 1024, modifiedAt: Date(timeIntervalSince1970: 5))
        let b = AIPendingCheck.fingerprint(byteSize: 1024, modifiedAt: Date(timeIntervalSince1970: 5))
        let c = AIPendingCheck.fingerprint(byteSize: 2048, modifiedAt: Date(timeIntervalSince1970: 5))
        #expect(a == b)
        #expect(a != c)
    }

    @Test func intervalShrinksWithAggression() {
        #expect(AIPendingCheckSchedule.interval(for: .aggressive) == 4 * 60)
        #expect(AIPendingCheckSchedule.interval(for: .balanced) == 15 * 60)
        #expect(AIPendingCheckSchedule.interval(for: .powerSaver) == 30 * 60)
        // 越激进间隔越短。
        #expect(AIPendingCheckSchedule.interval(for: .aggressive) < AIPendingCheckSchedule.interval(for: .balanced))
        #expect(AIPendingCheckSchedule.interval(for: .balanced) < AIPendingCheckSchedule.interval(for: .powerSaver))
    }

    @Test func codableRoundTrip() throws {
        var q = AIPendingCheckQueue()
        q.enqueue(path: "/a.zip", behavior: .security, fingerprint: "3:3", now: t0)
        let decoded = try JSONDecoder().decode(AIPendingCheckQueue.self, from: JSONEncoder().encode(q))
        #expect(decoded == q)
    }

    // MARK: - 阶段 D:执行完「值不值得显示」复判(security / inspect 没异常不冒)

    @Test func securityJudgeHidesCleanShowsFindings() {
        let clean = ArchiveRiskScore.assess(findings: [])
        #expect(!AIPendingCheckJudge.securityWorthSurfacing(findings: [], assessment: clean))   // 全干净 → 不冒
        let finding = ArchiveSecurityFinding(kind: .parentTraversal, entryPaths: ["pkg/../escape"])
        let dirty = ArchiveRiskScore.assess(findings: [finding])
        #expect(AIPendingCheckJudge.securityWorthSurfacing(findings: [finding], assessment: dirty))   // 有发现 → 冒
    }

    @Test func inspectJudgeHidesCleanShowsProblems() {
        let cleanStats = ReleaseInspectionStats(fileCount: 5, folderCount: 1, totalBytes: 100,
                                                junkCount: 0, emptyDirectoryCount: 0, executableCount: 0, symlinkCount: 0)
        var clean = ReleaseInspectionReport(archiveURL: URL(fileURLWithPath: "/clean.zip"))
        clean.listable = true
        clean.stats = cleanStats
        clean.testPassed = true
        #expect(!AIPendingCheckJudge.inspectWorthSurfacing(report: clean))   // 干净发布包 → 不冒

        var withJunk = clean
        withJunk.stats = ReleaseInspectionStats(fileCount: 5, folderCount: 1, totalBytes: 100,
                                                junkCount: 2, emptyDirectoryCount: 0, executableCount: 0, symlinkCount: 0)
        #expect(AIPendingCheckJudge.inspectWorthSurfacing(report: withJunk))   // 有 macOS 垃圾 → 冒

        var testFailed = clean
        testFailed.testPassed = false
        #expect(AIPendingCheckJudge.inspectWorthSurfacing(report: testFailed))   // 完整性测试没过 → 冒

        var withFinding = clean
        withFinding.securityFindings = [ArchiveSecurityFinding(kind: .absolutePath, entryPaths: ["/etc/x"])]
        #expect(AIPendingCheckJudge.inspectWorthSurfacing(report: withFinding))   // 有危险条目 → 冒
    }
}

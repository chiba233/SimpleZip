//
//  AIBackgroundIndexRunTests.swift
//  SimpleZipCoreTests
//
//  独立 AI 进程改造 · 阶段2:`AIBackgroundIndexRun.scan` 一轮扫描**编排层**的确定性单测。
//
//  这里只测编排(选哪些 scope / 扫几个 / 超时 / 取消),不测扫描内容 —— scope 指向 temp 路径会被
//  `AIPrefetchExclusions` 排除、`scanScope` 返回空记录但不报错(见 AIIndexerScanTests 的说明),正好让编排层
//  在「每个被扫的 scope 产一条结果」这个事实上可确定性断言:`results.count` = 实际扫了几个,`results.map(\.scopeID)`
//  = 实际扫描顺序。这样无需真实文件树即可锁定预算上限 / 最久没扫排序 / deadline / 取消四条编排不变量。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIBackgroundIndexRunTests {
    /// 造一个 scope(directoryPath 随便,反正 temp 路径被排除、扫描返回空;只用它的 id / lastScannedAt 测编排)。
    private func scope(_ name: String, lastScannedAt: Date?) -> AIArchivePrefetchScope {
        AIArchivePrefetchScope(
            id: UUID(),
            directoryPath: FileManager.default.temporaryDirectory.appendingPathComponent(name).path,
            origin: .userAdded, recursive: true, maxDepth: 2,
            createdAt: Date(timeIntervalSince1970: 0), lastScannedAt: lastScannedAt)
    }

    /// 预算上限:5 个 scope、scopeBudget 2 → 这一轮只扫 2 个。
    @Test func budgetCapsScopesScannedPerRound() {
        let scopes = (0..<5).map { scope("dir\($0)", lastScannedAt: nil) }
        let results = AIBackgroundIndexRun.scan(
            scopes: scopes, home: NSHomeDirectory(), scopeBudget: 2, fileBudget: 1_000, allowContent: false)
        #expect(results.count == 2)
    }

    /// scopeBudget < 1 也至少扫 1 个(max(1, …) 兜底)。
    @Test func budgetFloorsAtOne() {
        let scopes = (0..<3).map { scope("dir\($0)", lastScannedAt: nil) }
        let results = AIBackgroundIndexRun.scan(
            scopes: scopes, home: NSHomeDirectory(), scopeBudget: 0, fileBudget: 1_000, allowContent: false)
        #expect(results.count == 1)
    }

    /// 最久没扫优先:从没扫过(nil)排最前,其余按上次扫描时间升序。预算 2 → 取「没扫过的」+「扫得最久的那个」。
    @Test func picksLeastRecentlyScannedFirst() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let never = scope("never", lastScannedAt: nil)
        let old = scope("old", lastScannedAt: base)                    // 最久没扫(有时间里最早)
        let recent = scope("recent", lastScannedAt: base.addingTimeInterval(10_000))   // 最近扫过
        // 故意乱序传入,验证内部排序而非依赖入参顺序。
        let results = AIBackgroundIndexRun.scan(
            scopes: [recent, old, never], home: NSHomeDirectory(),
            scopeBudget: 2, fileBudget: 1_000, allowContent: false)
        #expect(results.map(\.scopeID) == [never.id, old.id])
    }

    /// deadline 已过 → 一个都不扫(超时下次续:返回空,scope 的 lastScannedAt 不被本轮触碰)。
    @Test func deadlineInPastScansNothing() {
        let scopes = (0..<3).map { scope("dir\($0)", lastScannedAt: nil) }
        let past = Date(timeIntervalSince1970: 0)
        let results = AIBackgroundIndexRun.scan(
            scopes: scopes, home: NSHomeDirectory(), scopeBudget: 3, fileBudget: 1_000,
            allowContent: false, deadline: past)
        #expect(results.isEmpty)
    }

    /// deadline 在远未来 → 不限制,正常按预算扫满。
    @Test func deadlineInFutureDoesNotLimit() {
        let scopes = (0..<3).map { scope("dir\($0)", lastScannedAt: nil) }
        let future = Date(timeIntervalSinceNow: 3_600)
        let results = AIBackgroundIndexRun.scan(
            scopes: scopes, home: NSHomeDirectory(), scopeBudget: 3, fileBudget: 1_000,
            allowContent: false, deadline: future)
        #expect(results.count == 3)
    }

    /// 取消旗立刻为真 → 一个都不扫。
    @Test func cancellationStopsImmediately() {
        let scopes = (0..<3).map { scope("dir\($0)", lastScannedAt: nil) }
        let results = AIBackgroundIndexRun.scan(
            scopes: scopes, home: NSHomeDirectory(), scopeBudget: 3, fileBudget: 1_000,
            allowContent: false, isCancelled: { true })
        #expect(results.isEmpty)
    }

    /// 空白名单 → 空结果(不崩)。
    @Test func emptyScopesReturnsEmpty() {
        let results = AIBackgroundIndexRun.scan(
            scopes: [], home: NSHomeDirectory(), scopeBudget: 3, fileBudget: 1_000, allowContent: false)
        #expect(results.isEmpty)
    }
}

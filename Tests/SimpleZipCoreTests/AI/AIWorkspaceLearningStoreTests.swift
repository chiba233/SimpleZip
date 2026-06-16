//
//  AIWorkspaceLearningStoreTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80 #89:泛化反馈(不喜欢摊到角色/类型/位置信号上,软调召回,非全局硬删)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIWorkspaceLearningStoreTests {
    private let ws = UUID()
    private let other = UUID()

    @Test func likeRaisesDislikeLowersAffinity() {
        var s = AIWorkspaceLearningStore()
        s = s.reinforcing(ws, signals: ["image", "screenshot"], by: 1)
        #expect(s.affinity(ws, signals: ["image"]) == 1)
        s = s.reinforcing(ws, signals: ["image"], by: -1)
        #expect(s.affinity(ws, signals: ["image"]) == 0)        // 一升一降抵消
        #expect(s.affinity(ws, signals: ["screenshot"]) == 1)   // 另一个信号不受影响
    }

    @Test func affinityIsScopedPerWorkspace() {
        var s = AIWorkspaceLearningStore()
        s = s.reinforcing(ws, signals: ["source"], by: 2)
        #expect(s.affinity(ws, signals: ["source"]) == 2)
        #expect(s.affinity(other, signals: ["source"]) == 0)
    }

    @Test func weightsClampToCap() {
        var s = AIWorkspaceLearningStore()
        for _ in 0..<10 { s = s.reinforcing(ws, signals: ["doc"], by: 1) }
        #expect(s.affinity(ws, signals: ["doc"]) == AIWorkspaceLearningStore.cap)
        for _ in 0..<20 { s = s.reinforcing(ws, signals: ["doc"], by: -1) }
        #expect(s.affinity(ws, signals: ["doc"]) == -AIWorkspaceLearningStore.cap)
    }

    @Test func stronglyDislikedAfterRepeatedNegative() {
        var s = AIWorkspaceLearningStore()
        s = s.reinforcing(ws, signals: ["image"], by: -3)
        #expect(s.isStronglyDisliked(ws, signals: ["image"]))
        #expect(!s.isStronglyDisliked(ws, signals: ["source"]))   // 没记录 → 不剔
    }

    @Test func clearingWorkspaceWipes() {
        var s = AIWorkspaceLearningStore().reinforcing(ws, signals: ["x"], by: 3)
        s = s.clearingWorkspace(ws)
        #expect(s.isEmpty)
    }

    @Test func codableRoundTrips() throws {
        let s = AIWorkspaceLearningStore().reinforcing(ws, signals: ["a", "b"], by: 2)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(AIWorkspaceLearningStore.self, from: data) == s)
    }

    @Test func recordingWithTimestampDecaysOverTime() {
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        let s = AIWorkspaceLearningStore().recording(ws, signals: ["image"], by: -4, at: epoch)
        // No decay at t=0
        #expect(s.weightedAffinity(ws, signals: ["image"], now: epoch) == -4)
        // After 45 days → half (half-life = 45 days)
        let halfLifeDays = epoch.addingTimeInterval(45 * 86_400)
        let decayed = s.weightedAffinity(ws, signals: ["image"], now: halfLifeDays)
        #expect(abs(decayed - (-2)) < 0.01)
    }

    @Test func weightedAffinityWithoutTimestampReturnsRaw() {
        // reinforcing() passes nil timestamp → no decay regardless of now
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        let s = AIWorkspaceLearningStore().reinforcing(ws, signals: ["doc"], by: 3)
        let farFuture = epoch.addingTimeInterval(365 * 86_400)
        #expect(s.weightedAffinity(ws, signals: ["doc"], now: farFuture) == 3)
    }

    @Test func isStronglyDislikedDecaysWithTime() {
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        // -4 ≤ strongNegative(-2.5) → disliked at t=0
        let s = AIWorkspaceLearningStore().recording(ws, signals: ["img"], by: -4, at: epoch)
        #expect(s.isStronglyDisliked(ws, signals: ["img"], now: epoch))
        // After ~120 days (halfLife 45d): -4 × 0.5^(120/45) ≈ -0.63 > -2.5 → not strongly disliked
        let farFuture = epoch.addingTimeInterval(120 * 86_400)
        #expect(!s.isStronglyDisliked(ws, signals: ["img"], now: farFuture))
    }

    @Test func recordingKeepsLatestTimestamp() {
        let t1 = Date(timeIntervalSinceReferenceDate: 100)
        let t2 = Date(timeIntervalSinceReferenceDate: 1000)
        var s = AIWorkspaceLearningStore().recording(ws, signals: ["x"], by: -1, at: t2)
        s = s.recording(ws, signals: ["x"], by: -1, at: t1) // older timestamp ignored
        // Both recordings sum to -2; decay anchored to t2 (later)
        let atT2 = s.weightedAffinity(ws, signals: ["x"], now: t2)
        #expect(atT2 == -2)
    }

    @Test func clearingWorkspaceWipesTimestamp() {
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        var s = AIWorkspaceLearningStore().recording(ws, signals: ["x"], by: -3, at: epoch)
        s = s.clearingWorkspace(ws)
        #expect(s.isEmpty)
        // After clear, weightedAffinity must be 0 (not crash)
        #expect(s.weightedAffinity(ws, signals: ["x"], now: epoch) == 0)
    }
}

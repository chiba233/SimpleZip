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
}

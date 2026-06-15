//
//  AIIntentRouterTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 场景路由器(白皮书建议二十四)。确定性 surface+selection 路由;模型目标必须在可用能力内,
//  否则退回;confidence 钳到 [0,1]。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIIntentRouterTests {
    private func archiveRef(_ id: String = "arch-1") -> AIContextSourceRef {
        AIContextSourceRef(kind: .archive, id: id)
    }

    @Test func routesActivitySurfaceToActivityFilter() {
        let r = AIIntentRouter.deterministicRoute(
            AIIntentRoutingInput(userText: "找上次权限失败", surface: "activity-center"))
        #expect(r.destination == .activityFilter)
    }

    @Test func routesSettingsSurfaceToSettingsAssistant() {
        let r = AIIntentRouter.deterministicRoute(
            AIIntentRoutingInput(userText: "我不想每次都弹这个", surface: "settings"))
        #expect(r.destination == .settingsAssistant)
    }

    @Test func routesBrowserWithArchiveSelectionToOperationPreview() {
        let r = AIIntentRouter.deterministicRoute(
            AIIntentRoutingInput(userText: "看看有什么问题", surface: "browser",
                                 selectedSourceRefs: [archiveRef()]))
        #expect(r.destination == .operationPreview)
    }

    @Test func routesWorkspaceSurface() {
        let r = AIIntentRouter.deterministicRoute(
            AIIntentRoutingInput(userText: "按发布相关重新整理", surface: "ai-workspace"))
        #expect(r.destination == .aiWorkspace)
    }

    @Test func unknownSurfaceNoSelectionFallsBackToActionRecommendation() {
        let r = AIIntentRouter.deterministicRoute(
            AIIntentRoutingInput(userText: "嗯", surface: "weird-surface"))
        #expect(r.destination == .actionRecommendation)
    }

    @Test func extractedQueryIsTrimmed() {
        let r = AIIntentRouter.deterministicRoute(
            AIIntentRoutingInput(userText: "  源码包  ", surface: "memory"))
        #expect(r.extractedQuery == "源码包")
        #expect(r.destination == .archiveSearch)
    }

    @Test func deterministicRespectsAvailableCapabilities() {
        // surface 指向 settingsAssistant,但它不在可用能力里 → 退回。
        let r = AIIntentRouter.deterministicRoute(
            AIIntentRoutingInput(userText: "x", surface: "settings",
                                 availableCapabilities: ["actionRecommendation", "archiveSearch"]))
        #expect(r.destination == .actionRecommendation)
    }

    @Test func clampKeepsAvailableModelDestination() {
        let input = AIIntentRoutingInput(userText: "x", surface: "browser",
                                         availableCapabilities: ["archiveSearch", "operationPreview"])
        let model = AIIntentRoutingResult(destination: .archiveSearch, confidence: 0.9, extractedQuery: "x")
        let c = AIIntentRouter.clamp(model, for: input)
        #expect(c.destination == .archiveSearch)
        #expect(c.confidence == 0.9)
    }

    @Test func clampRejectsUnavailableModelDestinationFallsBack() {
        let input = AIIntentRoutingInput(userText: "x", surface: "activity-center",
                                         availableCapabilities: ["activityFilter"])
        // 模型想去 settingsAssistant,但不可用 → 退回确定性(activityFilter)。
        let model = AIIntentRoutingResult(destination: .settingsAssistant, confidence: 0.95, extractedQuery: "x")
        let c = AIIntentRouter.clamp(model, for: input)
        #expect(c.destination == .activityFilter)
    }

    @Test func clampClampsConfidenceRange() {
        let input = AIIntentRoutingInput(userText: "x", surface: "settings")
        let tooHigh = AIIntentRoutingResult(destination: .settingsAssistant, confidence: 5.0, extractedQuery: "x")
        let tooLow = AIIntentRoutingResult(destination: .settingsAssistant, confidence: -2.0, extractedQuery: "x")
        #expect(AIIntentRouter.clamp(tooHigh, for: input).confidence == 1.0)
        #expect(AIIntentRouter.clamp(tooLow, for: input).confidence == 0.0)
    }

    @Test func codableRoundTrip() throws {
        let input = AIIntentRoutingInput(userText: "看看", surface: "browser", currentMode: "table",
                                         selectedSourceRefs: [archiveRef()], availableCapabilities: ["operationPreview"])
        let result = AIIntentRouter.deterministicRoute(input)
        let di = try JSONDecoder().decode(AIIntentRoutingInput.self, from: JSONEncoder().encode(input))
        let dr = try JSONDecoder().decode(AIIntentRoutingResult.self, from: JSONEncoder().encode(result))
        #expect(di == input)
        #expect(dr == result)
    }
}

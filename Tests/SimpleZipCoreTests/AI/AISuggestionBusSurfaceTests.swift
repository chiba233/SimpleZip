//
//  AISuggestionBusSurfaceTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:主窗口「AI 建议层」surface(白皮书建议五)—— 它必须完全依赖模型输出,不许确定性兜底。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AISuggestionBusSurfaceTests {
    @Test func mainWindowSuggestionForbidsDeterministicFallback() {
        #expect(!AISuggestionSurfaceID.mainWindowSuggestion.allowsDeterministicFallback)
    }

    @Test func allOtherSurfacesAllowDeterministicFallback() {
        for surface in AISuggestionSurfaceID.allCases where surface != .mainWindowSuggestion {
            #expect(surface.allowsDeterministicFallback, "expected fallback allowed: \(surface)")
        }
    }

    @Test func surfaceRawValueStable() {
        #expect(AISuggestionSurfaceID.mainWindowSuggestion.rawValue == "mainWindowSuggestion")
    }
}

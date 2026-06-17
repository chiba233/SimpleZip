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
    /// 完全依赖模型输出、绝不确定性兜底的 surface(白皮书建议五 + #80 行内抽屉):主窗口 AI 建议层 + 文件浏览器行内抽屉。
    static let modelOnlySurfaces: Set<AISuggestionSurfaceID> = [.mainWindowSuggestion, .fileBrowserDrawer]

    @Test func modelOnlySurfacesForbidDeterministicFallback() {
        for surface in Self.modelOnlySurfaces {
            #expect(!surface.allowsDeterministicFallback, "expected model-only (no fallback): \(surface)")
        }
    }

    @Test func allOtherSurfacesAllowDeterministicFallback() {
        for surface in AISuggestionSurfaceID.allCases where !Self.modelOnlySurfaces.contains(surface) {
            #expect(surface.allowsDeterministicFallback, "expected fallback allowed: \(surface)")
        }
    }

    @Test func surfaceRawValueStable() {
        #expect(AISuggestionSurfaceID.mainWindowSuggestion.rawValue == "mainWindowSuggestion")
        #expect(AISuggestionSurfaceID.fileBrowserDrawer.rawValue == "fileBrowserDrawer")
    }
}

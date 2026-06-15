//
//  AISearchRewriteTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 搜索重写 → 确定性查询计划(白皮书 Feat 8)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AISearchRewriteTests {
    @Test func emptyRewriteIsEmpty() {
        #expect(AISearchRewrite().isEmpty)
        #expect(AISearchRewrite(keywords: ["x"]).isEmpty == false)
    }

    @Test func mapsSignalsIntoQueryPlan() {
        let rewrite = AISearchRewrite(
            semanticTags: ["signed-container-related"], markerFiles: ["signature.asc"],
            extensions: ["szs", "asc"], taskTags: ["signature-problem"],
            surfaces: [.archives, .archiveEntries, .tasks])
        let plan = rewrite.toQueryPlan()
        #expect(plan.semanticTags == ["signed-container-related"])
        #expect(plan.markerFiles == ["signature.asc"])
        #expect(plan.taskTags == ["signature-problem"])
        #expect(plan.keywords.contains(".szs"))
        #expect(plan.includeArchives)
        #expect(plan.includeArchiveEntries)
        #expect(plan.includeTasks)
        #expect(!plan.includeReports)
    }

    @Test func emptySurfacesDefaultToArchivesAndTasks() {
        let plan = AISearchRewrite(keywords: ["readme"]).toQueryPlan()
        #expect(plan.includeArchives)
        #expect(plan.includeTasks)
        #expect(!plan.includeArchiveEntries)
    }

    @Test func reportsSurfaceEnablesReports() {
        let plan = AISearchRewrite(keywords: ["x"], surfaces: [.reports]).toQueryPlan()
        #expect(plan.includeReports)
        #expect(!plan.includeArchives)
    }

    @Test func dottedExtensionsNotDoubleDotted() {
        let plan = AISearchRewrite(extensions: [".dmg"]).toQueryPlan()
        #expect(plan.keywords.contains(".dmg"))
        #expect(!plan.keywords.contains("..dmg"))
    }

    @Test func roundTripsThroughCodable() throws {
        let rewrite = AISearchRewrite(keywords: ["a"], semanticTags: ["release-artifact"],
                                      surfaces: [.archives, .reports])
        let data = try JSONEncoder().encode(rewrite)
        #expect(try JSONDecoder().decode(AISearchRewrite.self, from: data) == rewrite)
    }

    @Test func everySurfaceTokenIsStable() {
        for surface in AISearchSurface.allCases {
            #expect(!surface.rawValue.isEmpty)
        }
    }
}

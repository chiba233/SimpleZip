//
//  AIWorkspaceDynamicThemeTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AIWorkspaceDynamicTheme 单测 —— budget capping / reason round-trip / theme upsert
//  invariants / theme boundary mutation rules（白皮书建议四学习边界不对称规则:AI 可自动 add，绝不自动 remove）。
//

import Foundation
import Testing
@testable import SimpleZipCore

// MARK: - Budget

@Suite("AIThemeRefreshBudget")
struct AIThemeRefreshBudgetTests {

    @Test func defaultPresetsHaveSensibleLimits() {
        #expect(AIThemeRefreshBudget.normal.maxCandidates <= AIThemeRefreshBudget.aggressive.maxCandidates)
        #expect(AIThemeRefreshBudget.normal.maxUpserts <= AIThemeRefreshBudget.aggressive.maxUpserts)
        #expect(AIThemeRefreshBudget.normal.maxCandidates >= 1)
        #expect(AIThemeRefreshBudget.normal.maxUpserts >= 1)
    }

    @Test func initClampsNegativesToOne() {
        let b = AIThemeRefreshBudget(maxCandidates: 0, maxUpserts: -5, maxDismissedFingerprints: 0)
        #expect(b.maxCandidates == 1)
        #expect(b.maxUpserts == 1)
        #expect(b.maxDismissedFingerprints == 1)
    }
}

// MARK: - Job

private func makeThemeFingerprint(_ token: String) -> AIWorkspaceThemeFingerprint {
    AIWorkspaceThemeFingerprint(themeTokens: [token], sourceRefHashes: [],
                                dominantRoleTags: [], locationKinds: [])
}

@Suite("AIWorkspaceDynamicThemeJob")
struct AIWorkspaceDynamicThemeJobTests {

    @Test func schemaCodingRoundTrip() throws {
        let job = AIWorkspaceDynamicThemeJob(reason: .idleRefresh, themeCandidates: [])
        #expect(job.schema == "simplezip.ai.workspaceThemeRefresh.input.v1")
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(AIWorkspaceDynamicThemeJob.self, from: data)
        #expect(decoded.schema == job.schema)
        #expect(decoded.reason == .idleRefresh)
    }

    @Test func candidatesAreCappedByBudget() {
        let budget = AIThemeRefreshBudget(maxCandidates: 3, maxUpserts: 2)
        let candidates = (0..<10).map { i in
            AIWorkspaceThemeCandidate(id: "c\(i)", titleSeed: "t\(i)")
        }
        let job = AIWorkspaceDynamicThemeJob(reason: .taskFinished, themeCandidates: candidates, budget: budget)
        #expect(job.themeCandidates.count == 3)
    }

    @Test func dismissedFingerprintsAreCappedByBudget() {
        let budget = AIThemeRefreshBudget(maxCandidates: 5, maxUpserts: 2, maxDismissedFingerprints: 2)
        let fps = (0..<5).map { i in makeThemeFingerprint("tok\(i)") }
        let job = AIWorkspaceDynamicThemeJob(reason: .userFeedback, themeCandidates: [],
                                              dismissedFingerprints: fps, budget: budget)
        #expect(job.dismissedFingerprints.count == 2)
    }

    @Test func allRefreshReasonsRoundTrip() throws {
        let reasons: [AIThemeRefreshReason] = [.idleRefresh, .currentFolderChanged, .taskFinished,
                                               .userFeedback, .indexUpdated]
        for reason in reasons {
            let job = AIWorkspaceDynamicThemeJob(reason: reason, themeCandidates: [])
            let data = try JSONEncoder().encode(job)
            let decoded = try JSONDecoder().decode(AIWorkspaceDynamicThemeJob.self, from: data)
            #expect(decoded.reason == reason)
        }
    }
}

// MARK: - Result + Upsert

@Suite("AIWorkspaceDynamicThemeResult")
struct AIWorkspaceDynamicThemeResultTests {

    @Test func emptyResultIsEmpty() {
        let result = AIWorkspaceDynamicThemeResult()
        #expect(result.isEmpty)
        #expect(result.schema == "simplezip.ai.workspaceThemeRefresh.output.v1")
    }

    @Test func upsertWithWorkspaceIDIsRefresh() {
        let id = UUID()
        let fp = AIWorkspaceThemeFingerprint(themeTokens: ["release"], sourceRefHashes: [],
                                              dominantRoleTags: [], locationKinds: [])
        let upsert = AIWorkspaceThemeUpsert(workspaceID: id, title: "Release", fingerprint: fp,
                                            queryPlan: AIWorkspaceQueryPlan(), sourceRefs: [],
                                            reason: "refresh", confidence: 0.9)
        #expect(!upsert.isNewWorkspace)
        #expect(upsert.workspaceID == id)
    }

    @Test func upsertWithoutWorkspaceIDIsNew() {
        let fp = AIWorkspaceThemeFingerprint(themeTokens: ["new"], sourceRefHashes: [],
                                              dominantRoleTags: [], locationKinds: [])
        let upsert = AIWorkspaceThemeUpsert(workspaceID: nil, title: "New Theme", fingerprint: fp,
                                            queryPlan: AIWorkspaceQueryPlan(), sourceRefs: [],
                                            reason: "proactive", confidence: 0.75)
        #expect(upsert.isNewWorkspace)
    }

    @Test func upsertClampsTitleWhitespaceAndConfidence() {
        let fp = AIWorkspaceThemeFingerprint(themeTokens: [], sourceRefHashes: [],
                                              dominantRoleTags: [], locationKinds: [])
        let upsert = AIWorkspaceThemeUpsert(workspaceID: nil, title: "  My Theme  ", fingerprint: fp,
                                            queryPlan: AIWorkspaceQueryPlan(), sourceRefs: [],
                                            reason: "r", confidence: 1.5)
        #expect(upsert.title == "My Theme")
        #expect(upsert.confidence <= 1.0)

        let empty = AIWorkspaceThemeUpsert(workspaceID: nil, title: "   ", fingerprint: fp,
                                           queryPlan: AIWorkspaceQueryPlan(), sourceRefs: [],
                                           reason: "r", confidence: -1.0)
        #expect(!empty.title.isEmpty)  // falls back to placeholder
        #expect(empty.confidence >= 0.0)
    }
}

// MARK: - ThemeSeed

@Suite("AIWorkspaceThemeSeed")
struct AIWorkspaceThemeSeedTests {

    @Test func originRoundTrip() throws {
        let origins: [AIWorkspaceThemeSeed.Origin] = [
            .proactive, .userPrompt, .userAddedSources, .interactionDerived, .migratedLegacy
        ]
        for origin in origins {
            let seed = AIWorkspaceThemeSeed(origin: origin, createdAt: .distantPast)
            let data = try JSONEncoder().encode(seed)
            let decoded = try JSONDecoder().decode(AIWorkspaceThemeSeed.self, from: data)
            #expect(decoded.origin == origin)
        }
    }

    @Test func emptyPromptStoredAsNil() {
        let seed = AIWorkspaceThemeSeed(origin: .userPrompt, prompt: "   ", createdAt: .distantPast)
        #expect(seed.prompt == nil)
    }

    @Test func nonEmptyPromptPreserved() {
        let seed = AIWorkspaceThemeSeed(origin: .userPrompt, prompt: "Release materials",
                                         createdAt: .distantPast)
        #expect(seed.prompt == "Release materials")
    }
}

// MARK: - ThemeBoundary

@Suite("AIWorkspaceThemeBoundary")
struct AIWorkspaceThemeBoundaryTests {

    private let wid = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
    private let refA = AIContextSourceRef(kind: .file, id: "file-a")
    private let refB = AIContextSourceRef(kind: .archive, id: "arch-b")
    private let refC = AIContextSourceRef(kind: .task, id: "task-c")

    @Test func addingRefsMakesThemVisible() {
        let boundary = AIWorkspaceThemeBoundary(workspaceID: wid)
        let updated = boundary.addingRefs([refA, refB])
        #expect(updated.isVisible(refA))
        #expect(updated.isVisible(refB))
        #expect(updated.positiveExampleRefs.contains(refA))
        #expect(updated.autoAddedRefs.contains(refA))
    }

    @Test func removingRefsMakesThemInvisibleAndNegativeExample() {
        let boundary = AIWorkspaceThemeBoundary(workspaceID: wid)
            .addingRefs([refA, refB])
            .removingRefs([refA])
        #expect(!boundary.isVisible(refA))    // userRemoved → invisible
        #expect(boundary.isVisible(refB))
        #expect(boundary.negativeExampleRefs.contains(refA))
        #expect(!boundary.positiveExampleRefs.contains(refA))
    }

    @Test func removingRefAlsoUnpinsIt() {
        // Pin refA first, then remove it — must leave pinnedRefs.
        let boundary = AIWorkspaceThemeBoundary(workspaceID: wid,
                                                 pinnedRefs: [refA])
        let updated = boundary.removingRefs([refA])
        #expect(!updated.isPinned(refA))
        #expect(!updated.isVisible(refA))
    }

    // ⚠️ 白皮书核心不对称规则：AI 自动加入不能包含 userRemovedRefs。
    @Test func autoAddingDoesNotReviveUserRemovedRefs() {
        let boundary = AIWorkspaceThemeBoundary(workspaceID: wid)
            .removingRefs([refA])          // user explicitly removed refA
        let afterAutoAdd = boundary.autoAddingRefs([refA, refB])  // AI tries to re-add both
        #expect(!afterAutoAdd.isVisible(refA))   // refA stays invisible (user removed)
        #expect(afterAutoAdd.isVisible(refB))    // refB was never removed → OK to auto-add
    }

    @Test func addingPreviouslyRemovedRefRestoresVisibility() {
        // User removes, then manually re-adds (positive signal wins).
        let boundary = AIWorkspaceThemeBoundary(workspaceID: wid)
            .removingRefs([refA])
            .addingRefs([refA])
        #expect(boundary.isVisible(refA))       // explicit re-add restores
        #expect(!boundary.userRemovedRefs.contains(refA))
    }

    @Test func pinnedRefsAreVisible() {
        let boundary = AIWorkspaceThemeBoundary(workspaceID: wid, pinnedRefs: [refA])
        #expect(boundary.isPinned(refA))
        #expect(boundary.isVisible(refA))
    }

    @Test func codableRoundTrip() throws {
        let boundary = AIWorkspaceThemeBoundary(workspaceID: wid,
            includeSignals: ["release"], excludeSignals: [],
            preferredLocations: ["downloads"], preferredFileTypes: ["public.zip-archive"],
            positiveExampleRefs: [refA], negativeExampleRefs: [refC],
            autoAddedRefs: [refB], pinnedRefs: [refA], userRemovedRefs: [refC])
        let data = try JSONEncoder().encode(boundary)
        let decoded = try JSONDecoder().decode(AIWorkspaceThemeBoundary.self, from: data)
        #expect(decoded.workspaceID == wid)
        #expect(decoded.includeSignals == ["release"])
        #expect(decoded.positiveExampleRefs == [refA])
        #expect(decoded.negativeExampleRefs == [refC])
        #expect(decoded.autoAddedRefs == [refB])
        #expect(decoded.pinnedRefs == [refA])
        #expect(decoded.userRemovedRefs == [refC])
    }
}

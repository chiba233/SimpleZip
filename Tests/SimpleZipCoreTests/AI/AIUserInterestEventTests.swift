//
//  AIUserInterestEventTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:用户兴趣事件 —— 第一反应分类 + 偏好聚合(工程补充八)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIUserInterestEventTests {
    private func event(source: AIUserInterestEvent.Source, reaction: AIUserInterestEvent.FirstReaction?,
                       roles: [String] = [], locationKind: AILocationKind? = nil) -> AIUserInterestEvent {
        let location = locationKind.map {
            AILocationContext(kind: $0, pathHash: "loc-x", folderNameTokens: [])
        }
        return AIUserInterestEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            targetKind: .archive,
            sourceRef: AIContextSourceRef(kind: .archive, id: "arch-1"),
            source: source, openedAt: Date(timeIntervalSince1970: 0),
            firstReaction: reaction, contextLocation: location, visibleRoleTags: roles)
    }

    @Test func firstReactionClassification() {
        #expect(AIInterestClassifier.firstReaction(dwellSeconds: 5, action: nil) == .closedQuickly)
        #expect(AIInterestClassifier.firstReaction(dwellSeconds: 45, action: nil) == .stayed)
        #expect(AIInterestClassifier.firstReaction(dwellSeconds: 20, action: nil) == .noAction)
        #expect(AIInterestClassifier.firstReaction(dwellSeconds: 3, action: .tested) == .tested)
    }

    @Test func aggregatesReactionPreferencePerSourceAndRole() {
        let summary = AIInterestAggregator.summarize([
            event(source: .spotlight, reaction: .tested, roles: ["release-package"]),
            event(source: .spotlight, reaction: .tested, roles: ["release-package"]),
            event(source: .spotlight, reaction: .converted, roles: ["release-package"])
        ])
        let pref = summary.reactionPreferences.first { $0.source == "spotlight" && $0.roleTag == "release-package" }
        #expect(pref?.topReaction == "tested")
        #expect(pref?.count == 2)
    }

    @Test func aggregatesLocationAffinity() {
        let summary = AIInterestAggregator.summarize([
            event(source: .sidebar, reaction: .stayed, locationKind: .downloads),
            event(source: .sidebar, reaction: .stayed, locationKind: .downloads),
            event(source: .sidebar, reaction: .stayed, locationKind: .desktop)
        ])
        #expect(summary.locationAffinities.first?.locationKind == "downloads")
        #expect(summary.locationAffinities.first?.openCount == 2)
    }

    @Test func emptyEventsYieldEmptySummary() {
        #expect(AIInterestAggregator.summarize([]).isEmpty)
    }

    @Test func summaryIsDeterministic() {
        let events = [
            event(source: .spotlight, reaction: .tested, roles: ["release-package"], locationKind: .downloads),
            event(source: .finderOpen, reaction: .searched, roles: ["source-package"], locationKind: .projectFolder)
        ]
        #expect(AIInterestAggregator.summarize(events) == AIInterestAggregator.summarize(events))
    }

    @Test func codableRoundTrip() throws {
        let e = event(source: .spotlight, reaction: .tested, roles: ["release-package"], locationKind: .downloads)
        let data = try JSONEncoder().encode(e)
        let decoded = try JSONDecoder().decode(AIUserInterestEvent.self, from: data)
        #expect(decoded == e)
    }
}

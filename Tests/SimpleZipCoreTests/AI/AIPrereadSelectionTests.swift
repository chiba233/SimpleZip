//
//  AIPrereadSelectionTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 驱动的预读选择(按角色/近期/兴趣排序挑前 N,替代旧死规则)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIPrereadSelectionTests {
    private let loc = AILocationContext(kind: .projectFolder, pathHash: "loc-1", folderNameTokens: ["proj"])
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func rec(_ name: String, daysOld: Double = 0) -> AIFileMemoryRecord {
        AIFileMemoryRecord.make(fileName: name, isDirectory: false, byteSize: 100,
                                modifiedAt: now.addingTimeInterval(-daysOld * 86_400), location: loc)
    }

    @Test func picksTextSummarizableOnlyAndSkipsBinaryMedia() {
        let records = [rec("a.swift"), rec("logo.png"), rec("data.zip"), rec("tool.deb"), rec("notes.md")]
        let picked = AIPrereadSelection.selectForSummary(records: records, budget: 10, now: now)
        let names = Set(picked.map(\.fileName))
        #expect(names.contains("a.swift"))
        #expect(names.contains("notes.md"))
        #expect(!names.contains("logo.png"))   // 媒体不读
        #expect(!names.contains("data.zip"))   // 归档不读
        #expect(!names.contains("tool.deb"))   // 二进制不读
    }

    @Test func rolePriorityPutsProjectDocBeforeSource() {
        // README(project-doc, weight 3) 应排在普通源码(source, weight 1)之前。
        let picked = AIPrereadSelection.selectForSummary(
            records: [rec("util.swift"), rec("README.md")], budget: 1, now: now)
        #expect(picked.count == 1)
        #expect(picked.first?.fileName == "README.md")
    }

    @Test func recencyBreaksTieAmongSameRole() {
        // 两个同角色源码,近期改的优先。
        let picked = AIPrereadSelection.selectForSummary(
            records: [rec("old.swift", daysOld: 60), rec("fresh.swift", daysOld: 0)], budget: 1, now: now)
        #expect(picked.first?.fileName == "fresh.swift")
    }

    @Test func interestRoleBoostsMatchingFiles() {
        // 用户近期常碰 config → 同分下 config 被抬。给一个 config 和一个 source(权重 source>config),
        // 但 interest 命中 config 应把它抬过 source。
        let picked = AIPrereadSelection.selectForSummary(
            records: [rec("main.swift"), rec("app.yaml")], budget: 1, now: now,
            interestRoleTags: ["config"])
        #expect(picked.first?.fileName == "app.yaml")
    }

    @Test func budgetCapsCount() {
        let records = (0..<10).map { rec("doc\($0).md", daysOld: Double($0)) }
        #expect(AIPrereadSelection.selectForSummary(records: records, budget: 3, now: now).count == 3)
        #expect(AIPrereadSelection.selectForSummary(records: records, budget: 0, now: now).isEmpty)
    }

    @Test func deterministicSameInputSameOrder() {
        let records = [rec("README.md"), rec("a.swift", daysOld: 5), rec("b.yaml", daysOld: 2)]
        let first = AIPrereadSelection.selectForSummary(records: records, budget: 3, now: now).map(\.fileName)
        let second = AIPrereadSelection.selectForSummary(records: records, budget: 3, now: now).map(\.fileName)
        #expect(first == second)
    }
}

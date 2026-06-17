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
        // 纳入:文档 / 配置 / 无后缀文本(LICENSE)/ 未识别文本(.log)。排除:源码(3B 读不懂)/ 媒体 / 归档 / 二进制。
        let records = [rec("notes.md"), rec("app.yaml"), rec("LICENSE"), rec("server.log"),
                       rec("a.swift"), rec("logo.png"), rec("data.zip"), rec("tool.deb")]
        let picked = AIPrereadSelection.selectForSummary(records: records, budget: 10, now: now)
        let names = Set(picked.map(\.fileName))
        #expect(names.contains("notes.md"))
        #expect(names.contains("app.yaml"))
        #expect(names.contains("LICENSE"))      // 无后缀文本 → 纳入(unix 生态常见)
        #expect(names.contains("server.log"))   // 未识别文本 → 纳入
        #expect(!names.contains("a.swift"))     // 源码 → 排除(3B 读不懂代码)
        #expect(!names.contains("logo.png"))    // 媒体不读
        #expect(!names.contains("data.zip"))    // 归档不读
        #expect(!names.contains("tool.deb"))    // 二进制不读
    }

    @Test func excludesSourceCode() {
        // 各类源码 / 脚本都不预读。
        for name in ["main.swift", "app.ts", "util.py", "deploy.sh", "Component.vue"] {
            #expect(AIPrereadSelection.selectForSummary(records: [rec(name)], budget: 5, now: now).isEmpty,
                    "\(name) 是源码,不该预读")
        }
    }

    @Test func rolePriorityPutsProjectDocFirst() {
        // README(project-doc, weight 5) 应排在 config(weight 1.8)之前。
        let picked = AIPrereadSelection.selectForSummary(
            records: [rec("app.yaml"), rec("README.md")], budget: 1, now: now)
        #expect(picked.count == 1)
        #expect(picked.first?.fileName == "README.md")
    }

    @Test func recencyBreaksTieAmongSameRole() {
        // 两个同角色文本(reference-data .txt),近期改的优先。
        let picked = AIPrereadSelection.selectForSummary(
            records: [rec("old.txt", daysOld: 60), rec("fresh.txt", daysOld: 0)], budget: 1, now: now)
        #expect(picked.first?.fileName == "fresh.txt")
    }

    @Test func interestRoleBoostsMatchingFiles() {
        // 用户近期常碰 config → 兴趣加权把 config(1.8)抬过权重略高的 reference-data(notes.txt = 2.0):
        // config 1.8 + 兴趣 1.5 = 3.3 > reference-data 2.0。
        let picked = AIPrereadSelection.selectForSummary(
            records: [rec("notes.txt"), rec("app.yaml")], budget: 1, now: now,
            interestRoleTags: ["config"])
        #expect(picked.first?.fileName == "app.yaml")
    }

    @Test func selectArchivesForListingPicksArchivesByRecency() {
        // 只挑归档(文档/源码不进);同角色(archive)下近期改的先列。
        let records = [rec("notes.md"), rec("old.zip", daysOld: 40), rec("fresh.7z", daysOld: 0), rec("a.swift")]
        let picked = AIPrereadSelection.selectArchivesForListing(records: records, budget: 5, now: now)
        let names = picked.map(\.fileName)
        #expect(names == ["fresh.7z", "old.zip"])   // 只归档、近期在前
        #expect(!names.contains("notes.md"))
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

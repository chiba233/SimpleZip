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

    // MARK: - ②b/②c 模型驱动建议:评分 / 阈值 / 选择

    /// 给一条记录挂上「已预读(有结构摘要)」状态;`shortSummary` 非 nil = 模型摘要已产出。
    private func summarized(_ name: String, daysOld: Double = 200, shortSummary: String? = nil) -> AIFileMemoryRecord {
        rec(name, daysOld: daysOld)
            .withContentSummary(AIFileContentSummary(mode: "text-summary", shortSummary: shortSummary))
    }

    @Test func suggestionThresholdGatesByRole() {
        // 老文件(近期权重≈0)→ 只看角色:project-doc 过线;config / checksum 不过(拒绝给低价值文件白费模型)。
        let t = AIPrereadSelection.suggestionScoreThreshold
        #expect(AIPrereadSelection.suggestionScore(for: rec("README.md", daysOld: 200), now: now) >= t)
        #expect(AIPrereadSelection.suggestionScore(for: rec("app.yaml", daysOld: 200), now: now) < t)
        #expect(AIPrereadSelection.suggestionScore(for: rec("SHA256SUMS", daysOld: 200), now: now) < t)
    }

    @Test func recencyCanLiftFileOverThreshold() {
        // 同一个 config 文件:很旧时不过线;刚改时近期加权(+2)把它抬过阈值。
        let t = AIPrereadSelection.suggestionScoreThreshold
        #expect(AIPrereadSelection.suggestionScore(for: rec("app.yaml", daysOld: 200), now: now) < t)
        #expect(AIPrereadSelection.suggestionScore(for: rec("app.yaml", daysOld: 0), now: now) >= t)
    }

    @Test func modelSuggestionSelectionRequiresPrereadAndThreshold() {
        // 过线但还没预读(无 contentSummary)→ 不选;有结构摘要且模型摘要还没出 → 选。
        #expect(AIPrereadSelection.selectForModelSuggestion(
            records: [rec("README.md", daysOld: 200)], budget: 5, now: now).isEmpty)
        #expect(AIPrereadSelection.selectForModelSuggestion(
            records: [summarized("README.md")], budget: 5, now: now).count == 1)
    }

    @Test func modelSuggestionSelectionSkipsAlreadyDone() {
        // 模型摘要已写回(shortSummary 非空)→ 不重做(渐进覆盖:指纹变了阶段一会清回 nil 才重选)。
        #expect(AIPrereadSelection.selectForModelSuggestion(
            records: [summarized("README.md", shortSummary: "已有摘要")], budget: 5, now: now).isEmpty)
    }

    @Test func modelSuggestionSelectionExcludesBelowThresholdAndSource() {
        let lowConfig = summarized("app.yaml")                       // config 1.8 < 2.5(老文件)→ 排除
        let source = rec("main.swift", daysOld: 0)                   // 源码 eligibility 排除(3B 读不懂)
            .withContentSummary(AIFileContentSummary(mode: "text-summary"))
        #expect(AIPrereadSelection.selectForModelSuggestion(
            records: [lowConfig, source], budget: 5, now: now).isEmpty)
    }

    @Test func withModelSuggestionRoundTrip() {
        let base = AIFileContentSummary(mode: "text-summary", headings: ["H"], redactionCount: 1)
        #expect(!base.hasModelSuggestion)
        let updated = base.withModelSuggestion(summary: "一句话",
                                               actions: [AIFileSuggestedAction(token: "hash")])
        #expect(updated.shortSummary == "一句话")
        #expect(updated.suggestedActions == [AIFileSuggestedAction(token: "hash")])
        #expect(updated.headings == ["H"])       // 结构信号不变
        #expect(updated.redactionCount == 1)
        #expect(updated.hasModelSuggestion)
    }

    @Test func suggestedActionRoundTripsPayload() throws {
        // 带 payload 的动作(openWith→app bundleId + 名字)Codable 往返不丢。
        let action = AIFileSuggestedAction(token: "openWith", payload: "com.apple.Preview", label: "Preview")
        let summary = AIFileContentSummary(mode: "metadata-only", shortSummary: "一张图", suggestedActions: [action])
        let round = try JSONDecoder().decode(AIFileContentSummary.self,
                                             from: JSONEncoder().encode(summary))
        #expect(round.suggestedActions == [action])
        #expect(round.suggestedActions.first?.payload == "com.apple.Preview")
    }

    @Test func contentSummaryDecodesLegacy() throws {
        // ① 旧缓存完全没有动作字段 → []。
        let bare = #"{"mode":"text-summary","headings":["A"],"fieldNames":[],"redactionCount":0}"#.data(using: .utf8)!
        let d1 = try JSONDecoder().decode(AIFileContentSummary.self, from: bare)
        #expect(d1.suggestedActions.isEmpty)
        #expect(d1.headings == ["A"])
        #expect(!d1.hasModelSuggestion)
        // ② 旧缓存的 [String] token 字段 → 升级成无 payload 的结构化动作(不丢)。
        let legacyTokens = #"{"mode":"text-summary","suggestedActionTokens":["hash","compress"],"redactionCount":0}"#.data(using: .utf8)!
        let d2 = try JSONDecoder().decode(AIFileContentSummary.self, from: legacyTokens)
        #expect(d2.suggestedActions == [AIFileSuggestedAction(token: "hash"), AIFileSuggestedAction(token: "compress")])
        #expect(d2.hasModelSuggestion)
    }

    // MARK: - 磁盘镜像安装建议选择(backlog 第2项:推荐打开方式之后)

    /// 带真实路径的 dmg 记录;`summarized` = 已评估过(写过 disk-image 摘要)。
    private func dmg(_ name: String, daysOld: Double = 0, summarized: Bool = false,
                     hasPath: Bool = true) -> AIFileMemoryRecord {
        let base = AIFileMemoryRecord.make(
            fileName: name, isDirectory: false, byteSize: 100,
            modifiedAt: now.addingTimeInterval(-daysOld * 86_400), location: loc,
            path: hasPath ? "/tmp/\(name)" : nil)
        return summarized ? base.withContentSummary(AIFileContentSummary(mode: "disk-image")) : base
    }

    @Test func selectsUnevaluatedDiskImagesWithPathByRecency() {
        let records = [
            dmg("Recent.dmg", daysOld: 0),
            dmg("Old.dmg", daysOld: 40),
            dmg("Done.dmg", summarized: true),       // 已评估(有 contentSummary)→ 排除
            dmg("NoPath.dmg", hasPath: false),       // 无路径(7zz peek 没法跑)→ 排除
            rec("notes.md"),                         // 非磁盘镜像 → 排除
        ]
        let picked = AIPrereadSelection.selectDiskImagesForSuggestion(records: records, budget: 5, now: now)
        let names = picked.map(\.fileName)
        #expect(names.contains("Recent.dmg"))
        #expect(names.contains("Old.dmg"))
        #expect(!names.contains("Done.dmg"))
        #expect(!names.contains("NoPath.dmg"))
        #expect(!names.contains("notes.md"))
        #expect(picked.first?.fileName == "Recent.dmg")   // installer 角色权重低 → 近期主导,近的在前
    }

    @Test func diskImageSelectionRespectsBudget() {
        let records = (0..<6).map { dmg("img\($0).dmg", daysOld: Double($0)) }
        #expect(AIPrereadSelection.selectDiskImagesForSuggestion(records: records, budget: 2, now: now).count == 2)
        #expect(AIPrereadSelection.selectDiskImagesForSuggestion(records: records, budget: 0, now: now).isEmpty)
    }
}

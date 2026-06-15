//
//  AIWorkspaceUserSeedTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:用户 AI 文件夹种子 + 拆分组(白皮书建议四扩写)。
//  种子是「会派生」的而非静态收藏;拆分组校验失败不生成新工作区。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIWorkspaceUserSeedTests {
    private let ws = AIStableHash.deterministicUUID("ws-paper")
    private let f1 = AIContextSourceRef(kind: .file, id: "file-1")
    private let f2 = AIContextSourceRef(kind: .file, id: "file-2")
    private let invented = AIContextSourceRef(kind: .file, id: "file-INVENTED")
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)

    private func seed() -> AIWorkspaceUserSeed {
        AIWorkspaceUserSeed(workspaceID: ws, userTitle: "我的论文",
                            pinnedSourceRefs: [f1, f2], createdAt: t0, updatedAt: t0)
    }

    // MARK: - 种子调教

    @Test func addingThemePromptDedupesAndBumpsUpdatedAt() {
        let s = seed()
            .addingThemePrompt("把论文相关都放一起", updatedAt: t1)
            .addingThemePrompt("把论文相关都放一起", updatedAt: t1)   // 重复
            .addingThemePrompt("   ", updatedAt: t1)                  // 空白丢弃
        #expect(s.themePrompts == ["把论文相关都放一起"])
        #expect(s.updatedAt == t1)
        #expect(s.createdAt == t0)                                   // createdAt 不变
    }

    @Test func excludingMovesRefOutOfPinned() {
        let s = seed().excluding([f1], updatedAt: t1)
        #expect(s.isExcluded(f1))
        #expect(!s.pinnedSourceRefs.contains(f1))                    // 排除即从固定集移除
        #expect(s.pinnedSourceRefs.contains(f2))
        #expect(s.updatedAt == t1)
    }

    @Test func excludingIsDeduped() {
        let s = seed().excluding([f1], updatedAt: t1).excluding([f1], updatedAt: t1)
        #expect(s.excludedSourceRefs == [f1])
    }

    @Test func userSeedCodableRoundTrips() throws {
        let s = seed().addingThemePrompt("发布相关", updatedAt: t1)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AIWorkspaceUserSeed.self, from: data)
        #expect(back == s)
    }

    // MARK: - 拆分组校验

    @Test func sanitizeKeepsOnlyCandidateRefs() {
        let groups = [
            AIWorkspaceSplitGroup(title: "文稿", sourceRefs: [f1, invented]),  // 部分非法
            AIWorkspaceSplitGroup(title: "全非法", sourceRefs: [invented])      // 全非法 → 丢弃
        ]
        let out = AIWorkspaceSplitGroup.sanitized(groups, allowed: [f1, f2])
        #expect(out.count == 1)
        #expect(out[0].title == "文稿")
        #expect(out[0].sourceRefs == [f1])                          // invented 被剔除
    }

    @Test func sanitizeAllInvalidYieldsEmpty() {
        // 全部组都被清空 → 返回 [],调用点据此不生成新工作区。
        let groups = [AIWorkspaceSplitGroup(title: "x", sourceRefs: [invented])]
        #expect(AIWorkspaceSplitGroup.sanitized(groups, allowed: [f1, f2]).isEmpty)
    }
}

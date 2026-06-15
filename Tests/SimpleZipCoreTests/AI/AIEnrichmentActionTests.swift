//
//  AIEnrichmentActionTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 只读数据增强动作 —— 候选集校验 + 增强门控 + 结果回填。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIEnrichmentActionTests {
    private let archRef = AIContextSourceRef(kind: .archive, id: "arch-1")
    private let fileRef = AIContextSourceRef(kind: .file, id: "file-1")
    private let invented = AIContextSourceRef(kind: .archive, id: "arch-INVENTED")

    // MARK: - 动作基本性质

    @Test func kindAndRefsExposed() {
        let a = AIReadOnlyEnrichmentAction.calculateHashes(sourceRefs: [fileRef], algorithms: [.sha256])
        #expect(a.kind == "calculate-hashes")
        #expect(a.sourceRefs == [fileRef])
        #expect(a.isReadOnlyDataEnrichment)
        #expect(a.requiresUserClickInForeground)
    }

    @Test func actionIDDeterministicAndRefOrderIndependent() {
        let r1 = AIContextSourceRef(kind: .file, id: "a")
        let r2 = AIContextSourceRef(kind: .file, id: "b")
        let x = AIReadOnlyEnrichmentAction.testArchives(sourceRefs: [r1, r2])
        let y = AIReadOnlyEnrichmentAction.testArchives(sourceRefs: [r2, r1])
        #expect(x.actionID == y.actionID)        // ref 顺序无关
        #expect(x.actionID.hasPrefix("enrich-test-archives-"))
        // 不同 kind → 不同 id
        let z = AIReadOnlyEnrichmentAction.refreshArchiveListing(sourceRefs: [r1, r2])
        #expect(z.actionID != x.actionID)
    }

    @Test func codableRoundTrips() throws {
        let a = AIReadOnlyEnrichmentAction.calculateHashes(sourceRefs: [fileRef], algorithms: [.sha256, .crc32])
        let data = try JSONEncoder().encode(a)
        let back = try JSONDecoder().decode(AIReadOnlyEnrichmentAction.self, from: data)
        #expect(back == a)
    }

    // MARK: - 候选集校验(模型不能凭空指定路径)

    @Test func sanitizeDropsInventedRefs() {
        let actions: [AIReadOnlyEnrichmentAction] = [
            .testArchives(sourceRefs: [archRef, invented]),     // 部分非法 → 保留合法部分
            .refreshArchiveListing(sourceRefs: [invented])      // 全非法 → 整条丢弃
        ]
        let out = AIEnrichmentGate.sanitized(actions, allowed: [archRef, fileRef])
        #expect(out.count == 1)
        #expect(out[0].kind == "test-archives")
        #expect(out[0].sourceRefs == [archRef])                 // invented 被剔除
    }

    @Test func sanitizePreservesAlgorithms() {
        let a = AIReadOnlyEnrichmentAction.calculateHashes(sourceRefs: [fileRef, invented], algorithms: [.sha512])
        let out = AIEnrichmentGate.sanitized([a], allowed: [fileRef])
        #expect(out.count == 1)
        if case let .calculateHashes(refs, algos) = out[0] {
            #expect(refs == [fileRef])
            #expect(algos == [.sha512])                         // 算法在剔 ref 后保留
        } else { Issue.record("expected calculateHashes") }
    }

    // MARK: - 增强门控(加密 / 无权限 / 排除 / 敏感目录)

    @Test func enrichmentAllowedForNormalReadableFile() {
        #expect(AIEnrichmentGate.blockReason(
            absolutePath: "/Users/yumeka/Desktop/release.7z", currentUserCanRead: true,
            isExcludedByUser: false, isEncryptedArchive: false) == nil)
    }

    @Test func enrichmentBlockedReasons() {
        #expect(AIEnrichmentGate.blockReason(
            absolutePath: "/x/a.7z", currentUserCanRead: false,
            isExcludedByUser: false, isEncryptedArchive: false) == .noReadPermission)
        #expect(AIEnrichmentGate.blockReason(
            absolutePath: "/x/a.7z", currentUserCanRead: true,
            isExcludedByUser: true, isEncryptedArchive: false) == .excludedByUser)
        #expect(AIEnrichmentGate.blockReason(
            absolutePath: "/x/secret.7z", currentUserCanRead: true,
            isExcludedByUser: false, isEncryptedArchive: true) == .encryptedArchive)
        #expect(AIEnrichmentGate.blockReason(
            absolutePath: "/Users/yumeka/.gnupg/key.7z", currentUserCanRead: true,
            isExcludedByUser: false, isEncryptedArchive: false) == .sensitiveDirectory)
        #expect(AIEnrichmentGate.blockReason(
            absolutePath: "/private/var/folders/x/SimpleZip-tmp/a.7z", currentUserCanRead: true,
            isExcludedByUser: false, isEncryptedArchive: false) == .decryptTempDirectory)
    }

    @Test func enrichmentAllowsSecretLookingNameHashOnly() {
        // 哈希只产摘要、不存内容,所以「疑似密钥文件名」不挡增强(与内容可读性门控有别)。
        #expect(AIEnrichmentGate.blockReason(
            absolutePath: "/Users/yumeka/Desktop/server.key", currentUserCanRead: true,
            isExcludedByUser: false, isEncryptedArchive: false) == nil)
    }

    // MARK: - 结果回填

    @Test func resultCapturesActionIdentity() {
        let action = AIReadOnlyEnrichmentAction.computeArchiveFingerprint(sourceRefs: [archRef])
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 1_002)
        let result = AIEnrichmentResult(action: action, startedAt: start, completedAt: end,
                                        producedSignals: ["fingerprint-computed"])
        #expect(result.generatedByActionID == action.actionID)
        #expect(result.actionKind == "compute-archive-fingerprint")
        #expect(result.sourceRefs == [archRef])
        #expect(result.producedSignals == ["fingerprint-computed"])
        #expect(result.completedAt > result.startedAt)
    }
}

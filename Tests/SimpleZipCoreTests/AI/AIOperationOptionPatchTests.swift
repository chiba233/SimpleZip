//
//  AIOperationOptionPatchTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:创建/解压 Auto-Tune 安全核心 —— 字段策略表 + 安全闸(白皮书「Operation Auto-Tune」)。
//  重点是**安全断言**:密码 / GPG / 删源 / 移废纸篓等永不被自动改;碰加密内容整条丢;防覆盖用户手改。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIOperationOptionPatchTests {

    // MARK: - 字段策略表

    @Test func createFieldPolicies() {
        #expect(AIOperationFieldCatalog.policy(scope: .create, fieldID: "compressionLevel") == .safeAutoApply)
        #expect(AIOperationFieldCatalog.policy(scope: .create, fieldID: "reproducibleArchive") == .safeAutoApply)
        #expect(AIOperationFieldCatalog.policy(scope: .create, fieldID: "encryptionMethod") == .cautiousAutoApply)
        #expect(AIOperationFieldCatalog.policy(scope: .create, fieldID: "password") == .suggestOnly)
        #expect(AIOperationFieldCatalog.policy(scope: .create, fieldID: "gpgSymmetricPassphrase") == .suggestOnly)
        #expect(AIOperationFieldCatalog.policy(scope: .create, fieldID: "sevenZipDeleteSourceFiles") == .suggestOnly)
    }

    @Test func extractFieldPolicies() {
        #expect(AIOperationFieldCatalog.policy(scope: .extract, fieldID: "skipJunk") == .safeAutoApply)
        #expect(AIOperationFieldCatalog.policy(scope: .extract, fieldID: "stripSingleRootFolder") == .safeAutoApply)
        #expect(AIOperationFieldCatalog.policy(scope: .extract, fieldID: "trashOriginalWhenDone") == .suggestOnly)
        #expect(AIOperationFieldCatalog.policy(scope: .extract, fieldID: "destinationURL") == .suggestOnly)
        #expect(AIOperationFieldCatalog.policy(scope: .extract, fieldID: "gpgDecryptionPassphrase") == .suggestOnly)
    }

    @Test func unknownFieldDefaultsToSuggestOnly() {
        // 不在白名单的字段一律最保守 —— 新字段不会意外被自动写。
        #expect(AIOperationFieldCatalog.policy(scope: .create, fieldID: "brandNewSecretField") == .suggestOnly)
        #expect(AIOperationFieldCatalog.policy(scope: .extract, fieldID: "somethingUnlisted") == .suggestOnly)
    }

    @Test func allowsAutoApplyMatrix() {
        // safeAutoApply 字段:safe + aggressive 模式可自动,off/suggestOnly 不行。
        #expect(!AIOperationFieldCatalog.allowsAutoApply(scope: .create, fieldID: "compressionLevel", mode: .off))
        #expect(!AIOperationFieldCatalog.allowsAutoApply(scope: .create, fieldID: "compressionLevel", mode: .suggestOnly))
        #expect(AIOperationFieldCatalog.allowsAutoApply(scope: .create, fieldID: "compressionLevel", mode: .autoApplySafe))
        #expect(AIOperationFieldCatalog.allowsAutoApply(scope: .create, fieldID: "compressionLevel", mode: .autoApplyAggressive))
        // cautiousAutoApply 字段:仅 aggressive 可自动。
        #expect(!AIOperationFieldCatalog.allowsAutoApply(scope: .create, fieldID: "encryptionMethod", mode: .autoApplySafe))
        #expect(AIOperationFieldCatalog.allowsAutoApply(scope: .create, fieldID: "encryptionMethod", mode: .autoApplyAggressive))
    }

    @Test func suggestOnlyFieldsNeverAutoApplyInAnyMode() {
        // 安全红线:密码 / GPG / 删源 / 移废纸篓 等在任何模式都不能自动改。
        let redlines: [(AIOperationScope, String)] = [
            (.create, "password"), (.create, "gpgRecipientFingerprints"), (.create, "gpgSymmetricPassphrase"),
            (.create, "sevenZipDeleteSourceFiles"), (.create, "rawParameters"), (.create, "customExcludes"),
            (.create, "destinationURL"),
            (.extract, "password"), (.extract, "gpgDecryptionPassphrase"),
            (.extract, "trashOriginalWhenDone"), (.extract, "destinationURL"),
        ]
        for mode in AIOperationAutoTuneMode.allCases {
            for (scope, field) in redlines {
                #expect(!AIOperationFieldCatalog.allowsAutoApply(scope: scope, fieldID: field, mode: mode),
                        "\(field) 在 \(mode.rawValue) 下绝不能自动改")
            }
        }
    }

    @Test func safeAutoApplyFieldsSorted() {
        let fields = AIOperationFieldCatalog.safeAutoApplyFields(scope: .extract)
        #expect(fields == fields.sorted())
        #expect(fields.contains("skipJunk"))
        #expect(!fields.contains("trashOriginalWhenDone"))
    }

    // MARK: - 安全闸 resolve

    private func change(_ field: String, from: String, to: String,
                        safety: AISuggestionSafety = .safe, explicit: Bool = false) -> AIOperationOptionPatch.Change {
        .init(fieldID: field, fromValue: from, toValue: to, reason: "test",
              safety: safety, requiresExplicitClick: explicit)
    }

    @Test func resolveAutoAppliesSafeFieldWhenFromValueMatches() {
        let patch = AIOperationOptionPatch(scope: .extract, patchID: "p1", title: "t", changes: [
            change("skipJunk", from: "false", to: "true"),
        ])
        let r = AIOperationAutoTuneEngine.resolve(
            patch, mode: .autoApplySafe, currentValues: ["skipJunk": "false"], userTouchedFields: [])
        #expect(r.autoApply.map { $0.fieldID } == ["skipJunk"])
        #expect(r.suggestOnly.isEmpty && r.rejected.isEmpty)
    }

    @Test func resolveOffModeYieldsEmpty() {
        let patch = AIOperationOptionPatch(scope: .extract, patchID: "p", title: "t", changes: [
            change("skipJunk", from: "false", to: "true"),
        ])
        let r = AIOperationAutoTuneEngine.resolve(
            patch, mode: .off, currentValues: ["skipJunk": "false"], userTouchedFields: [])
        #expect(r == .empty)
    }

    @Test func resolveRejectsWhenFromValueStale() {
        // fromValue 与当前表单值不符 → 拒绝(用户刚手改过,或建议过时)。
        let patch = AIOperationOptionPatch(scope: .extract, patchID: "p", title: "t", changes: [
            change("skipJunk", from: "false", to: "true"),
        ])
        let r = AIOperationAutoTuneEngine.resolve(
            patch, mode: .autoApplySafe, currentValues: ["skipJunk": "true"], userTouchedFields: [])
        #expect(r.autoApply.isEmpty && r.suggestOnly.isEmpty)
        #expect(r.rejected.map { $0.fieldID } == ["skipJunk"])
    }

    @Test func resolveRejectsUserTouchedField() {
        let patch = AIOperationOptionPatch(scope: .extract, patchID: "p", title: "t", changes: [
            change("skipJunk", from: "false", to: "true"),
        ])
        let r = AIOperationAutoTuneEngine.resolve(
            patch, mode: .autoApplySafe, currentValues: ["skipJunk": "false"], userTouchedFields: ["skipJunk"])
        #expect(r.rejected.map { $0.fieldID } == ["skipJunk"])
        #expect(r.autoApply.isEmpty)
    }

    @Test func resolveRejectsEncryptedContentChange() {
        let patch = AIOperationOptionPatch(scope: .extract, patchID: "p", title: "t", changes: [
            change("skipJunk", from: "false", to: "true",
                   safety: AISuggestionSafety(touchesEncryptedContent: true)),
        ])
        let r = AIOperationAutoTuneEngine.resolve(
            patch, mode: .autoApplySafe, currentValues: ["skipJunk": "false"], userTouchedFields: [])
        #expect(r.rejected.map { $0.fieldID } == ["skipJunk"])
    }

    @Test func resolvePasswordNeverAutoAppliesEvenAggressive() {
        // 安全核心断言:密码 change 即使 mode=aggressive、fromValue 匹配、没碰过,也只进 suggestOnly,绝不 autoApply。
        let patch = AIOperationOptionPatch(scope: .create, patchID: "p", title: "t", changes: [
            change("password", from: "", to: "hunter2"),
        ])
        let r = AIOperationAutoTuneEngine.resolve(
            patch, mode: .autoApplyAggressive, currentValues: ["password": ""], userTouchedFields: [])
        #expect(r.autoApply.isEmpty)
        #expect(r.suggestOnly.map { $0.fieldID } == ["password"])
    }

    @Test func resolveExplicitClickAndDestructiveGoToSuggestOnly() {
        let patch = AIOperationOptionPatch(scope: .extract, patchID: "p", title: "t", changes: [
            change("skipJunk", from: "false", to: "true", explicit: true),
            change("autoRenameConflicts", from: "false", to: "true",
                   safety: AISuggestionSafety(destructive: true, requiresConfirmation: true)),
        ])
        let r = AIOperationAutoTuneEngine.resolve(
            patch, mode: .autoApplyAggressive,
            currentValues: ["skipJunk": "false", "autoRenameConflicts": "false"], userTouchedFields: [])
        #expect(r.autoApply.isEmpty)
        #expect(Set(r.suggestOnly.map { $0.fieldID }) == ["skipJunk", "autoRenameConflicts"])
    }

    @Test func patchCodableRoundTrip() throws {
        let patch = AIOperationOptionPatch(scope: .create, patchID: "p", title: "已按发布包调整", changes: [
            change("reproducibleArchive", from: "false", to: "true"),
        ], rejectedChanges: ["password: never auto-filled"])
        let decoded = try JSONDecoder().decode(
            AIOperationOptionPatch.self, from: JSONEncoder().encode(patch))
        #expect(decoded == patch)
    }
}

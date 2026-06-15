//
//  AISuggestionActionSafetyTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AISuggestionAction 扩容后的**按 case 安全分级**(白皮书建议四扩写)。
//  红线:写盘 / 启动任务一律 requiresConfirmation;删盘 destructive,绝不当 primaryAction(sanitizer 硬剥离)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AISuggestionActionSafetyTests {
    private let ws = AIStableHash.deterministicUUID("ws")
    private let ref = AIContextSourceRef(kind: .file, id: "file-1")

    // MARK: - 分级

    @Test func readOnlyAndVirtualActionsAreDirectlySafe() {
        let safe: [AISuggestionAction] = [
            .applySelection(paths: ["/x"]),
            .revealSourceRefsInFinder(sourceRefs: [ref]),
            .openWithApplication(sourceRefs: [ref], bundleIdentifier: "com.microsoft.VSCode"),
            .setWorkspacePreferredOpenApp(workspaceID: ws, bundleIdentifier: "com.apple.dt.Xcode"),
            .mergeAIWorkspaces(sourceWorkspaceIDs: [ws], title: "合并"),
            .splitAIWorkspace(workspaceID: ws, groups: []),
            .removeSourceRefsFromAIWorkspace(workspaceID: ws, sourceRefs: [ref]),
            .moveVirtualNodes(workspaceID: ws, nodeIDs: ["n1"], destinationVirtualFolderID: "g1"),
            .addSourceRefsToAIWorkspace(workspaceID: ws, sourceRefs: [ref]),
            .addThemePromptToAIWorkspace(workspaceID: ws, prompt: "论文")
        ]
        for a in safe {
            #expect(a.isDirectlySafe, "expected directly safe: \(a)")
            #expect(!a.isDestructive)
            #expect(!a.requiresConfirmation)
        }
    }

    @Test func writeOrTaskActionsRequireConfirmationButNotDestructive() {
        let confirm: [AISuggestionAction] = [
            .calculateHash(paths: ["/x"], algorithms: ["sha256"]),
            .calculateHashForEvidence(sourceRefs: [ref], algorithms: ["sha256"]),
            .createArchive(paths: ["/x"]),
            .createArchiveFromSuggestion(paths: ["/x"], suggestedFormat: "7z", suggestedPresetID: nil),
            .testArchive(path: "/x.7z"),
            .testArchiveForEvidence(sourceRef: ref),
            .convertArchive(path: "/x.zip"),
            .inspectRelease(path: "/x"),
            .refreshArchiveListingForEvidence(sourceRef: ref),
            .copySourceRefsToFolder(sourceRefs: [ref], destination: "/dest"),
            .deleteAIWorkspace(workspaceID: ws)
        ]
        for a in confirm {
            #expect(a.requiresConfirmation, "expected requiresConfirmation: \(a)")
            #expect(!a.isDirectlySafe)
            #expect(!a.isDestructive, "write/task action must not be destructive: \(a)")
        }
    }

    @Test func deleteFromDiskIsDestructiveAndConfirmed() {
        let del = AISuggestionAction.deleteSourceRefsFromDisk(sourceRefs: [ref])
        #expect(del.isDestructive)
        #expect(del.requiresConfirmation)
        #expect(!del.isDirectlySafe)
        #expect(!del.safety.isAllowedInV1)        // 破坏性动作连节点安全闸都过不了
    }

    // MARK: - 旧 case 仍直接安全(不回归)

    @Test func legacyActionsRemainDirectlySafe() {
        let legacy: [AISuggestionAction] = [
            .openTask(ws), .openFolder(path: "/x"), .revealFile(path: "/x/a"),
            .openArchive(path: "/x/a.zip", revealEntry: "README.md"),
            .openReport(taskID: ws), .explainFailure(taskID: ws), .openActivityCenter,
            .pinRecommendedWorkspace(ws), .dismissRecommendedWorkspace(ws)
        ]
        #expect(legacy.allSatisfy { $0.isDirectlySafe })
    }

    // MARK: - sanitizer 硬剥离破坏性 primaryAction

    @Test func sanitizerStripsDestructivePrimaryActionButKeepsNode() {
        let node = AIVirtualNode(
            id: AIStableHash.deterministicUUID("n"), kind: .file, title: "raw-data.csv",
            sourceRefs: [ref],
            primaryAction: .deleteSourceRefsFromDisk(sourceRefs: [ref]),
            secondaryActions: [.revealSourceRefsInFinder(sourceRefs: [ref])])
        let clean = AIVirtualTreeSanitizer.sanitize([node], allowed: [ref])
        #expect(clean.count == 1)                       // 节点保留
        #expect(clean[0].primaryAction == nil)          // 破坏性 primary 被剥离
        #expect(clean[0].secondaryActions.count == 1)   // 次级安全动作保留
    }

    @Test func sanitizerKeepsNonDestructivePrimaryAction() {
        let node = AIVirtualNode(
            id: AIStableHash.deterministicUUID("n2"), kind: .group, title: "长期未动的大文件",
            sourceRefs: [ref],
            primaryAction: .createArchiveFromSuggestion(paths: ["/x"], suggestedFormat: "7z", suggestedPresetID: nil))
        let clean = AIVirtualTreeSanitizer.sanitize([node], allowed: [ref])
        #expect(clean.count == 1)
        #expect(clean[0].primaryAction != nil)          // 需确认但非破坏 → 可当 primary(打开创建表单)
    }

    // MARK: - 新 case Codable

    @Test func newCasesCodableRoundTrip() throws {
        let group = AIWorkspaceSplitGroup(title: "文稿", sourceRefs: [ref], themePrompt: "doc")
        let actions: [AISuggestionAction] = [
            .splitAIWorkspace(workspaceID: ws, groups: [group]),
            .deleteSourceRefsFromDisk(sourceRefs: [ref]),
            .calculateHash(paths: ["/x"], algorithms: ["sha256", "crc32"])
        ]
        for a in actions {
            let data = try JSONEncoder().encode(a)
            #expect(try JSONDecoder().decode(AISuggestionAction.self, from: data) == a)
        }
    }
}

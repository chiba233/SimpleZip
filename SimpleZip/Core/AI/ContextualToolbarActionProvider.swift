//
//  ContextualToolbarActionProvider.swift
//  SimpleZip
//
//  0.4.5 #80: deterministic main-toolbar action candidates. This preserves
//  the old ContextualToolbarButtons behavior while moving the branch logic into
//  a testable provider that can later accept usage signals and AI hints.
//

import Foundation

nonisolated struct ContextualToolbarSnapshot: Codable, Equatable, Sendable {
    nonisolated enum Mode: String, Codable, Equatable, Sendable {
        case archive
        case folder
        case tag
        case aiWorkspace
    }

    nonisolated struct SelectedFile: Codable, Equatable, Sendable {
        let name: String
        let pathExtension: String
        let isDirectory: Bool
        let isSupportedArchive: Bool

        init(name: String, pathExtension: String, isDirectory: Bool, isSupportedArchive: Bool) {
            self.name = name
            self.pathExtension = pathExtension.lowercased()
            self.isDirectory = isDirectory
            self.isSupportedArchive = isSupportedArchive
        }
    }

    let mode: Mode
    let selectedArchiveItemCount: Int
    let canEditArchiveComment: Bool
    let canDropIntoOpenArchive: Bool
    let selectedFiles: [SelectedFile]
    let clipboardHasFiles: Bool
    let gpgUIAvailable: Bool

    init(mode: Mode,
         selectedArchiveItemCount: Int = 0,
         canEditArchiveComment: Bool = false,
         canDropIntoOpenArchive: Bool = false,
         selectedFiles: [SelectedFile] = [],
         clipboardHasFiles: Bool = false,
         gpgUIAvailable: Bool = false) {
        self.mode = mode
        self.selectedArchiveItemCount = selectedArchiveItemCount
        self.canEditArchiveComment = canEditArchiveComment
        self.canDropIntoOpenArchive = canDropIntoOpenArchive
        self.selectedFiles = selectedFiles
        self.clipboardHasFiles = clipboardHasFiles
        self.gpgUIAvailable = gpgUIAvailable
    }
}

nonisolated struct ContextualToolbarAction: Identifiable, Codable, Equatable, Sendable {
    nonisolated enum ID: String, Codable, Equatable, CaseIterable, Sendable {
        case archiveFindDuplicates
        case archiveEditComment
        case archiveSecurityReport
        case archiveBatchRename
        case archiveDeleteEntries
        case archiveSaveCopyAs
        case fileNewFolder
        case filePaste
        case combineVolumes
        case compareArchives
        case batchTestArchives
        case convertArchives
        case inspectRelease
        case compareSZSWithFolder
        case browseSZS
        case encryptGPG
        case createSignedManifest
        case fileBatchRename
        case duplicateFiles
        case splitFile
    }

    let id: ID
    let titleKey: String
    let systemImage: String
    let safety: AISuggestionSafety
    let isEnabled: Bool

    init(_ id: ID, titleKey: String, systemImage: String,
         safety: AISuggestionSafety = .safe, isEnabled: Bool = true) {
        self.id = id
        self.titleKey = titleKey
        self.systemImage = systemImage
        self.safety = safety
        self.isEnabled = isEnabled
    }

    var rankingCandidate: AIActionCandidate {
        AIActionCandidate(id: id.rawValue, safety: safety)
    }
}

nonisolated enum ContextualToolbarActionProvider {
    static func actions(for snapshot: ContextualToolbarSnapshot,
                        usage: [AIActionUsageSignal] = [],
                        limit: Int = 2) -> [ContextualToolbarAction] {
        let candidates = defaultActions(for: snapshot)
        guard !usage.isEmpty else { return Array(candidates.prefix(max(0, limit))) }

        let rankedCards = AINextActionRanker.rank(
            candidates: candidates.map(\.rankingCandidate),
            usage: usage,
            limit: limit)
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id.rawValue, $0) })
        return rankedCards.compactMap { candidatesByID[$0.actionID] }
    }

    static func defaultActions(for snapshot: ContextualToolbarSnapshot) -> [ContextualToolbarAction] {
        switch snapshot.mode {
        case .archive:
            return archiveActions(for: snapshot)
        case .folder, .tag:
            return folderActions(for: snapshot)
        case .aiWorkspace:
            return []
        }
    }

    private static func archiveActions(for snapshot: ContextualToolbarSnapshot) -> [ContextualToolbarAction] {
        if snapshot.selectedArchiveItemCount == 0 {
            return [
                .findDuplicates,
                snapshot.canEditArchiveComment ? .editComment : .securityReport
            ]
        }

        if snapshot.selectedArchiveItemCount >= 2 {
            return [
                .archiveBatchRename,
                snapshot.canDropIntoOpenArchive ? .deleteArchiveEntries : .findDuplicates
            ]
        }

        return [
            .saveCopyAs,
            snapshot.canDropIntoOpenArchive ? .deleteArchiveEntries : .findDuplicates
        ]
    }

    private static func folderActions(for snapshot: ContextualToolbarSnapshot) -> [ContextualToolbarAction] {
        let selection = snapshot.selectedFiles
        if selection.isEmpty {
            return snapshot.clipboardHasFiles ? [.newFolder, .paste] : [.newFolder]
        }

        if selection.contains(where: isSplitVolumeMember) {
            return [.combineVolumes, .compareArchives]
        }

        let selectedArchives = selection.filter { !$0.isDirectory && $0.isSupportedArchive }
        if selectedArchives.count >= 2 {
            return selectedArchives.count == 2
                ? [.batchTestArchives, .compareArchives]
                : [.batchTestArchives, .convertArchives]
        }

        if selectedArchives.count == 1, selection.count == 1 {
            return [.convertArchives, .inspectRelease]
        }

        if selection.count == 1, selection[0].pathExtension == SZSArchive.extensionName {
            return [.compareSZSWithFolder, .browseSZS]
        }

        if snapshot.gpgUIAvailable {
            return [.encryptGPG, .createSignedManifest]
        }

        if selection.count >= 2 {
            return [.fileBatchRename, .duplicateFiles]
        }

        return [.duplicateFiles, .splitFile(enabled: !selection[0].isDirectory)]
    }

    private static func isSplitVolumeMember(_ item: ContextualToolbarSnapshot.SelectedFile) -> Bool {
        let name = item.name.lowercased()
        return item.pathExtension == "001" || name.contains(".part")
    }
}

private extension ContextualToolbarAction {
    nonisolated static let findDuplicates = ContextualToolbarAction(
        .archiveFindDuplicates, titleKey: "duplicates.menu", systemImage: "doc.on.doc")
    nonisolated static let editComment = ContextualToolbarAction(
        .archiveEditComment, titleKey: "archive.comment.menu", systemImage: "text.bubble")
    nonisolated static let securityReport = ContextualToolbarAction(
        .archiveSecurityReport, titleKey: "security.banner.review", systemImage: "shield.lefthalf.filled")
    nonisolated static let archiveBatchRename = ContextualToolbarAction(
        .archiveBatchRename, titleKey: "archive.batchRename.menu", systemImage: "pencil.line")
    nonisolated static let deleteArchiveEntries = ContextualToolbarAction(
        .archiveDeleteEntries, titleKey: "archive.delete.menu", systemImage: "trash",
        safety: AISuggestionSafety(requiresConfirmation: true, reason: "existing-confirmation-flow"))
    nonisolated static let saveCopyAs = ContextualToolbarAction(
        .archiveSaveCopyAs, titleKey: "archive.saveCopyAs", systemImage: "square.and.arrow.down")
    nonisolated static let newFolder = ContextualToolbarAction(
        .fileNewFolder, titleKey: "file.newFolder", systemImage: "folder.badge.plus")
    nonisolated static let paste = ContextualToolbarAction(
        .filePaste, titleKey: "file.paste", systemImage: "doc.on.clipboard",
        safety: AISuggestionSafety(requiresConfirmation: true, reason: "writes-files"))
    nonisolated static let combineVolumes = ContextualToolbarAction(
        .combineVolumes, titleKey: "file.combine.menuItem", systemImage: "square.stack.3d.down.right",
        safety: AISuggestionSafety(requiresConfirmation: true, reason: "writes-archive-output"))
    nonisolated static let compareArchives = ContextualToolbarAction(
        .compareArchives, titleKey: "file.compareArchives", systemImage: "arrow.left.arrow.right.circle")
    nonisolated static let batchTestArchives = ContextualToolbarAction(
        .batchTestArchives, titleKey: "file.batchTest.button", systemImage: "checkmark.seal")
    nonisolated static let convertArchives = ContextualToolbarAction(
        .convertArchives, titleKey: "file.convert.menuItem", systemImage: "arrow.triangle.2.circlepath",
        safety: AISuggestionSafety(requiresConfirmation: true, reason: "writes-archive-output"))
    nonisolated static let inspectRelease = ContextualToolbarAction(
        .inspectRelease, titleKey: "inspect.menu", systemImage: "checklist")
    nonisolated static let compareSZSWithFolder = ContextualToolbarAction(
        .compareSZSWithFolder, titleKey: "szs.compareWithFolder.menuItem", systemImage: "arrow.left.arrow.right.circle")
    nonisolated static let browseSZS = ContextualToolbarAction(
        .browseSZS, titleKey: "szs.silentBrowse.menuItem", systemImage: "folder.badge.questionmark")
    nonisolated static let encryptGPG = ContextualToolbarAction(
        .encryptGPG, titleKey: "file.encrypt.gpg", systemImage: "lock.doc",
        safety: AISuggestionSafety(requiresConfirmation: true, reason: "writes-encrypted-output"))
    nonisolated static let createSignedManifest = ContextualToolbarAction(
        .createSignedManifest, titleKey: "szs.create.menuItem", systemImage: "signature",
        safety: AISuggestionSafety(requiresConfirmation: true, reason: "writes-signed-output"))
    nonisolated static let fileBatchRename = ContextualToolbarAction(
        .fileBatchRename, titleKey: "archive.batchRename.menu", systemImage: "pencil.line",
        safety: AISuggestionSafety(requiresConfirmation: true, reason: "renames-files"))
    nonisolated static let duplicateFiles = ContextualToolbarAction(
        .duplicateFiles, titleKey: "file.duplicate", systemImage: "plus.square.on.square",
        safety: AISuggestionSafety(requiresConfirmation: true, reason: "writes-files"))

    nonisolated static func splitFile(enabled: Bool) -> ContextualToolbarAction {
        ContextualToolbarAction(
            .splitFile, titleKey: "file.split.menuItem", systemImage: "scissors",
            safety: AISuggestionSafety(requiresConfirmation: true, reason: "writes-file-parts"),
            isEnabled: enabled)
    }
}

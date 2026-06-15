//
//  ContextualToolbarActionProviderTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80: main toolbar suggestion provider should preserve the old
//  ContextualToolbarButtons branch order while moving the logic into Core.
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ContextualToolbarActionProviderTests {
    private func file(_ name: String, isDirectory: Bool = false) -> ContextualToolbarSnapshot.SelectedFile {
        ContextualToolbarSnapshot.SelectedFile(
            name: name,
            pathExtension: URL(fileURLWithPath: name).pathExtension.lowercased(),
            isDirectory: isDirectory,
            isSupportedArchive: ArchiveService.isSupportedArchive(URL(fileURLWithPath: "/tmp/\(name)")))
    }

    @Test func archiveEmptySelectionShowsDuplicatesAndCommentWhenEditable() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .archive,
            selectedArchiveItemCount: 0,
            canEditArchiveComment: true,
            canDropIntoOpenArchive: false)

        let actions = ContextualToolbarActionProvider.actions(for: snapshot)

        #expect(actions.map(\.id) == [.archiveFindDuplicates, .archiveEditComment])
    }

    @Test func archiveSingleSelectionShowsSaveCopyThenDeleteWhenWritable() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .archive,
            selectedArchiveItemCount: 1,
            canEditArchiveComment: false,
            canDropIntoOpenArchive: true)

        let actions = ContextualToolbarActionProvider.actions(for: snapshot)

        #expect(actions.map(\.id) == [.archiveSaveCopyAs, .archiveDeleteEntries])
    }

    @Test func emptyFolderShowsPasteOnlyWhenClipboardHasFiles() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder,
            selectedFiles: [],
            clipboardHasFiles: true,
            gpgUIAvailable: false)

        let actions = ContextualToolbarActionProvider.actions(for: snapshot)

        #expect(actions.map(\.id) == [.fileNewFolder, .filePaste])
    }

    @Test func splitVolumeSelectionShowsCombineThenCompare() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder,
            selectedFiles: [file("sample.zip.001")],
            clipboardHasFiles: false,
            gpgUIAvailable: false)

        let actions = ContextualToolbarActionProvider.actions(for: snapshot)

        #expect(actions.map(\.id) == [.combineVolumes, .compareArchives])
    }

    @Test func twoArchivesShowBatchTestThenCompare() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder,
            selectedFiles: [file("a.zip"), file("b.7z")],
            clipboardHasFiles: false,
            gpgUIAvailable: false)

        let actions = ContextualToolbarActionProvider.actions(for: snapshot)

        #expect(actions.map(\.id) == [.batchTestArchives, .compareArchives])
    }

    @Test func manyArchivesShowBatchTestThenConvert() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder,
            selectedFiles: [file("a.zip"), file("b.7z"), file("c.tar")],
            clipboardHasFiles: false,
            gpgUIAvailable: false)

        let actions = ContextualToolbarActionProvider.actions(for: snapshot)

        #expect(actions.map(\.id) == [.batchTestArchives, .convertArchives])
    }

    @Test func singleArchiveShowsConvertThenReleaseInspection() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder,
            selectedFiles: [file("release.zip")],
            clipboardHasFiles: false,
            gpgUIAvailable: false)

        let actions = ContextualToolbarActionProvider.actions(for: snapshot)

        #expect(actions.map(\.id) == [.convertArchives, .inspectRelease])
    }

    @Test func szsSelectionShowsCompareThenVirtualBrowse() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder,
            selectedFiles: [file("snapshot.szs")],
            clipboardHasFiles: false,
            gpgUIAvailable: false)

        let actions = ContextualToolbarActionProvider.actions(for: snapshot)

        #expect(actions.map(\.id) == [.compareSZSWithFolder, .browseSZS])
    }

    @Test func gpgAvailableForPlainFilesShowsEncryptThenSignedManifest() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder,
            selectedFiles: [file("notes.txt")],
            clipboardHasFiles: false,
            gpgUIAvailable: true)

        let actions = ContextualToolbarActionProvider.actions(for: snapshot)

        #expect(actions.map(\.id) == [.encryptGPG, .createSignedManifest])
    }

    @Test func singleFolderShowsDuplicateAndDisabledSplit() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder,
            selectedFiles: [file("Source", isDirectory: true)],
            clipboardHasFiles: false,
            gpgUIAvailable: false)

        let actions = ContextualToolbarActionProvider.actions(for: snapshot)

        #expect(actions.map(\.id) == [.duplicateFiles, .splitFile])
        #expect(actions.last?.isEnabled == false)
    }

    @Test func aiWorkspaceShowsNoFileActions() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .aiWorkspace,
            selectedFiles: [file("release.zip")],
            clipboardHasFiles: true,
            gpgUIAvailable: true)

        #expect(ContextualToolbarActionProvider.actions(for: snapshot).isEmpty)
    }
}

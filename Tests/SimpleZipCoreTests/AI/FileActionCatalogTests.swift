//
//  FileActionCatalogTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80 建议七:共享动作目录。① 空 usage 时每分支前两项 = 原策划对(行为不变);
//  ② 候选池已扩成右键菜单白名单(每分支不止两项);③ 习惯信号能把常用动作排进前两个。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct FileActionCatalogTests {
    private func file(_ name: String, isDirectory: Bool = false,
                      isFirstVolume: Bool = false, isChecksumFile: Bool = false,
                      isPackage: Bool = false) -> ContextualToolbarSnapshot.SelectedFile {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return ContextualToolbarSnapshot.SelectedFile(
            name: name,
            pathExtension: url.pathExtension.lowercased(),
            isDirectory: isDirectory,
            isSupportedArchive: ArchiveService.isSupportedArchive(url),
            isToolableArchive: ArchiveService.isSupportedArchive(url),
            isPackage: isPackage,
            isFirstVolume: isFirstVolume,
            isChecksumFile: isChecksumFile)
    }

    // MARK: - 原策划对保持不变(空 usage 取前两个)

    @Test func archiveEmptySelectionShowsDuplicatesAndCommentWhenEditable() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .archive, selectedArchiveItemCount: 0,
            canEditArchiveComment: true, canDropIntoOpenArchive: false)
        #expect(FileActionCatalog.actions(for: snapshot).map(\.id) == [.archiveFindDuplicates, .archiveEditComment])
    }

    @Test func archiveSingleSelectionShowsSaveCopyThenDeleteWhenWritable() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .archive, selectedArchiveItemCount: 1,
            canEditArchiveComment: false, canDropIntoOpenArchive: true)
        #expect(FileActionCatalog.actions(for: snapshot).map(\.id) == [.archiveSaveCopyAs, .archiveDeleteEntries])
    }

    @Test func emptyFolderShowsPasteOnlyWhenClipboardHasFiles() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder, selectedFiles: [], clipboardHasFiles: true, gpgUIAvailable: false)
        #expect(FileActionCatalog.actions(for: snapshot).map(\.id) == [.fileNewFolder, .filePaste])
    }

    @Test func splitVolumeSelectionShowsCombineThenCompare() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder, selectedFiles: [file("sample.zip.001", isFirstVolume: true)],
            clipboardHasFiles: false, gpgUIAvailable: false)
        #expect(FileActionCatalog.actions(for: snapshot).map(\.id) == [.combineVolumes, .compareArchives])
    }

    @Test func twoArchivesShowBatchTestThenCompare() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder, selectedFiles: [file("a.zip"), file("b.7z")],
            clipboardHasFiles: false, gpgUIAvailable: false)
        #expect(FileActionCatalog.actions(for: snapshot).map(\.id) == [.batchTestArchives, .compareArchives])
    }

    @Test func manyArchivesShowBatchTestThenConvert() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder, selectedFiles: [file("a.zip"), file("b.7z"), file("c.tar")],
            clipboardHasFiles: false, gpgUIAvailable: false)
        #expect(FileActionCatalog.actions(for: snapshot).map(\.id) == [.batchTestArchives, .convertArchives])
    }

    @Test func singleArchiveShowsConvertThenReleaseInspection() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder, selectedFiles: [file("release.zip")],
            clipboardHasFiles: false, gpgUIAvailable: false)
        #expect(FileActionCatalog.actions(for: snapshot).map(\.id) == [.convertArchives, .inspectRelease])
    }

    @Test func szsSelectionShowsCompareThenVirtualBrowse() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder, selectedFiles: [file("snapshot.szs")],
            clipboardHasFiles: false, gpgUIAvailable: false)
        #expect(FileActionCatalog.actions(for: snapshot).map(\.id) == [.compareSZSWithFolder, .browseSZS])
    }

    @Test func gpgAvailableForPlainFilesShowsEncryptThenSignedManifest() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder, selectedFiles: [file("notes.txt")],
            clipboardHasFiles: false, gpgUIAvailable: true)
        #expect(FileActionCatalog.actions(for: snapshot).map(\.id) == [.encryptGPG, .createSignedManifest])
    }

    @Test func singleFolderShowsDuplicateAndDisabledSplit() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder, selectedFiles: [file("Source", isDirectory: true)],
            clipboardHasFiles: false, gpgUIAvailable: false)
        let actions = FileActionCatalog.actions(for: snapshot)
        #expect(actions.map(\.id) == [.duplicateFiles, .splitFile])
        #expect(actions.last?.isEnabled == false)
    }

    @Test func aiWorkspaceShowsNoFileActions() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .aiWorkspace, selectedFiles: [file("release.zip")],
            clipboardHasFiles: true, gpgUIAvailable: true)
        #expect(FileActionCatalog.actions(for: snapshot).isEmpty)
    }

    // MARK: - 候选池扩成右键菜单白名单(每分支不止两项)

    @Test func singleArchivePoolIncludesMenuTools() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder, selectedFiles: [file("release.zip")], gpgUIAvailable: false)
        let pool = FileActionCatalog.defaultActions(for: snapshot).map(\.id)
        #expect(pool.count > 2)
        #expect(pool.contains(.analyzeSpace))
        #expect(pool.contains(.checkupArchives))
        #expect(pool.contains(.salvageArchive))
    }

    @Test func plainFolderPoolIncludesReleaseChecks() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder, selectedFiles: [file("Release", isDirectory: true)], gpgUIAvailable: false)
        let pool = FileActionCatalog.defaultActions(for: snapshot).map(\.id)
        #expect(pool.contains(.quickVerifyReleaseGroup))
        #expect(pool.contains(.auditReleaseDirectory))
        #expect(pool.contains(.checkReproducibility))
    }

    // MARK: - 习惯信号把常用动作排进前两个

    @Test func usageSignalPromotesFrequentlyUsedAction() {
        let snapshot = ContextualToolbarSnapshot(
            mode: .folder, selectedFiles: [file("release.zip")], gpgUIAvailable: false)
        // 默认前两个是 convert / inspect;analyzeSpace 在池里更靠后。重度使用后应被排进前两个。
        let usage = [AIActionUsageSignal(actionID: ContextualToolbarAction.ID.analyzeSpace.rawValue, clicked: 12)]
        let ranked = FileActionCatalog.actions(for: snapshot, usage: usage, limit: 2).map(\.id)
        #expect(ranked.contains(.analyzeSpace))
    }
}

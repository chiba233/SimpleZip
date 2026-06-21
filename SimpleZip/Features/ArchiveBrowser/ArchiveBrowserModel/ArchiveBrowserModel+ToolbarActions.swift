//
//  ArchiveBrowserModel+ToolbarActions.swift
//  SimpleZip
//
//  0.4.5 #80 建议七:工具栏动态推荐的选择上下文 + 习惯记录。
//
//  `contextualToolbarSnapshot()` 把当前选择翻成 `FileActionCatalog` 用的纯值快照(工具栏渲染 + 习惯记录共用一份)。
//  `recordToolbarActionHabit(_:)` 把一次 catalog 动作的使用记进共享统计 —— **工具栏按钮点击**和**右键菜单里的
//  同一动作点击**都调它(用户拍板:不学右键就没法推荐,所以右键菜单的 catalog 动作选择是主要习惯信号)。
//

import Foundation

extension ArchiveBrowserModel {
    /// 当前选择的工具栏动作上下文快照(纯值;cheap,只读 in-memory 选择状态,无文件系统扫描)。
    func contextualToolbarSnapshot() -> ContextualToolbarSnapshot {
        ContextualToolbarSnapshot(
            mode: toolbarSnapshotMode,
            selectedArchiveItemCount: selectedArchiveItems.count,
            selectedArchiveNonDirectoryCount: selectedArchiveItems.filter { !$0.isDirectory }.count,
            canEditArchiveComment: canEditArchiveComment,
            canDropIntoOpenArchive: canDropIntoOpenArchive,
            selectedFiles: selectedFileItems.map { item in
                ContextualToolbarSnapshot.SelectedFile(
                    name: item.url.lastPathComponent,
                    pathExtension: item.url.pathExtension.lowercased(),
                    isDirectory: item.isDirectory,
                    isSupportedArchive: !item.isDirectory && ArchiveService.isSupportedArchive(item.url),
                    isToolableArchive: !item.isDirectory && SignedContainerService.isToolableArchive(item.url),
                    isPackage: item.isPackage,
                    isFirstVolume: !item.isDirectory && FileSplitCombine.isFirstVolume(item.url),
                    isChecksumFile: !item.isDirectory && ChecksumFile.isChecksumFileName(item.url.lastPathComponent))
            },
            clipboardHasFiles: fileClipboard?.urls.isEmpty == false,
            gpgUIAvailable: AppPreferences.gpgEnabled && GPGBackend.isAvailable(),
            canConvertSelectedArchives: canConvertSelectedArchives)
    }

    /// 记一次 catalog 动作的使用(工具栏点击 / 右键菜单点击都调)。AI 关 → 习惯排序直接用;AI 开 → 习惯权重。
    func recordToolbarActionHabit(_ id: ContextualToolbarAction.ID) {
        ToolbarActionUsageStore.shared.record(actionID: id.rawValue, in: contextualToolbarSnapshot())
    }

    private var toolbarSnapshotMode: ContextualToolbarSnapshot.Mode {
        switch mode {
        case .archive: return .archive
        case .folder: return .folder
        case .tag: return .tag
        case .aiWorkspace: return .aiWorkspace
        }
    }
}

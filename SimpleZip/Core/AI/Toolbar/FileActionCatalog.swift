//
//  FileActionCatalog.swift
//  SimpleZip
//
//  0.4.5 #80 建议七:工具栏动态推荐的**共享动作目录**。
//
//  设计(复用右键菜单白名单,别自己维护):工具栏的上下文候选动作不再自维护一份会和右键菜单
//  漂移的小白名单,而是从**右键菜单的同一批上下文动作**取候选池(条件 / 标题 key / 图标 / 调用全部对齐
//  FileTable / ArchiveTable 的 `menuNeedsUpdate`)。本类型是这份目录的纯数据底座(Core 可测):
//
//    - `defaultActions(for:)` 按当前选择给出**有序候选池**:每个分支前两项保持原「策划对」(行为不变,
//      空 usage 时 `actions(for:)` 仍只取前两个),其后追加该上下文下右键菜单里更多的上下文强动作,
//      让习惯排序 / AI 预烘焙有更大的重排空间。
//    - `actions(for:usage:limit:)` 在候选池上叠加确定性习惯排序(`AINextActionRanker`,见 AINextActionCard)。
//
//  常驻工具栏已有的按钮(添加 / 解压 / 测试 / 哈希 / 显示 / 活动中心)和纯通用项(打开 / 复制 / 重命名 /
//  删除 / 简介 / Reveal)**不进**候选池 —— 工具栏只推上下文强动作。两个右键菜单后续会逐步迁来吃这一份。
//
//  纯值 + 确定性,SwiftPM 可断言。
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
        /// 工具可作用的归档(含 .siz 内层,`SignedContainerService.isToolableArchive`);测试 / 比较 / 体检等据此。
        let isToolableArchive: Bool
        /// 系统包(.app / .bundle 等)。普通文件夹 = 目录且非包。
        let isPackage: Bool
        /// 分卷集首卷(`.001` / `.part1` 等),`FileSplitCombine.isFirstVolume`。
        let isFirstVolume: Bool
        /// 校验清单文件(SHA256SUMS 等),`ChecksumFile.isChecksumFileName`。
        let isChecksumFile: Bool

        init(name: String, pathExtension: String, isDirectory: Bool, isSupportedArchive: Bool,
             isToolableArchive: Bool = false, isPackage: Bool = false,
             isFirstVolume: Bool = false, isChecksumFile: Bool = false) {
            self.name = name
            self.pathExtension = pathExtension.lowercased()
            self.isDirectory = isDirectory
            self.isSupportedArchive = isSupportedArchive
            self.isToolableArchive = isToolableArchive
            self.isPackage = isPackage
            self.isFirstVolume = isFirstVolume
            self.isChecksumFile = isChecksumFile
        }

        var isSZS: Bool { pathExtension == SZSArchive.extensionName }
        var isAppBundle: Bool { isDirectory && pathExtension == "app" }
        var isComparable: Bool { isDirectory || isToolableArchive }
        /// 普通文件夹(目录且非系统包),发布组核对 / 可复现等只对它有意义。
        var isPlainFolder: Bool { isDirectory && !isPackage }
        var isSplitVolumeMember: Bool { pathExtension == "001" || name.lowercased().contains(".part") }
    }

    let mode: Mode
    let selectedArchiveItemCount: Int
    /// 选中的归档内非目录条目数(批量重命名需要 ≥2)。
    let selectedArchiveNonDirectoryCount: Int
    let canEditArchiveComment: Bool
    let canDropIntoOpenArchive: Bool
    let selectedFiles: [SelectedFile]
    let clipboardHasFiles: Bool
    let gpgUIAvailable: Bool
    /// 选中项整体可批量转换格式(`model.canConvertSelectedArchives`)。
    let canConvertSelectedArchives: Bool

    init(mode: Mode,
         selectedArchiveItemCount: Int = 0,
         selectedArchiveNonDirectoryCount: Int = 0,
         canEditArchiveComment: Bool = false,
         canDropIntoOpenArchive: Bool = false,
         selectedFiles: [SelectedFile] = [],
         clipboardHasFiles: Bool = false,
         gpgUIAvailable: Bool = false,
         canConvertSelectedArchives: Bool = false) {
        self.mode = mode
        self.selectedArchiveItemCount = selectedArchiveItemCount
        self.selectedArchiveNonDirectoryCount = selectedArchiveNonDirectoryCount
        self.canEditArchiveComment = canEditArchiveComment
        self.canDropIntoOpenArchive = canDropIntoOpenArchive
        self.selectedFiles = selectedFiles
        self.clipboardHasFiles = clipboardHasFiles
        self.gpgUIAvailable = gpgUIAvailable
        self.canConvertSelectedArchives = canConvertSelectedArchives
    }
}

nonisolated struct ContextualToolbarAction: Identifiable, Codable, Equatable, Sendable {
    nonisolated enum ID: String, Codable, Equatable, CaseIterable, Sendable {
        // 归档内(打开归档)
        case archiveFindDuplicates
        case archiveEditComment
        case archiveSecurityReport
        case archiveContentSearch
        case archiveMetadataReport
        case archiveBatchRename
        case archiveDeleteEntries
        case archiveSaveCopyAs
        // 文件夹 / 标签
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
        case openAsArchive
        case findDuplicateArchivesInFolder
        case checkupArchives
        case salvageArchive
        case analyzeSpace
        case quickVerifyReleaseGroup
        case auditReleaseDirectory
        case checkReproducibility
        case generateChecksumFile
        case verifyChecksumFile
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

/// 工具栏动态推荐的共享动作目录。`defaultActions` 给候选池,`actions(for:usage:)` 叠加确定性习惯排序。
nonisolated enum FileActionCatalog {
    /// `bakedOrder`(建议七 Phase2):AI 开时后台烘焙的「对该文件/类型最有用的工具栏动作」有序 id,叠进 ranker 当强权重;
    /// AI 关 / 无烘焙 → 空 → 退回纯习惯排序。空 usage + 空 bakedOrder → 直接取策划前两项(行为不变)。
    static func actions(for snapshot: ContextualToolbarSnapshot,
                        usage: [AIActionUsageSignal] = [],
                        bakedOrder: [String] = [],
                        limit: Int = 2) -> [ContextualToolbarAction] {
        let candidates = defaultActions(for: snapshot)
        guard !usage.isEmpty || !bakedOrder.isEmpty else { return Array(candidates.prefix(max(0, limit))) }

        let rankedCards = AINextActionRanker.rank(
            candidates: candidates.map(\.rankingCandidate),
            usage: usage,
            bakedOrder: bakedOrder,
            limit: limit)
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id.rawValue, $0) })
        return rankedCards.compactMap { candidatesByID[$0.actionID] }
    }

    /// 当前选择下的有序候选池:每分支前两项 = 原策划对(行为不变),其后追加该上下文右键菜单里的更多上下文强动作。
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

    // MARK: - 归档内

    private static func archiveActions(for snapshot: ContextualToolbarSnapshot) -> [ContextualToolbarAction] {
        var out: [ContextualToolbarAction]
        if snapshot.selectedArchiveItemCount == 0 {
            out = [.findDuplicates, snapshot.canEditArchiveComment ? .editComment : .securityReport]
        } else if snapshot.selectedArchiveItemCount >= 2 {
            out = [.archiveBatchRename, snapshot.canDropIntoOpenArchive ? .deleteArchiveEntries : .findDuplicates]
        } else {
            out = [.saveCopyAs, snapshot.canDropIntoOpenArchive ? .deleteArchiveEntries : .findDuplicates]
        }
        // 追加:归档级只读分析(任何格式可用)+ 可写包的删改项。
        appendUnique(&out, [.findDuplicates, .contentSearch, .securityReport, .metadataReport])
        if snapshot.canEditArchiveComment { appendUnique(&out, [.editComment]) }
        if snapshot.canDropIntoOpenArchive, snapshot.selectedArchiveNonDirectoryCount >= 2 {
            appendUnique(&out, [.archiveBatchRename])
        }
        return out
    }

    // MARK: - 文件夹 / 标签

    private static func folderActions(for snapshot: ContextualToolbarSnapshot) -> [ContextualToolbarAction] {
        let selection = snapshot.selectedFiles
        if selection.isEmpty {
            return snapshot.clipboardHasFiles ? [.newFolder, .paste] : [.newFolder]
        }

        if selection.contains(where: { $0.isSplitVolumeMember }) {
            return [.combineVolumes, .compareArchives]
        }

        let selectedArchives = selection.filter { !$0.isDirectory && $0.isSupportedArchive }
        if selectedArchives.count >= 2 {
            var out: [ContextualToolbarAction] = selectedArchives.count == 2
                ? [.batchTestArchives, .compareArchives]
                : [.batchTestArchives, .convertArchives]
            appendUnique(&out, [.convertArchives, .findDuplicateArchivesInFolder, .checkupArchives])
            return out
        }

        if selectedArchives.count == 1, selection.count == 1 {
            var out: [ContextualToolbarAction] = [.convertArchives, .inspectRelease]
            appendUnique(&out, [.analyzeSpace, .checkupArchives, .salvageArchive, .generateChecksumFile])
            if snapshot.gpgUIAvailable { appendUnique(&out, [.encryptGPG, .createSignedManifest]) }
            return out
        }

        if selection.count == 1, selection[0].isSZS {
            var out: [ContextualToolbarAction] = [.compareSZSWithFolder, .browseSZS]
            appendUnique(&out, [.generateChecksumFile])
            if snapshot.gpgUIAvailable { appendUnique(&out, [.encryptGPG, .createSignedManifest]) }
            return out
        }

        // 普通文件 / 文件夹选择。GPG 可用时签名加密置顶(与原策划一致),但候选池仍带上文件管理强动作。
        var out: [ContextualToolbarAction] = []
        if snapshot.gpgUIAvailable {
            out = [.encryptGPG, .createSignedManifest]
        } else if selection.count >= 2 {
            out = [.fileBatchRename, .duplicateFiles]
        } else {
            out = [.duplicateFiles, .splitFile(enabled: !selection[0].isDirectory)]
        }
        appendUnique(&out, plainSelectionExtras(for: snapshot, selection: selection))
        return out
    }

    /// 普通文件 / 文件夹选择下,右键菜单里的更多上下文强动作(去重后追加进候选池)。
    private static func plainSelectionExtras(for snapshot: ContextualToolbarSnapshot,
                                             selection: [ContextualToolbarSnapshot.SelectedFile]) -> [ContextualToolbarAction] {
        var extras: [ContextualToolbarAction] = []
        if selection.count >= 2 {
            extras += [.fileBatchRename, .duplicateFiles, .generateChecksumFile]
        }
        if selection.count == 1 {
            let only = selection[0]
            extras.append(.duplicateFiles)
            if !only.isDirectory {
                extras.append(.splitFile(enabled: true))
                if only.isFirstVolume { extras.append(.combineVolumes) }
                if !only.isSupportedArchive { extras.append(.openAsArchive) }
                extras.append(.generateChecksumFile)
                if only.isChecksumFile { extras.append(.verifyChecksumFile) }
            }
            if only.isAppBundle { extras.append(.inspectRelease) }
            if only.isPlainFolder {
                extras += [.quickVerifyReleaseGroup, .auditReleaseDirectory, .checkReproducibility, .checkupArchives]
            }
        }
        if snapshot.canConvertSelectedArchives { extras.append(.convertArchives) }
        return extras
    }

    /// 追加候选(去重,保序);保留首次出现位置,前面的策划对不被打乱。
    private static func appendUnique(_ out: inout [ContextualToolbarAction], _ extras: [ContextualToolbarAction]) {
        for action in extras where !out.contains(where: { $0.id == action.id }) {
            out.append(action)
        }
    }
}

private extension ContextualToolbarAction {
    nonisolated static let findDuplicates = ContextualToolbarAction(
        .archiveFindDuplicates, titleKey: "duplicates.menu", systemImage: "doc.on.doc")
    nonisolated static let editComment = ContextualToolbarAction(
        .archiveEditComment, titleKey: "archive.comment.menu", systemImage: "text.bubble")
    nonisolated static let securityReport = ContextualToolbarAction(
        .archiveSecurityReport, titleKey: "security.banner.review", systemImage: "shield.lefthalf.filled")
    nonisolated static let contentSearch = ContextualToolbarAction(
        .archiveContentSearch, titleKey: "contentSearch.menu", systemImage: "text.magnifyingglass")
    nonisolated static let metadataReport = ContextualToolbarAction(
        .archiveMetadataReport, titleKey: "metadata.menu", systemImage: "info.square")
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
    nonisolated static let openAsArchive = ContextualToolbarAction(
        .openAsArchive, titleKey: "file.openAsArchive", systemImage: "doc.zipper")
    nonisolated static let findDuplicateArchivesInFolder = ContextualToolbarAction(
        .findDuplicateArchivesInFolder, titleKey: "dupArchives.menu", systemImage: "doc.on.doc")
    nonisolated static let checkupArchives = ContextualToolbarAction(
        .checkupArchives, titleKey: "checkup.menu", systemImage: "stethoscope")
    nonisolated static let salvageArchive = ContextualToolbarAction(
        .salvageArchive, titleKey: "salvage.menu", systemImage: "bandage",
        safety: AISuggestionSafety(requiresConfirmation: true, reason: "writes-extracted-output"))
    nonisolated static let analyzeSpace = ContextualToolbarAction(
        .analyzeSpace, titleKey: "space.menu", systemImage: "chart.pie")
    nonisolated static let quickVerifyReleaseGroup = ContextualToolbarAction(
        .quickVerifyReleaseGroup, titleKey: "quickVerify.menu", systemImage: "checklist")
    nonisolated static let auditReleaseDirectory = ContextualToolbarAction(
        .auditReleaseDirectory, titleKey: "dirAudit.menu", systemImage: "folder.badge.questionmark")
    nonisolated static let checkReproducibility = ContextualToolbarAction(
        .checkReproducibility, titleKey: "repro.menu", systemImage: "arrow.triangle.2.circlepath")
    nonisolated static let generateChecksumFile = ContextualToolbarAction(
        .generateChecksumFile, titleKey: "checksum.generate.menu", systemImage: "number.square.fill",
        safety: AISuggestionSafety(requiresConfirmation: true, reason: "writes-checksum-file"))
    nonisolated static let verifyChecksumFile = ContextualToolbarAction(
        .verifyChecksumFile, titleKey: "checksum.verify.menu", systemImage: "checkmark.seal")

    nonisolated static func splitFile(enabled: Bool) -> ContextualToolbarAction {
        ContextualToolbarAction(
            .splitFile, titleKey: "file.split.menuItem", systemImage: "scissors",
            safety: AISuggestionSafety(requiresConfirmation: true, reason: "writes-file-parts"),
            isEnabled: enabled)
    }
}

//
//  ArchiveBrowserModel+Undo.swift
//  SimpleZip
//
//  本地文件操作的撤销 / 重做（⌘Z / ⇧⌘Z）。
//
//  设计：forward 操作（移动 / 粘贴复制 / 创建副本 / 重命名 / 删除）成功后，调用下面的
//  register* 注册一个逆操作到 `fileUndoManager`。逆操作执行时又会注册它自己的逆操作 ——
//  这正是 UndoManager 的标准玩法，undo 的「再次注册」自动成为 redo。
//
//  两类原语：
//  - 移动型（移动 / 重命名 / 删除-恢复）：A→B 的逆就是 B→A，统一走 `performUndoableMoves`。
//    删除当成 (原位 ⟷ 废纸篓 URL) 的移动：撤销 = 从废纸篓移回，重做 = 移回废纸篓那个路径。
//  - 复制型（粘贴复制 / 创建副本）：撤销 = 把复制出来的产物移到废纸篓（可恢复、非破坏），
//    重做 = 重新从源复制。
//
//  保守安全（仓库铁律「绝不静默覆盖用户数据」）：每一步都要求「源存在且未被外部改动、目标空闲」，
//  否则跳过该步并提示，绝不覆盖 / 移走外部期间新建或改动的同名文件。

import AppKit
import Foundation

extension ArchiveBrowserModel {
    // MARK: - 注册（forward 操作成功后调用）

    /// 移动 / 重命名：forward 已把每个 from 移到了 to。撤销 = 反向移动。
    func registerMoveUndo(_ forwardPairs: [(from: URL, to: URL)], actionName: String) {
        let steps = forwardPairs.compactMap { pair -> UndoMoveStep? in
            guard pair.from != pair.to, let snapshot = UndoFileSnapshot(url: pair.to, fileManager: fileManager) else { return nil }
            return UndoMoveStep(from: pair.to, to: pair.from, sourceSnapshot: snapshot)
        }
        guard !steps.isEmpty else { return }
        fileUndoManager.setActionName(actionName)
        fileUndoManager.registerUndo(withTarget: self) { model in
            model.performUndoableMoves(steps, actionName: actionName)
        }
        refreshUndoActionNames()
    }

    /// 粘贴复制 / 创建副本：forward 已把每个 source 复制到 dest。撤销 = 删掉 dest（移到废纸篓）。
    func registerCopyUndo(_ forwardPairs: [(source: URL, dest: URL)], actionName: String) {
        let steps = forwardPairs.compactMap { pair -> UndoCopyStep? in
            guard let sourceSnapshot = UndoFileSnapshot(url: pair.source, fileManager: fileManager),
                  let destSnapshot = UndoFileSnapshot(url: pair.dest, fileManager: fileManager) else { return nil }
            return UndoCopyStep(source: pair.source, dest: pair.dest, sourceSnapshot: sourceSnapshot, destSnapshot: destSnapshot)
        }
        guard !steps.isEmpty else { return }
        fileUndoManager.setActionName(actionName)
        fileUndoManager.registerUndo(withTarget: self) { model in
            model.performUndoableRemoveCopies(steps, actionName: actionName)
        }
        refreshUndoActionNames()
    }

    /// 新建文件 / 文件夹：forward 已创建 dest。撤销 = 把 dest 移到废纸篓；重做 = 从废纸篓移回原位。
    func registerCreateUndo(_ createdURLs: [URL], actionName: String) {
        let steps = createdURLs.compactMap { url -> UndoCreateStep? in
            guard let snapshot = UndoFileSnapshot(url: url, fileManager: fileManager) else { return nil }
            return UndoCreateStep(url: url, snapshot: snapshot)
        }
        guard !steps.isEmpty else { return }
        fileUndoManager.setActionName(actionName)
        fileUndoManager.registerUndo(withTarget: self) { model in
            model.performUndoableRemoveCreatedItems(steps, actionName: actionName)
        }
        refreshUndoActionNames()
    }

    /// 删除：forward 已把每个 original 移到了废纸篓的 trashURL。当成移动处理 —— 撤销 = trashURL → original。
    func registerTrashUndo(_ forwardPairs: [(original: URL, trashURL: URL)], actionName: String) {
        registerMoveUndo(forwardPairs.map { (from: $0.original, to: $0.trashURL) }, actionName: actionName)
    }

    /// Task 7 整理建议的「建文件夹」段撤销 —— 和移动撤销组成**一个撤销组**(组合撤销「撤销这条 AI 建议」)。撤销整条
    /// 整理时,同组的移动撤销(LIFO 先跑)把成员移回原位、这里再把**空了**的文件夹收掉。**不用 `registerCreateUndo` 的
    /// 创建时快照**(整理把文件移进又移出、mtime 变了,快照守卫会误判「目标被占」→ 跳过 → 文件夹删不掉,正是用户报的
    /// bug);改成「只删空文件夹」既安全(里头还有别的就不删)又能在多段撤销里正确收尾。撤销 / 重做逐步写
    /// `undoRedoTransferLog` → 落活动中心(整条整理的撤销显示成一张卡:移回 N 项 + 删空文件夹)。
    func registerOrganizeFolderUndo(_ folder: URL, actionName: String) {
        fileUndoManager.setActionName(actionName)
        fileUndoManager.registerUndo(withTarget: self) { model in
            model.performUndoableRemoveOrganizeFolder(folder, actionName: actionName)
        }
        refreshUndoActionNames()
    }

    /// 权限 / 属主：forward 已把每个 url 改成新值。撤销 = 恢复 `steps` 里记录的**旧** mode / owner。
    /// `mode` / `owner` 为 nil 表示该维度没改、撤销时也不动它。仅非递归操作注册（递归一整棵树的旧权限无法可靠快照）。
    func registerPermissionsUndo(_ steps: [UndoPermissionsStep], actionName: String) {
        let valid = steps.filter { $0.mode != nil || ($0.owner?.isEmpty == false) }
        guard !valid.isEmpty else { return }
        fileUndoManager.setActionName(actionName)
        fileUndoManager.registerUndo(withTarget: self) { model in
            model.performUndoablePermissions(valid, actionName: actionName)
        }
        refreshUndoActionNames()
    }

    /// 恢复 `steps` 的 mode / owner，并把**当前**值（撤销前的状态）注册成下一步重做。
    /// chown 维度恢复仍需系统授权（会再弹一次密码框）—— 跟 forward 一致，可接受。
    private func performUndoablePermissions(_ steps: [UndoPermissionsStep], actionName: String) {
        // 先抓「现在的值」给重做用（必须在 apply 之前抓）。
        let redoSteps = steps.map { step in
            UndoPermissionsStep(
                url: step.url,
                mode: step.mode != nil ? FilePermissionService.currentMode(of: step.url) : nil,
                owner: (step.owner?.isEmpty == false) ? FilePermissionService.currentOwner(of: step.url) : nil
            )
        }
        // 详情同步记（异步 apply 之前）—— recordUndoRedoHistory 在 undo() 返回后立刻收割,等不到 Task。
        for step in steps {
            appendUndoRedoLog(.changed, at: step.url, detail: abbreviatedPath(step.url))
        }
        Task { @MainActor [weak self] in
            for step in steps {
                _ = try? await Task.detached(priority: .userInitiated) {
                    try FilePermissionService.apply(mode: step.mode, owner: step.owner, to: [step.url], recursive: false)
                }.value
            }
            self?.reload()
        }
        fileUndoManager.setActionName(actionName)
        fileUndoManager.registerUndo(withTarget: self) { model in
            model.performUndoablePermissions(redoSteps, actionName: actionName)
        }
        refreshUndoActionNames()
    }

    // MARK: - 原语

    /// 把每个 from 移到 to（保守：源在且没变、目标空才动），然后注册反向移动作为下一步撤销 / 重做。
    private func performUndoableMoves(_ steps: [UndoMoveStep], actionName: String) {
        var done: [UndoMoveStep] = []
        var skipped = 0
        for step in steps {
            guard step.sourceSnapshot.matches(url: step.from, fileManager: fileManager) else { skipped += 1; continue }
            guard !fileManager.fileExists(atPath: step.to.path) else { skipped += 1; continue }
            do {
                try fileManager.createDirectory(at: step.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: step.from, to: step.to)
                appendUndoRedoLog(.changed, at: step.to, detail: "\(abbreviatedPath(step.from)) → \(abbreviatedPath(step.to))")
                if let snapshot = UndoFileSnapshot(url: step.to, fileManager: fileManager) {
                    done.append(UndoMoveStep(from: step.to, to: step.from, sourceSnapshot: snapshot))
                }
            } catch {
                skipped += 1
            }
        }
        reportUndoSkips(skipped)
        guard !done.isEmpty else { return }
        fileUndoManager.setActionName(actionName)
        fileUndoManager.registerUndo(withTarget: self) { model in
            model.performUndoableMoves(done, actionName: actionName)
        }
        refreshUndoActionNames()
    }

    /// 重做一次复制（撤销「删除复制产物」的逆）：把 source 重新复制到 dest。
    private func performUndoableCopy(_ steps: [UndoCopyStep], actionName: String) {
        var done: [UndoCopyStep] = []
        var skipped = 0
        for step in steps {
            guard step.sourceSnapshot.matches(url: step.source, fileManager: fileManager) else { skipped += 1; continue }
            guard !fileManager.fileExists(atPath: step.dest.path) else { skipped += 1; continue }
            do {
                try fileManager.copyItem(at: step.source, to: step.dest)
                appendUndoRedoLog(.added, at: step.dest, detail: "\(abbreviatedPath(step.source)) → \(abbreviatedPath(step.dest))")
                if let destSnapshot = UndoFileSnapshot(url: step.dest, fileManager: fileManager) {
                    done.append(UndoCopyStep(
                        source: step.source,
                        dest: step.dest,
                        sourceSnapshot: step.sourceSnapshot,
                        destSnapshot: destSnapshot
                    ))
                }
            } catch {
                skipped += 1
            }
        }
        reportUndoSkips(skipped)
        guard !done.isEmpty else { return }
        fileUndoManager.setActionName(actionName)
        fileUndoManager.registerUndo(withTarget: self) { model in
            model.performUndoableRemoveCopies(done, actionName: actionName)
        }
        refreshUndoActionNames()
    }

    /// 撤销一次复制：把复制产物 dest 移到废纸篓（可恢复、非破坏），然后注册「重新复制」作为重做。
    private func performUndoableRemoveCopies(_ steps: [UndoCopyStep], actionName: String) {
        var done: [UndoCopyStep] = []
        var skipped = 0
        for step in steps {
            guard step.destSnapshot.matches(url: step.dest, fileManager: fileManager) else { skipped += 1; continue }
            do {
                var trashURL: NSURL?
                try fileManager.trashItem(at: step.dest, resultingItemURL: &trashURL)
                appendUndoRedoLog(.deleted, at: step.dest, detail: abbreviatedPath(step.dest))
                done.append(step)
            } catch {
                skipped += 1
            }
        }
        reportUndoSkips(skipped)
        guard !done.isEmpty else { return }
        fileUndoManager.setActionName(actionName)
        fileUndoManager.registerUndo(withTarget: self) { model in
            model.performUndoableCopy(done, actionName: actionName)
        }
        refreshUndoActionNames()
    }

    /// 撤销新建：只在新建项仍是同一个、且未被外部改动时移到废纸篓。
    private func performUndoableRemoveCreatedItems(_ steps: [UndoCreateStep], actionName: String) {
        var trashed: [(original: URL, trashURL: URL)] = []
        var skipped = 0
        for step in steps {
            guard step.snapshot.matches(url: step.url, fileManager: fileManager) else { skipped += 1; continue }
            do {
                var trashURL: NSURL?
                try fileManager.trashItem(at: step.url, resultingItemURL: &trashURL)
                appendUndoRedoLog(.deleted, at: step.url, detail: abbreviatedPath(step.url))
                if let trashURL = trashURL as URL? {
                    trashed.append((original: step.url, trashURL: trashURL))
                }
            } catch {
                skipped += 1
            }
        }
        reportUndoSkips(skipped)
        registerTrashUndo(trashed, actionName: actionName)
    }

    /// 撤销整理建议建出的文件夹:仅当它**存在且为空**(成员已被同组移动撤销移回)才移到废纸篓;否则跳过并提示
    /// (不静默删用户后来放进去的东西)。注册「重新建回空文件夹」作为重做。
    private func performUndoableRemoveOrganizeFolder(_ folder: URL, actionName: String) {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory)
        let isEmpty = ((try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty) ?? false
        guard exists, isDirectory.boolValue, isEmpty else { reportUndoSkips(1); return }
        do {
            var trashURL: NSURL?
            try fileManager.trashItem(at: folder, resultingItemURL: &trashURL)
            appendUndoRedoLog(.deleted, at: folder, detail: abbreviatedPath(folder))
            fileUndoManager.setActionName(actionName)
            fileUndoManager.registerUndo(withTarget: self) { model in
                model.performUndoableRecreateOrganizeFolder(folder, actionName: actionName)
            }
            refreshUndoActionNames()
        } catch {
            reportUndoSkips(1)
        }
    }

    /// 重做整理建议的文件夹创建:目标空闲才建回空文件夹,注册「再删空文件夹」作为下一轮撤销。
    private func performUndoableRecreateOrganizeFolder(_ folder: URL, actionName: String) {
        guard !fileManager.fileExists(atPath: folder.path) else { reportUndoSkips(1); return }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
            appendUndoRedoLog(.added, at: folder, detail: abbreviatedPath(folder))
            fileUndoManager.setActionName(actionName)
            fileUndoManager.registerUndo(withTarget: self) { model in
                model.performUndoableRemoveOrganizeFolder(folder, actionName: actionName)
            }
            refreshUndoActionNames()
        } catch {
            reportUndoSkips(1)
        }
    }

    func undoFileOperation() {
        guard fileUndoManager.canUndo else { return }
        let actionName = nonEmptyActionName(fileUndoManager.undoActionName)
        undoRedoTransferLog = []
        fileUndoManager.undo()
        refreshUndoActionNames()
        recordUndoRedoHistory(isUndo: true, actionName: actionName)
    }

    func redoFileOperation() {
        guard fileUndoManager.canRedo else { return }
        let actionName = nonEmptyActionName(fileUndoManager.redoActionName)
        undoRedoTransferLog = []
        fileUndoManager.redo()
        refreshUndoActionNames()
        recordUndoRedoHistory(isUndo: false, actionName: actionName)
    }

    /// 0.4.3:撤销 / 重做留痕活动中心 —— 独立「撤销与重做」分组的即时记录(开始即完成)。
    /// 唯一漏斗:⌘Z / ⇧⌘Z / 菜单都走 undoFileOperation / redoFileOperation。
    /// 用户点名要详情且要**格式化**:undo 原语执行时逐文件写 `undoRedoTransferLog`,
    /// 这里收割挂成 task.transferLog —— 跟解压 / 粘贴同一套分组卡片(图标 + 文件名 + 路径小字),历史也持久化。
    private func recordUndoRedoHistory(isUndo: Bool, actionName: String?) {
        let name = actionName ?? L10n.text("tasks.undoRedo.generic")
        let entries = undoRedoTransferLog
        undoRedoTransferLog = []
        let task = TaskCenter.shared.begin(
            category: .undoRedo,
            kind: isUndo ? .undo : .redo,
            title: L10n.format(isUndo ? "tasks.undo.title" : "tasks.redo.title", name),
            detail: entries.isEmpty ? nil : L10n.format("status.itemCount", entries.count),
            cancellable: false
        )
        task.transferLog = entries
        TaskCenter.shared.finish(task, outcome: .succeeded(nil))
    }

    /// 收集一条撤销 / 重做的逐文件记录。`isDirectory` 就地 stat(N 小,文件可能已不在则回退 false)。
    private func appendUndoRedoLog(_ action: TransferAction, at url: URL, detail: String) {
        var isDirectory: ObjCBool = false
        _ = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        undoRedoTransferLog.append(TransferLogEntry(
            name: url.lastPathComponent,
            action: action,
            isDirectory: isDirectory.boolValue,
            detail: detail
        ))
    }

    /// `/Users/<me>/…` → `~/…`,活动中心详情里的路径不再一长串。
    private func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    func refreshUndoActionNames() {
        fileUndoActionName = fileUndoManager.canUndo ? nonEmptyActionName(fileUndoManager.undoActionName) : nil
        fileRedoActionName = fileUndoManager.canRedo ? nonEmptyActionName(fileUndoManager.redoActionName) : nil
    }

    private func reportUndoSkips(_ count: Int) {
        guard count > 0 else { return }
        // 有步骤因「源已不在 / 目标被占」被跳过 —— 明确告诉用户，不静默、不覆盖。
        errorMessage = L10n.format("undo.partiallySkipped", count)
    }

    private func nonEmptyActionName(_ actionName: String) -> String? {
        let trimmed = actionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct UndoMoveStep {
    let from: URL
    let to: URL
    let sourceSnapshot: UndoFileSnapshot
}

private struct UndoCopyStep {
    let source: URL
    let dest: URL
    let sourceSnapshot: UndoFileSnapshot
    let destSnapshot: UndoFileSnapshot
}

private struct UndoCreateStep {
    let url: URL
    let snapshot: UndoFileSnapshot
}

/// 权限 / 属主撤销步骤：把 `url` 恢复到 `mode` / `owner`（nil = 该维度不动）。
struct UndoPermissionsStep {
    let url: URL
    let mode: UInt16?
    let owner: String?
}

// `UndoFileSnapshot`（撤销/重做的「文件未被改动」安全判定）已抽到 Core/UndoFileSnapshot.swift（SwiftPM 可测）。

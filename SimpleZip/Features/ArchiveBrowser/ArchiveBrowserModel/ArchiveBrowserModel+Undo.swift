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
//  保守安全（仓库铁律「绝不静默覆盖用户数据」）：每一步都要求「源存在 且 目标空闲」，
//  否则跳过该步并提示，绝不覆盖外部期间新建 / 改动的同名文件。

import AppKit
import Foundation

extension ArchiveBrowserModel {
    // MARK: - 注册（forward 操作成功后调用）

    /// 移动 / 重命名：forward 已把每个 from 移到了 to。撤销 = 反向移动。
    func registerMoveUndo(_ forwardPairs: [(from: URL, to: URL)], actionName: String) {
        let pairs = forwardPairs.filter { $0.from != $0.to }
        guard !pairs.isEmpty else { return }
        fileUndoManager.setActionName(actionName)
        fileUndoManager.registerUndo(withTarget: self) { model in
            model.performUndoableMoves(pairs.map { (from: $0.to, to: $0.from) }, actionName: actionName)
        }
    }

    /// 粘贴复制 / 创建副本：forward 已把每个 source 复制到 dest。撤销 = 删掉 dest（移到废纸篓）。
    func registerCopyUndo(_ forwardPairs: [(source: URL, dest: URL)], actionName: String) {
        guard !forwardPairs.isEmpty else { return }
        fileUndoManager.setActionName(actionName)
        fileUndoManager.registerUndo(withTarget: self) { model in
            model.performUndoableRemoveCopies(forwardPairs, actionName: actionName)
        }
    }

    /// 删除：forward 已把每个 original 移到了废纸篓的 trashURL。当成移动处理 —— 撤销 = trashURL → original。
    func registerTrashUndo(_ forwardPairs: [(original: URL, trashURL: URL)], actionName: String) {
        registerMoveUndo(forwardPairs.map { (from: $0.original, to: $0.trashURL) }, actionName: actionName)
    }

    // MARK: - 原语

    /// 把每个 from 移到 to（保守：源在、目标空才动），然后注册反向移动作为下一步撤销 / 重做。
    private func performUndoableMoves(_ pairs: [(from: URL, to: URL)], actionName: String) {
        var done: [(from: URL, to: URL)] = []
        var skipped = 0
        for pair in pairs {
            guard fileManager.fileExists(atPath: pair.from.path) else { skipped += 1; continue }
            guard !fileManager.fileExists(atPath: pair.to.path) else { skipped += 1; continue }
            do {
                try fileManager.createDirectory(at: pair.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: pair.from, to: pair.to)
                done.append(pair)
            } catch {
                skipped += 1
            }
        }
        reportUndoSkips(skipped)
        guard !done.isEmpty else { return }
        fileUndoManager.setActionName(actionName)
        fileUndoManager.registerUndo(withTarget: self) { model in
            model.performUndoableMoves(done.map { (from: $0.to, to: $0.from) }, actionName: actionName)
        }
    }

    /// 重做一次复制（撤销「删除复制产物」的逆）：把 source 重新复制到 dest。
    private func performUndoableCopy(_ pairs: [(source: URL, dest: URL)], actionName: String) {
        var done: [(source: URL, dest: URL)] = []
        var skipped = 0
        for pair in pairs {
            guard fileManager.fileExists(atPath: pair.source.path) else { skipped += 1; continue }
            guard !fileManager.fileExists(atPath: pair.dest.path) else { skipped += 1; continue }
            do {
                try fileManager.copyItem(at: pair.source, to: pair.dest)
                done.append(pair)
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
    }

    /// 撤销一次复制：把复制产物 dest 移到废纸篓（可恢复、非破坏），然后注册「重新复制」作为重做。
    private func performUndoableRemoveCopies(_ pairs: [(source: URL, dest: URL)], actionName: String) {
        var done: [(source: URL, dest: URL)] = []
        var skipped = 0
        for pair in pairs {
            guard fileManager.fileExists(atPath: pair.dest.path) else { skipped += 1; continue }
            do {
                var trashURL: NSURL?
                try fileManager.trashItem(at: pair.dest, resultingItemURL: &trashURL)
                done.append(pair)
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
    }

    private func reportUndoSkips(_ count: Int) {
        guard count > 0 else { return }
        // 有步骤因「源已不在 / 目标被占」被跳过 —— 明确告诉用户，不静默、不覆盖。
        errorMessage = L10n.format("undo.partiallySkipped", count)
    }
}

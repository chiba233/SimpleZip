//
//  FileTableEditing.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//

import AppKit
import Foundation

@MainActor
extension FileNSOutlineView.Coordinator {
    @objc func renameSelected() {
        _ = beginRenameSelected()
    }

    /// 给 Return 键 / 右键菜单共用：选中恰好一个文件时进入内联编辑。返回是否已处理。
    @discardableResult
    func beginRenameSelected() -> Bool {
        guard case .folder = model.mode,
              model.selectedFileItems.count == 1,
              let item = model.selectedFileItems.first else { return false }
        model.pendingInlineRenameURL = nil
        return beginRename(item)
    }

    @discardableResult
    func beginRename(_ item: FileItem) -> Bool {
        let itemURL = item.url.standardizedFileURL
        guard let outlineView,
              let nameColIndex = outlineView.tableColumns.firstIndex(where: { $0.identifier.rawValue == FileColumn.name.identifier }),
              let node = allFileNodes().first(where: { $0.fileItem?.url.standardizedFileURL == itemURL }),
              let currentItem = node.fileItem else { return false }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return false }
        outlineView.scrollRowToVisible(row)
        guard let cell = outlineView.view(atColumn: nameColIndex, row: row, makeIfNecessary: true) as? NSTableCellView,
              let textField = cell.textField else { return false }

        renamingItem = currentItem
        // 编辑真实磁盘名（不是 displayName），让用户改的就是最终文件名。
        let fullName = currentItem.url.lastPathComponent
        textField.isEditable = true
        textField.isSelectable = true
        textField.isBordered = true
        textField.bezelStyle = .squareBezel
        textField.drawsBackground = true
        textField.delegate = self
        textField.stringValue = fullName
        outlineView.window?.makeFirstResponder(textField)
        // 像 Finder：文件默认选中不含扩展名的主名；目录全选。
        if let editor = textField.currentEditor() {
            let stem = currentItem.isDirectory ? fullName : (fullName as NSString).deletingPathExtension
            let length = stem.isEmpty ? (fullName as NSString).length : (stem as NSString).length
            editor.selectedRange = NSRange(location: 0, length: length)
        }
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField, let item = renamingItem else { return }
        renamingItem = nil
        let cancelled = renameCancelled
        renameCancelled = false
        let newName = textField.stringValue
        // 编辑期间被推迟的内容刷新，现在补刷（成功改名会自己 loadFolder，这里主要兜住取消 / 无改动的情况）。
        if needsReloadAfterRename {
            needsReloadAfterRename = false
            DispatchQueue.main.async { [weak self] in self?.syncContent() }
        }

        // 还原成 label 外观；显示回原名，成功 rename 时下面 reload 会换成新名。
        textField.isEditable = false
        textField.isSelectable = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.delegate = nil
        textField.stringValue = item.displayName

        // Escape 取消（cancel 移动 / 我们的 Esc 标记）→ 不改名。
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? NSTextMovement.other.rawValue
        guard !cancelled, movement != NSTextMovement.cancel.rawValue else { return }
        model.renameFile(item, to: newName)
    }

    /// 回车提交 / Esc 取消 —— 显式结束字段编辑，避免某些情况下 Esc 不触发 endEditing、
    /// 输入框赖着不走（用户反馈：只能回车消、Esc 取消都不灵）。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard renamingItem != nil else { return false }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            renameCancelled = true
            outlineView?.window?.makeFirstResponder(outlineView)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            outlineView?.window?.makeFirstResponder(outlineView)
            return true
        default:
            return false
        }
    }

    /// 结束当前正在进行的内联重命名（提交）。用于「点开别处 / 切文件夹 / 列表 reload」时
    /// 把输入框收掉 —— 把第一响应者交回 outline 会触发 controlTextDidEndEditing 提交并还原外观。
    func endActiveRename() {
        guard renamingItem != nil, let outlineView else { return }
        outlineView.window?.makeFirstResponder(outlineView)
    }
}

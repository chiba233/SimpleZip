//
//  ContentDragOutlineView.swift
//  SimpleZip
//
//  Created by Codex on 2026/06/01.
//

import AppKit
import Quartz

/// NSOutlineView subclass shared by file/archive tables.
///
/// Dragging starts only from the primary column's icon or visible text. Empty row space remains available for
/// rubber-band selection, and the same hit testing routes force-clicks to rename or Quick Look.
final class ContentDragOutlineView: NSOutlineView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// Primary column identifier. nil disables content-originated dragging.
    var primaryColumnIdentifier: String?
    /// 仅图标可发起内容拖拽,文字区域留给选择 / 框选 / 拖选多行。**单列满宽的 AI 工作区列表设 true** ——
    /// 否则整行文字都是拖拽源,没有「死区」给框选,拖选多行 / 框选被拖拽抢掉。多列的文件 / 归档表保持 false
    /// (点名称列以外的列本就是 `.none`,有地方框选),文字也可拖。
    var dragFromIconOnly = false
    /// Whether the last mouse down landed on draggable content.
    private(set) var dragAllowedFromMouseDown = false
    /// Return/Enter action. Return true to consume the key.
    var returnKeyAction: (() -> Bool)?
    /// URLs for Quick Look preview. nil disables Quick Look for this table.
    var quickLookURLsProvider: (() -> [URL])?
    /// Maps a preview URL back to a row for Quick Look's zoom animation.
    var quickLookRowForURL: ((URL) -> Int?)?

    private enum HitRegion { case icon, text, none }
    private var lastMouseDownRegion: HitRegion = .none
    private var lastMouseDownRow: Int = -1
    private var didTriggerForceClick = false
    private var quickLookURLs: [URL] = []
    /// 是否存在「用户主动发起、且尚未关闭」的快速查看会话。
    /// QLPreviewPanel 是 app 级单例 + 走 responder 链：只有这个标志为 true 时我们才接管控制权，
    /// 否则（用户从没开过 / 已经关掉）一律拒绝 —— 避免双击打开 .siz、窗口重新激活时把陈旧面板顶回来。
    private var isQuickLookActive = false

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMouseDownRow = row(at: point)
        lastMouseDownRegion = hitRegion(at: point)
        dragAllowedFromMouseDown = lastMouseDownRegion != .none
        didTriggerForceClick = false
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Return/Enter:先试改名(returnKeyAction)。可展开项也要让改名优先 —— 否则可展开的行(如 AI 工作区
        // 的虚拟分组)按 Return 永远先展开、够不到改名。FileTable / 归档表的 returnKeyAction 对「非单个可改名项」
        // 返回 false,会自然回退到下面的展开/折叠,行为不变。
        if event.keyCode == 36 || event.keyCode == 76, let returnKeyAction, returnKeyAction() {
            return
        }
        // Space + Return:展开/折叠可展开项。
        if event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76 {
            if selectedRow >= 0, let item = item(atRow: selectedRow), isExpandable(item) {
                if isItemExpanded(item) { collapseItem(item) } else { expandItem(item) }
                return
            }
        }
        // Space:可展开项以外的行 → 快速查看。
        if event.keyCode == 49, presentQuickLook() {
            return
        }
        super.keyDown(with: event)
    }

    override func pressureChange(with event: NSEvent) {
        if event.stage >= 2, !didTriggerForceClick {
            didTriggerForceClick = true
            if lastMouseDownRow >= 0, selectedRow != lastMouseDownRow || numberOfSelectedRows != 1 {
                selectRowIndexes(IndexSet(integer: lastMouseDownRow), byExtendingSelection: false)
            }
            switch lastMouseDownRegion {
            case .text:
                if returnKeyAction?() == true { return }
            case .icon:
                if presentQuickLook() { return }
            case .none:
                break
            }
        }
        super.pressureChange(with: event)
    }

    @discardableResult
    func presentQuickLook() -> Bool {
        guard let provider = quickLookURLsProvider else { return false }
        return presentQuickLook(urls: provider())
    }

    /// 0.4.2 #10：直接喂 URL 的变体 —— 归档条目「快速预览」先解到临时目录再调这里
    /// （provider 是同步的，归档条目拿不出现成磁盘 URL）。
    @discardableResult
    func presentQuickLook(urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        quickLookURLs = urls
        guard let panel = QLPreviewPanel.shared() else { return false }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            isQuickLookActive = false
            panel.orderOut(nil)
        } else {
            isQuickLookActive = true
            panel.makeKeyAndOrderFront(nil)
        }
        return true
    }

    // 只有「用户主动发起、尚未关闭」的快速查看会话才接管共享 QLPreviewPanel 的控制权。
    // 否则（从没开过 / 已经关掉）一律拒绝：双击打开 .siz、窗口重新激活时 AppKit 会沿 responder 链
    // 重新找控制者，若无条件返回 true 就会把刚 orderOut 隐藏的陈旧面板又顶回来 —— 用户从没要过快速查看。
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        isQuickLookActive
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // 控制权结束（面板关闭 / 转移）→ 清掉会话标志，下次 AppKit 再问就拒绝，面板不会自己冒回来。
        isQuickLookActive = false
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookURLs[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.keyCode == 49 {
            isQuickLookActive = false
            panel.orderOut(nil)
            return true
        }
        return false
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item?.previewItemURL else { return .zero }
        return iconScreenFrame(for: url) ?? .zero
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = item?.previewItemURL,
              let colIndex = nameColumnIndex(),
              let row = quickLookRowForURL?(url), row >= 0,
              let cell = view(atColumn: colIndex, row: row, makeIfNecessary: false) as? NSTableCellView else {
            return nil
        }
        return cell.imageView?.image
    }

    private func nameColumnIndex() -> Int? {
        guard let primaryColumnIdentifier else { return nil }
        return tableColumns.firstIndex { $0.identifier.rawValue == primaryColumnIdentifier }
    }

    private func iconScreenFrame(for url: URL) -> NSRect? {
        guard let window,
              let colIndex = nameColumnIndex(),
              let row = quickLookRowForURL?(url), row >= 0,
              let cell = view(atColumn: colIndex, row: row, makeIfNecessary: false) as? NSTableCellView,
              let imageView = cell.imageView else {
            return nil
        }
        let rectInWindow = imageView.convert(imageView.bounds, to: nil)
        return window.convertToScreen(rectInWindow)
    }

    private func hitRegion(at point: NSPoint) -> HitRegion {
        let row = row(at: point)
        guard row >= 0,
              let primaryColumnIdentifier,
              let colIndex = tableColumns.firstIndex(where: { $0.identifier.rawValue == primaryColumnIdentifier }),
              column(at: point) == colIndex,
              let cell = view(atColumn: colIndex, row: row, makeIfNecessary: false) as? NSTableCellView else {
            return .none
        }
        let pointInCell = cell.convert(point, from: self)
        if let imageView = cell.imageView, imageView.frame.contains(pointInCell) {
            return .icon
        }
        if !dragFromIconOnly, let textField = cell.textField {
            let font = textField.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            let textWidth = (textField.stringValue as NSString).size(withAttributes: [.font: font]).width
            let glyphRect = NSRect(
                x: textField.frame.minX,
                y: textField.frame.minY,
                width: min(textWidth + 4, textField.frame.width),
                height: textField.frame.height
            )
            if glyphRect.contains(pointInCell) { return .text }
        }
        return .none
    }
}

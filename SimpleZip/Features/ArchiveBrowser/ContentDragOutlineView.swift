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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMouseDownRow = row(at: point)
        lastMouseDownRegion = hitRegion(at: point)
        dragAllowedFromMouseDown = lastMouseDownRegion != .none
        didTriggerForceClick = false
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76 {
            if selectedRow >= 0, let item = item(atRow: selectedRow), isExpandable(item) {
                if isItemExpanded(item) { collapseItem(item) } else { expandItem(item) }
                return
            }
        }
        if event.keyCode == 49, presentQuickLook() {
            return
        }
        if event.keyCode == 36 || event.keyCode == 76, let returnKeyAction, returnKeyAction() {
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
        let urls = provider()
        guard !urls.isEmpty else { return false }
        quickLookURLs = urls
        guard let panel = QLPreviewPanel.shared() else { return false }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        return true
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookURLs[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.keyCode == 49 {
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
        if let textField = cell.textField {
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

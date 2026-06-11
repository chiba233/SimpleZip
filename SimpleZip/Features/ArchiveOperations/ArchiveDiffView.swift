//
//  ArchiveDiffView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/10.
//
//  #111 Archive Diff —— 比较结果弹窗。引擎在 Core/ArchiveDiff.swift（纯逻辑、已单测），
//  这里只做展示：仅在 A / 仅在 B / 有差异（逐字段 before→after）/ 相同计数。
//  条目按目录层级组织成可收起的 outline 树（OutlineGroup），不平铺完整路径 —— 用户反馈。
//  分区视图（ArchiveDiffSections）被活动中心详情复用，保持弹窗和任务详情一个长相。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 一次归档比较的展示模型。`leftName` / `rightName` 用文件名标注方向 —— 比较任意两个包
/// 没有天然的「旧 / 新」，所以 UI 全部用「仅在 xxx 中」这种中性措辞，不说「新增 / 删除」。
struct ArchiveDiffReport: Identifiable {
    let id = UUID()
    let leftName: String
    let rightName: String
    let result: ArchiveDiffResult

    /// 整份报告的纯文本（「复制」按钮 + 活动中心复制用）。文本形态保留平铺完整路径 —— 便于粘进 diff/邮件。
    var plainTextSummary: String {
        var lines: [String] = []
        lines.append("\(L10n.text("diff.title")): \(leftName) ↔ \(rightName)")
        if !result.removed.isEmpty {
            lines.append("")
            lines.append("\(L10n.format("diff.onlyIn", leftName)) (\(result.removed.count)):")
            lines.append(contentsOf: result.removed.map { "  - \(ArchiveDiff.normalizedPath($0.name))" })
        }
        if !result.added.isEmpty {
            lines.append("")
            lines.append("\(L10n.format("diff.onlyIn", rightName)) (\(result.added.count)):")
            lines.append(contentsOf: result.added.map { "  + \(ArchiveDiff.normalizedPath($0.name))" })
        }
        if !result.changed.isEmpty {
            lines.append("")
            lines.append("\(L10n.text("diff.changed")) (\(result.changed.count)):")
            lines.append(contentsOf: result.changed.map { "  ~ \($0.path): \(ArchiveDiffSections.changeDescription($0))" })
        }
        lines.append("")
        lines.append(L10n.format("diff.unchangedCount", result.unchanged.count))
        return lines.joined(separator: "\n")
    }

    /// 人看的 Markdown 报告（导出用,跟 UI 语言走）。只列差异项,unchanged 进摘要计数 ——
    /// 机器可读的 JSON / CSV 在 Core `ArchiveDiffExport`（字段名固定英文）。
    var markdownReport: String {
        var lines: [String] = []
        lines.append("# \(L10n.text("diff.title"))")
        lines.append("")
        lines.append("**\(leftName) ↔ \(rightName)**")
        lines.append("")
        lines.append("- \(L10n.format("diff.onlyIn", leftName)): \(result.removed.count)")
        lines.append("- \(L10n.format("diff.onlyIn", rightName)): \(result.added.count)")
        lines.append("- \(L10n.text("diff.changed")): \(result.changed.count)")
        lines.append("- \(L10n.format("diff.unchangedCount", result.unchanged.count))")
        if !result.removed.isEmpty {
            lines.append("")
            lines.append("## \(L10n.format("diff.onlyIn", leftName)) (\(result.removed.count))")
            lines.append("")
            lines.append(contentsOf: result.removed.map { "- `\(ArchiveDiff.normalizedPath($0.name))`" })
        }
        if !result.added.isEmpty {
            lines.append("")
            lines.append("## \(L10n.format("diff.onlyIn", rightName)) (\(result.added.count))")
            lines.append("")
            lines.append(contentsOf: result.added.map { "- `\(ArchiveDiff.normalizedPath($0.name))`" })
        }
        if !result.changed.isEmpty {
            lines.append("")
            lines.append("## \(L10n.text("diff.changed")) (\(result.changed.count))")
            lines.append("")
            lines.append(contentsOf: result.changed.map { "- `\($0.path)` — \(ArchiveDiffSections.changeDescription($0))" })
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

struct ArchiveDiffView: View {
    let report: ArchiveDiffReport
    let onClose: () -> Void

    /// 0.4.2 #16：忽略 macOS 元数据垃圾（.DS_Store / __MACOSX / ._* …）—— 复制 / 导出同样遵守。
    @State private var hideJunk = false

    private var displayedReport: ArchiveDiffReport {
        hideJunk
            ? ArchiveDiffReport(leftName: report.leftName, rightName: report.rightName, result: report.result.filteringJunk())
            : report
    }

    var body: some View {
        // 0.4.2 用户点名：比较窗也套 0.4.1 的现代弹窗体例 —— hero 头 + 滚动内容 + 钉底操作栏。
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "arrow.left.arrow.right",
                colors: [.orange, .pink],
                title: L10n.text("diff.title"),
                subtitle: "\(report.leftName) ↔ \(report.rightName)"
            )

            ArchiveDiffSummaryLine(report: displayedReport)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            if displayedReport.result.hasDifferences {
                ScrollView {
                    ArchiveDiffSections(report: displayedReport)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                }
                .frame(minHeight: 300, maxHeight: .infinity)
            } else {
                // 没有差异时不渲染空列表，给一个明确的「完全一致」状态。
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                    Text(L10n.format("diff.identical", displayedReport.result.unchanged.count))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
            }

            Divider()

            // 钉底操作栏：左侧工具（导出 / 忽略垃圾 / 复制），右侧主按钮 —— 与创建 / 解压同款。
            HStack(spacing: 12) {
                Menu(L10n.text("diff.export")) {
                    Button(L10n.text("diff.export.json")) { exportReport(.json) }
                    Button(L10n.text("diff.export.csv")) { exportReport(.csv) }
                    Button(L10n.text("diff.export.markdown")) { exportReport(.markdown) }
                }
                .fixedSize()

                Toggle(L10n.text("diff.hideJunk"), isOn: $hideJunk)
                    .toggleStyle(.checkbox)

                Button(L10n.text("button.copyAll")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(displayedReport.plainTextSummary, forType: .string)
                }

                Spacer()

                Button(L10n.text("button.ok")) {
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 460, idealHeight: 580)
    }

    // MARK: - 导出（0.4.2）

    private enum ExportFormat {
        case json, csv, markdown

        var fileExtension: String {
            switch self {
            case .json: return "json"
            case .csv: return "csv"
            case .markdown: return "md"
            }
        }
    }

    private func exportReport(_ format: ExportFormat) {
        let content: String
        do {
            switch format {
            case .json:
                content = try ArchiveDiffExport.json(result: displayedReport.result, leftName: report.leftName, rightName: report.rightName)
            case .csv:
                content = ArchiveDiffExport.csv(result: displayedReport.result, leftName: report.leftName, rightName: report.rightName)
            case .markdown:
                content = displayedReport.markdownReport
            }
        } catch {
            presentExportError(error)
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(report.leftName)-vs-\(report.rightName).\(format.fileExtension)"
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentExportError(error)
        }
    }

    private func presentExportError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("diff.export.failedTitle")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

/// 比对计数摘要行（弹窗 + 活动中心共用）。
struct ArchiveDiffSummaryLine: View {
    let report: ArchiveDiffReport

    var body: some View {
        HStack(spacing: 14) {
            Label("\(report.result.removed.count)", systemImage: "minus.circle")
                .foregroundStyle(.red)
                .help(L10n.format("diff.onlyIn", report.leftName))
            Label("\(report.result.added.count)", systemImage: "plus.circle")
                .foregroundStyle(.green)
                .help(L10n.format("diff.onlyIn", report.rightName))
            Label("\(report.result.changed.count)", systemImage: "arrow.left.arrow.right.circle")
                .foregroundStyle(.orange)
                .help(L10n.text("diff.changed"))
            Label(L10n.format("diff.unchangedCount", report.result.unchanged.count), systemImage: "equal.circle")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

/// 三个差异分区（仅在 A / 仅在 B / 有差异），每区一棵按目录层级可收起的 outline 树。
/// `internal` 以便活动中心任务详情直接复用同一套展示（不要重画）。
struct ArchiveDiffSections: View {
    let report: ArchiveDiffReport

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            sectionCard(
                title: L10n.format("diff.onlyIn", report.leftName),
                systemImage: "minus.circle",
                tint: .red,
                nodes: ArchiveDiffTreeNode.tree(items: report.result.removed)
            )
            sectionCard(
                title: L10n.format("diff.onlyIn", report.rightName),
                systemImage: "plus.circle",
                tint: .green,
                nodes: ArchiveDiffTreeNode.tree(items: report.result.added)
            )
            sectionCard(
                title: L10n.text("diff.changed"),
                systemImage: "arrow.left.arrow.right.circle",
                tint: .orange,
                nodes: ArchiveDiffTreeNode.tree(changes: report.result.changed)
            )
        }
    }

    @ViewBuilder
    private func sectionCard(title: String, systemImage: String, tint: Color, nodes: [ArchiveDiffTreeNode]) -> some View {
        if !nodes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(title, systemImage: systemImage)
                        .font(.headline)
                        .foregroundStyle(tint)
                    Spacer()
                    Text("\(ArchiveDiffTreeNode.leafAndFolderEntryCount(nodes))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                // 不用 OutlineGroup：它在 List 之外不给子级缩进（只换折叠三角，内容跟父级同一 x），
                // 层级完全看不出来 —— 用户反馈。改成递归 DisclosureGroup，每层子级显式缩进。
                ForEach(nodes) { node in
                    ArchiveDiffNodeView(node: node)
                }
            }
            // 卡片外观对齐 DialogSection（12pt 圆角 + control 背景 + 弱描边）—— 0.4.2 体例统一。
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
        }
    }

    /// 一条修改的逐字段摘要：「大小 1.2 MB → 1.4 MB · CRC A1B2 → C3D4 · …」。
    /// 也被纯文本报告复用，保证看到的和拷走的一致。
    static func changeDescription(_ change: ArchiveEntryChange) -> String {
        var parts: [String] = []
        // 按固定顺序输出，保证同一结果文案稳定。
        if change.fields.contains(.type) {
            parts.append(L10n.text("diff.field.type"))
        }
        if change.fields.contains(.size) {
            parts.append(L10n.format("diff.field.size", change.before.sizeText, change.after.sizeText))
        }
        if change.fields.contains(.crc) {
            parts.append(L10n.format("diff.field.crc", change.before.crc, change.after.crc))
        }
        if change.fields.contains(.modified) {
            parts.append(L10n.format("diff.field.modified", change.before.modifiedText, change.after.modifiedText))
        }
        if change.fields.contains(.encryption) {
            parts.append(L10n.text(change.after.isEncrypted ? "diff.field.becameEncrypted" : "diff.field.becameUnencrypted"))
        }
        if change.fields.contains(.comment) {
            // 注释可多行可超长，逐字段摘要里只标「注释已更改」，不内联正文。
            parts.append(L10n.text("diff.field.comment"))
        }
        return parts.joined(separator: " · ")
    }
}

/// 树节点的递归渲染：目录 = DisclosureGroup（默认收起），子级整体左缩进一档；
/// 叶子 = 普通行，补一段与折叠三角等宽的前导留白，跟同级目录行的图标对齐。
private struct ArchiveDiffNodeView: View {
    let node: ArchiveDiffTreeNode

    var body: some View {
        if let children = node.children {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(children) { child in
                        ArchiveDiffNodeView(node: child)
                    }
                }
                .padding(.leading, 16)   // 每层级缩进一档，层级肉眼可分 —— 用户反馈修复
            } label: {
                nodeRow
            }
        } else {
            nodeRow
                .padding(.leading, 16)   // 对齐同级 DisclosureGroup 的折叠三角宽度
        }
    }

    private var nodeRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: node.isFolder ? "folder" : "doc")
                    .foregroundStyle(.secondary)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if !node.sizeText.isEmpty {
                    Text(node.sizeText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if !node.changeText.isEmpty {
                Text(node.changeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            }
        }
        .font(.callout)
    }
}

/// 差异条目的目录层级树节点。`children == nil` 即叶子（OutlineGroup 据此决定有没有展开三角）。
/// 中间目录可能只是路径前缀（包里没有对应条目）—— 一样成节点，让层级完整可收起。
struct ArchiveDiffTreeNode: Identifiable {
    let id: String          // 归一化完整路径，树内唯一
    let name: String        // 最后一段路径分量（行内显示用）
    let isFolder: Bool
    let sizeText: String    // 文件条目的大小（目录 / 前缀节点为空）
    let changeText: String  // 「有差异」区的逐字段摘要（其他区为空）
    var children: [ArchiveDiffTreeNode]?

    /// 「仅在 …」区：把 ArchiveItem 列表按路径组成树。
    static func tree(items: [ArchiveItem]) -> [ArchiveDiffTreeNode] {
        build(entries: items.map { item in
            Entry(
                path: ArchiveDiff.normalizedPath(item.name),
                isDirectory: item.isDirectory,
                sizeText: item.isDirectory ? "" : item.sizeText,
                changeText: ""
            )
        })
    }

    /// 「有差异」区：每条修改带逐字段摘要。
    static func tree(changes: [ArchiveEntryChange]) -> [ArchiveDiffTreeNode] {
        build(entries: changes.map { change in
            Entry(
                path: ArchiveDiff.normalizedPath(change.path),
                isDirectory: change.after.isDirectory,
                sizeText: change.after.isDirectory ? "" : change.after.sizeText,
                changeText: ArchiveDiffSections.changeDescription(change)
            )
        })
    }

    /// 区头计数 = 实际差异条目数（叶子 + 自身就是差异条目的目录），不算凑层级的前缀节点。
    static func leafAndFolderEntryCount(_ nodes: [ArchiveDiffTreeNode]) -> Int {
        nodes.reduce(0) { count, node in
            count + (node.isRealEntry ? 1 : 0) + leafAndFolderEntryCount(node.children ?? [])
        }
    }

    // MARK: - 构建

    private struct Entry {
        let path: String
        let isDirectory: Bool
        let sizeText: String
        let changeText: String
    }

    /// 仅路径前缀、本身不是差异条目的目录节点不计数。
    private var isRealEntry: Bool { !sizeText.isEmpty || !changeText.isEmpty || isEntryFolder }
    private let isEntryFolder: Bool

    private init(id: String, name: String, isFolder: Bool, isEntryFolder: Bool, sizeText: String, changeText: String, children: [ArchiveDiffTreeNode]?) {
        self.id = id
        self.name = name
        self.isFolder = isFolder
        self.isEntryFolder = isEntryFolder
        self.sizeText = sizeText
        self.changeText = changeText
        self.children = children
    }

    private final class MutableNode {
        var entry: Entry?
        var children: [String: MutableNode] = [:]
    }

    private static func build(entries: [Entry]) -> [ArchiveDiffTreeNode] {
        let root = MutableNode()
        for entry in entries {
            let components = entry.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            var node = root
            for component in components {
                if let child = node.children[component] {
                    node = child
                } else {
                    let child = MutableNode()
                    node.children[component] = child
                    node = child
                }
            }
            node.entry = entry
        }
        return convert(root, parentPath: "")
    }

    private static func convert(_ node: MutableNode, parentPath: String) -> [ArchiveDiffTreeNode] {
        node.children
            .map { name, child -> ArchiveDiffTreeNode in
                let path = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
                let childNodes = convert(child, parentPath: path)
                // 目录 = 包里标了目录的条目，或有子节点的路径前缀。
                let isEntryFolder = child.entry?.isDirectory ?? false
                let isFolder = isEntryFolder || !childNodes.isEmpty
                return ArchiveDiffTreeNode(
                    id: path,
                    name: name,
                    isFolder: isFolder,
                    isEntryFolder: isEntryFolder,
                    sizeText: child.entry?.sizeText ?? "",
                    changeText: child.entry?.changeText ?? "",
                    children: childNodes.isEmpty ? nil : childNodes
                )
            }
            .sorted { a, b in
                // 文件夹排前面，再按本地化字典序 —— 跟 Finder 列表一个习惯。
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }
}

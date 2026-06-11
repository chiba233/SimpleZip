//
//  ActivityTaskRow.swift
//  SimpleZip
//
//  0.3.3 代码质量拆分:从 ActivityView.swift 纯移动出来的单任务行 + 详情渲染
//  (哈希卡片 / 归档比较树 / 逐文件传输日志 / 命令输出),零行为变更。
//  ActivityView 留容器(侧栏 + 列表 + 设置页),这里管「一行任务长什么样」。
//

import AppKit
import SwiftUI

struct ActivityTaskRow: View {
    @ObservedObject var task: OperationTask
    @State private var isShowingDetails = false
    @State private var showsCopiedConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)
                    .background(iconColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Spacer()

                trailingControls
            }

            if task.status.isRunning {
                if let fraction = task.progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if isShowingDetails, hasDetails {
                if let report = task.hashReport {
                    hashResultDetails(report)
                } else if let diffReport = task.diffReport {
                    diffResultDetails(diffReport)
                } else if !task.transferLog.isEmpty {
                    // 文件操作：唯一一段「结果」。逐文件分组（新增/覆盖/跳过），
                    // 有哈希比对的项内嵌哈希卡片，不再单列第二段。
                    transferLogDetails(task.transferLog, hashComparisons: task.hashComparisons)
                } else if !task.hashComparisons.isEmpty {
                    // 旧版本历史只存了 hashComparisons、没有 transferLog —— 兼容回退。
                    hashComparisonDetails(task.hashComparisons)
                } else if let session = task.detailsSession {
                    commandOutputDetails(session)
                }
            }
        }
        .padding(.vertical, 8)
    }

    /// 哈希任务详情：复用「文件哈希」弹窗的同一套格式化卡片（HashResultCard），不画文本日志。
    @ViewBuilder
    private func hashResultDetails(_ report: HashReport) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(detailsHeaderTitle)
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.plainTextSummary, forType: .string)
                    withAnimation { showsCopiedConfirmation = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation { showsCopiedConfirmation = false }
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(L10n.text("button.copyAll"))
            }
            if showsCopiedConfirmation {
                Text(L10n.text("diagnostics.copied"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(report.results) { result in
                        HashResultCard(report: report, result: result)
                    }
                }
                .padding(.vertical, 2)
                .padding(.trailing, 16)   // 预留竖向滚动条宽度，避免盖住右侧长哈希值
            }
            .frame(maxHeight: 280)
        }
    }

    /// 归档比较任务详情：复用比较弹窗的同一套分区树（ArchiveDiffSections），不画文本日志。
    @ViewBuilder
    private func diffResultDetails(_ report: ArchiveDiffReport) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(detailsHeaderTitle)
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.plainTextSummary, forType: .string)
                    withAnimation { showsCopiedConfirmation = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation { showsCopiedConfirmation = false }
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(L10n.text("button.copyAll"))
            }
            if showsCopiedConfirmation {
                Text(L10n.text("diagnostics.copied"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ArchiveDiffSummaryLine(report: report)
            if report.result.hasDifferences {
                ScrollView {
                    ArchiveDiffSections(report: report)
                        .padding(.vertical, 2)
                        .padding(.trailing, 16)   // 预留竖向滚动条宽度
                }
                .frame(maxHeight: 280)
            } else {
                Text(L10n.format("diff.identical", report.result.unchanged.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 粘贴 / 移动覆盖前的哈希比对详情：每项一张格式化卡片（源哈希 vs 目标哈希 + 跳过/覆盖结果）。
    @ViewBuilder
    private func hashComparisonDetails(_ comparisons: [HashOverwriteResult]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(detailsHeaderTitle)
                .font(.caption.weight(.semibold))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(comparisons.enumerated()), id: \.offset) { _, result in
                        HashComparisonCard(result: result)
                    }
                }
                .padding(.vertical, 2)
                .padding(.trailing, 16)   // 预留竖向滚动条宽度，避免盖住右侧长哈希值
            }
            .frame(maxHeight: 280)
        }
    }

    /// 复制 / 移动 / 合并的逐文件结果：按「新增 / 覆盖 / 跳过」分组列出（补上「新增文件无痕」盲点）。
    /// 有哈希比对的项内嵌哈希卡片，作为这条任务唯一一段「结果」，不再单列第二段。
    /// （函数体有局部变量 + 显式 return，单返回一个 VStack，不需要 @ViewBuilder。）
    private func transferLogDetails(_ entries: [TransferLogEntry], hashComparisons: [HashOverwriteResult]) -> some View {
        let added = entries.filter { $0.action == .added }
        let overwritten = entries.filter { $0.action == .overwritten }
        let changed = entries.filter { $0.action == .changed }
        let skipped = entries.filter { $0.action == .skipped }
        let deleted = entries.filter { $0.action == .deleted }
        let failed = entries.filter { $0.action == .failed }
        let passed = entries.filter { $0.action == .passed }
        var hashByName: [String: HashOverwriteResult] = [:]
        for result in hashComparisons {
            hashByName[result.targetURL.lastPathComponent] = result
        }
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(detailsHeaderTitle)
                    .font(.caption.weight(.semibold))
                Spacer()
                transferLogSummary(added: added.count + passed.count, overwritten: overwritten.count + changed.count,
                                   skipped: skipped.count, failed: failed.count)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // 失败项排最前 —— 用户最关心「哪些没成」。
                    if !failed.isEmpty {
                        TransferLogGroup(title: L10n.text("transfer.section.failed"), entries: failed, icon: "exclamationmark.circle.fill", tint: .red, hashByName: hashByName)
                    }
                    if !passed.isEmpty {
                        TransferLogGroup(title: L10n.text("transfer.section.passed"), entries: passed, icon: "checkmark.seal.fill", tint: .green, hashByName: hashByName)
                    }
                    if !added.isEmpty {
                        TransferLogGroup(title: L10n.text("transfer.section.added"), entries: added, icon: "plus.circle.fill", tint: .green, hashByName: hashByName)
                    }
                    if !overwritten.isEmpty {
                        TransferLogGroup(title: L10n.text("transfer.section.overwritten"), entries: overwritten, icon: "arrow.triangle.2.circlepath.circle.fill", tint: .orange, hashByName: hashByName)
                    }
                    if !changed.isEmpty {
                        TransferLogGroup(title: L10n.text("transfer.section.changed"), entries: changed, icon: "lock.shield.fill", tint: .green, hashByName: hashByName)
                    }
                    if !skipped.isEmpty {
                        TransferLogGroup(title: L10n.text("transfer.section.skipped"), entries: skipped, icon: "minus.circle.fill", tint: .secondary, hashByName: hashByName)
                    }
                    if !deleted.isEmpty {
                        TransferLogGroup(title: L10n.text("transfer.section.deleted"), entries: deleted, icon: "trash.fill", tint: .red, hashByName: hashByName)
                    }
                }
                .padding(.vertical, 2)
                .padding(.trailing, 16)
            }
            .frame(maxHeight: 280)

            // 重试失败项 —— 仅当有失败项且任务挂了重试动作（运行时态，历史任务不可重试）。
            if !failed.isEmpty, let retry = task.retryFailed {
                Button {
                    retry()
                } label: {
                    Label(L10n.format("transfer.retryFailed", "\(failed.count)"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
        }
    }

    /// 详情顶部的「✓N · ⤼K · ✗M」计数摘要 —— 一眼看清批量结果分布。
    @ViewBuilder
    private func transferLogSummary(added: Int, overwritten: Int, skipped: Int, failed: Int) -> some View {
        HStack(spacing: 8) {
            if added + overwritten > 0 {
                summaryChip(count: added + overwritten, system: "checkmark.circle.fill", tint: .green)
            }
            if skipped > 0 {
                summaryChip(count: skipped, system: "minus.circle.fill", tint: .secondary)
            }
            if failed > 0 {
                summaryChip(count: failed, system: "exclamationmark.circle.fill", tint: .red)
            }
        }
    }

    @ViewBuilder
    private func summaryChip(count: Int, system: String, tint: Color) -> some View {
        Label("\(count)", systemImage: system)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
    }

    /// 任务日志里的等价后端命令行（BackendProcessRunner 统一打的 `$ ` 前缀行）。
    private func backendCommandLines(in session: ArchiveOperationDetailsSession) -> [String] {
        session.rawOutput.components(separatedBy: "\n").filter { $0.hasPrefix("$ ") }
    }

    /// 后端命令详情：实时命令输出文本日志（解压 / 压缩 / 测试）。
    @ViewBuilder
    private func commandOutputDetails(_ session: ArchiveOperationDetailsSession) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(detailsHeaderTitle)
                    .font(.caption.weight(.semibold))
                Spacer()
                // 0.4.2 #20：复制等价后端命令（口令不进 argv 无需脱敏；路径含本次操作的临时工作目录）。
                let commands = backendCommandLines(in: session)
                if !commands.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commands.map { String($0.dropFirst(2)) }.joined(separator: "\n"), forType: .string)
                        withAnimation { showsCopiedConfirmation = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            withAnimation { showsCopiedConfirmation = false }
                        }
                    } label: {
                        Image(systemName: "terminal")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("button.copyCommand.help"))
                }
                Button {
                    Task {
                        await DiagnosticsCopier.copy(session: session, errorMessage: errorMessage)
                        withAnimation { showsCopiedConfirmation = true }
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation { showsCopiedConfirmation = false }
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(L10n.text("button.copyDiagnostics"))
            }
            if showsCopiedConfirmation {
                Text(L10n.text("diagnostics.copied"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            CommandOutputLogView(text: session.rawOutput.isEmpty ? L10n.text("details.waiting") : session.rawOutput)
                .frame(height: 142)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                )
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: 6) {
            // 0.4.2 #21：任务结束后可整单重跑（运行时态——重启后的历史任务没有重跑闭包，按钮自然不出现）。
            if !task.status.isRunning, task.rerun != nil {
                Button {
                    task.rerun?()
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.borderless)
                .help(L10n.text("button.rerunTask"))
            }
            if task.status.isRunning, task.cancel != nil {
                Button {
                    task.cancel?()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help(L10n.text("button.cancel"))
            }
            // 只有「真有内容可看」时才给详情入口：归档操作运行中（命令输出随时来）或任何已积累了输出/
            // 哈希信息的任务。这样文件操作平平无奇的复制/移动不再出空面板，失败的也不再卡「正在等待命令输出…」，
            // 而哈希结果 / 粘贴时的源·目标哈希这类有用信息照样能展开看。
            if hasDetails {
                Button {
                    isShowingDetails.toggle()
                } label: {
                    Image(systemName: isShowingDetails ? "chevron.up.circle" : "info.circle")
                }
                .buttonStyle(.borderless)
                .help(L10n.text("button.details"))
            }
        }
        .foregroundStyle(.secondary)
    }

    private var iconName: String {
        switch task.kind {
        case .extract:
            return "tray.and.arrow.down"
        case .compress:
            return "doc.zipper"
        case .test:
            return "checkmark.seal"
        case .compare:
            return "arrow.left.arrow.right.circle"
        case .benchmark:
            return "speedometer"
        case .hash:
            return "number.square"
        case .paste, .copy:
            return "doc.on.doc"
        case .create:
            return "doc.badge.plus"
        case .move:
            return "folder.badge.gearshape"
        case .duplicate:
            return "plus.square.on.square"
        case .delete:
            return "trash"
        case .rename:
            return "pencil"
        case .permissions:
            return "lock.shield"
        case .split:
            return "rectangle.split.2x1"
        case .combine:
            return "arrow.triangle.merge"
        case .convert:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var iconColor: Color {
        switch task.status {
        case .running:
            return .accentColor
        case .succeeded:
            return .green
        case .skipped:
            // 不用绿色：跳过 = 没改动，绿色会让用户误以为覆盖/写入成功了。用中性灰区分。
            return .secondary
        case .failed:
            return .orange
        case .cancelled:
            return .secondary
        }
    }

    private var statusText: String {
        switch task.status {
        case .running:
            if let detail = task.detail, !detail.isEmpty {
                return detail
            }
            if let statusText = task.progress.statusText, !statusText.isEmpty {
                return statusText
            }
            if let currentFile = task.progress.currentFile, !currentFile.isEmpty {
                return currentFile
            }
            return L10n.text("tasks.running")
        case .succeeded:
            if let detail = task.detail, !detail.isEmpty {
                return detail
            }
            return L10n.text("status.done")
        case .skipped(let reason):
            return reason ?? L10n.text("tasks.fileOperation.skipped.noChange")
        case .failed(let message):
            return message
        case .cancelled:
            return L10n.text("status.cancelled")
        }
    }

    private var errorMessage: String? {
        if case .failed(let message) = task.status {
            return message
        }
        return nil
    }

    /// 是否给这条任务展示「详情」入口/面板。
    /// - 归档操作运行中：允许（后端命令输出会陆续来，先开着看实时输出）。
    /// - 其它情况：仅当 detailsSession 已有内容（哈希结果 / 粘贴的源·目标哈希等）。
    ///   平凡的复制/移动 + 失败任务都没有内容 → 不出空面板，也不再卡「正在等待命令输出…」。
    private var hasDetails: Bool {
        // 哈希任务 / 归档比较 / 粘贴·移动的哈希比对：有结构化结果就给详情入口（格式化卡片）。
        if task.hashReport != nil { return true }
        if task.diffReport != nil { return true }
        if !task.hashComparisons.isEmpty { return true }
        if !task.transferLog.isEmpty { return true }
        guard let session = task.detailsSession else { return false }
        // 测试：结果就是「通过 / 失败」，成功 / 进行中不必给命令框（图标 + 状态已说明一切，命令输出毫无价值）；
        // 只有失败才展开看是哪个文件 CRC 出错。
        if task.kind == .test {
            if case .failed = task.status { return !session.rawOutput.isEmpty }
            return false
        }
        // 真·后端命令（解压 / 压缩）运行中就允许展开看实时输出；其余只在已有内容时给入口。
        if isBackendCommand, task.status.isRunning { return true }
        return !session.rawOutput.isEmpty
    }

    /// 该任务是否跑了真正的后端命令（其详情才是「命令输出」）。哈希结果 / 文件操作的哈希对比不是命令输出。
    private var isBackendCommand: Bool {
        task.category == .archive && task.kind != .hash
    }

    /// 详情面板标题：后端命令 → 「命令输出」；哈希结果 / 文件哈希对比 → 「结果」（避免把哈希信息错叫成命令输出）。
    private var detailsHeaderTitle: String {
        isBackendCommand ? L10n.text("details.commandOutput") : L10n.text("details.results")
    }
}

/// 活动中心里的逐文件结果分组（新增 / 覆盖 / 跳过）。可折叠，长列表不炸；文件夹名带「（文件夹）」后缀。
private struct TransferLogGroup: View {
    let title: String
    let entries: [TransferLogEntry]
    let icon: String
    let tint: Color
    let hashByName: [String: HashOverwriteResult]
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                    Text(L10n.format("transfer.section.count", title, entries.count))
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    if let hash = hashByName[entry.name] {
                        // 有哈希比对 → 内嵌那张格式化卡片（源/目标哈希 + 状态）。
                        HashComparisonCard(result: hash)
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Image(systemName: icon)
                                    .foregroundStyle(tint)
                                Text(entry.isDirectory ? L10n.format("transfer.folderName", entry.name) : entry.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                            .font(.callout)
                            // 失败原因等备注 —— 缩进对齐文件名，灰色小字。
                            if let detail = entry.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .padding(.leading, 20)
                            }
                        }
                        .padding(.leading, 12)
                    }
                }
            }
        }
    }
}

/// 粘贴 / 移动覆盖前「源 vs 目标」哈希比对的格式化卡片（活动中心详情用）。
/// 风格对齐「文件哈希」弹窗的 HashResultCard：文件名 + 路径 + 哈希行 + 跳过/覆盖状态。
private struct HashComparisonCard: View {
    let result: HashOverwriteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(result.sourceURL.lastPathComponent, systemImage: "doc")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                statusLabel
            }

            Text(result.targetURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow {
                    Text(L10n.text("hashCompare.sourceHash"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
                    Text(result.sourceHash)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                }
                GridRow {
                    Text(L10n.text("hashCompare.targetHash"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
                    Text(result.targetHash)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                }
            }
            .textSelection(.enabled)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor))
        )
    }

    @ViewBuilder
    private var statusLabel: some View {
        Label(
            result.isSame
                ? L10n.text("tasks.fileOperation.hashDetail.skipped")
                : L10n.text("tasks.fileOperation.hashDetail.overwritten"),
            systemImage: result.isSame ? "equal.circle" : "arrow.triangle.2.circlepath"
        )
        .font(.caption)
        .foregroundStyle(result.isSame ? Color.secondary : Color.orange)
    }
}

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
    /// 详情展开态**外置**(0.4.4 bug 修复):列表是 LazyVStack,滚远的行被回收,
    /// 行内 @State 一并丢失 → 展开的卡片滚回来自动收起。真值挂在 ActivityView 的
    /// expandedTaskIDs(按任务 id),回收/重建都不丢。
    @Binding var isShowingDetails: Bool
    /// 0.4.4:重启后报告从落盘附件重开(openReport 闭包只活一个会话,nil 时回退到这里)。
    var onOpenAttachment: ((TaskReportAttachment) -> Void)?
    /// 复制反馈文案（nil = 不显示）。0.4.2 用户报「复制命令也显示诊断信息已复制」—— 按按钮分流。
    @State private var copiedConfirmationText: String?
    /// 0.4.4(用户反馈):命令输出框按内容真实高度收缩、封顶 300pt(不再固定 300)。0 = 还没测到。
    @State private var commandLogHeight: CGFloat = 0
    /// 0.4.4 D(macOS 26 AI):「解释失败」sheet 的展示状态。
    @State private var showsAIExplainFailure = false
    /// 命令输出框高度上限 —— 超过就在框内滚动。
    private static let commandLogMaxHeight: CGFloat = 300

    private func flashCopied(_ key: String) {
        withAnimation { copiedConfirmationText = L10n.text(key) }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { copiedConfirmationText = nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 用户拍板:卡头整行任意位置可点 = 展开/收起(帮助页同款手感);
            // 行内按钮(重跑/暂停/取消)自己接管点击,不受影响。
            HStack(alignment: .top, spacing: 12) {
                // 用户反馈:左侧彩色图标长得像按钮,点了没反应 —— 让它真的能点:
                // 有详情时点击 = 展开 / 收起(与右侧 ⓘ 同款),没详情保持纯装饰。
                Button {
                    if hasDetails {
                        isShowingDetails.toggle()
                    }
                } label: {
                    // #17 跟进(用户拍板,两轮):圆角矩形彩色瓦片;活动中心内容区瓦片**纯色不渐变**,
                    // 且再浅 30%(0.7 透明度)。侧栏瓦片(渐变实底)用户点名保留,不在此列。
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(iconColor.opacity(0.7))
                        .overlay(
                            Image(systemName: iconName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help(hasDetails ? L10n.text("button.details") : "")

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
            .contentShape(Rectangle())
            .onTapGesture {
                if hasDetails {
                    isShowingDetails.toggle()
                }
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
                    flashCopied("feedback.copied")
                } label: {
                    Self.controlIcon("doc.on.doc", tint: .blue)
                }
                .buttonStyle(.plain)
                .help(L10n.text("button.copyAll"))
            }
            if let copiedConfirmationText {
                Text(copiedConfirmationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // 0.4.4 用户报「几百个文件的哈希结果把卡片撑到天上」:详情封顶 320pt,
            // 贴内容生长、超过才内滚(HeightCappedScrollView —— 短内容仍无二级滚动条)。
            HeightCappedScrollView(maxHeight: 320) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(report.results) { result in
                        HashResultCard(report: report, result: result)
                    }
                }
            }
            .padding(.vertical, 2)
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
                    flashCopied("feedback.copied")
                } label: {
                    Self.controlIcon("doc.on.doc", tint: .blue)
                }
                .buttonStyle(.plain)
                .help(L10n.text("button.copyAll"))
            }
            if let copiedConfirmationText {
                Text(copiedConfirmationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ArchiveDiffSummaryLine(report: report)
            if report.result.hasDifferences {
                // 0.4.4:同哈希详情 —— 封顶 320pt,超过内滚。
                HeightCappedScrollView(maxHeight: 320) {
                    ArchiveDiffSections(report: report)
                }
                .padding(.vertical, 2)
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
            // 0.4.4:封顶 320pt,超过内滚(短内容不出现二级滚动条)。
            HeightCappedScrollView(maxHeight: 320) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(comparisons.enumerated()), id: \.offset) { _, result in
                        HashComparisonCard(result: result)
                    }
                }
            }
            .padding(.vertical, 2)
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
            // 0.4.4:封顶 320pt(贴内容生长,超过才内滚)—— 大批量文件不再把卡片撑到天上。
            HeightCappedScrollView(maxHeight: 320) {
                transferLogGroupsList(
                    failed: failed, passed: passed, added: added, overwritten: overwritten,
                    changed: changed, skipped: skipped, deleted: deleted, hashByName: hashByName
                )
            }
            .padding(.vertical, 2)

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

    /// 传输日志分组列表本体(transferLogDetails 拆出,套进高度封顶滚动)。
    @ViewBuilder
    private func transferLogGroupsList(
        failed: [TransferLogEntry], passed: [TransferLogEntry], added: [TransferLogEntry],
        overwritten: [TransferLogEntry], changed: [TransferLogEntry], skipped: [TransferLogEntry],
        deleted: [TransferLogEntry], hashByName: [String: HashOverwriteResult]
    ) -> some View {
            LazyVStack(alignment: .leading, spacing: 10) {
                    // 失败项排最前 —— 用户最关心「哪些没成」。
                    if !failed.isEmpty {
                        TransferLogGroup(title: L10n.text("transfer.section.failed"), entries: failed, icon: "exclamationmark.triangle.fill", tint: .red, hashByName: hashByName)
                    }
                    if !passed.isEmpty {
                        TransferLogGroup(title: L10n.text("transfer.section.passed"), entries: passed, icon: "checkmark", tint: .green, hashByName: hashByName)
                    }
                    if !added.isEmpty {
                        TransferLogGroup(title: L10n.text("transfer.section.added"), entries: added, icon: "plus", tint: .green, hashByName: hashByName)
                    }
                    if !overwritten.isEmpty {
                        TransferLogGroup(title: L10n.text("transfer.section.overwritten"), entries: overwritten, icon: "arrow.triangle.2.circlepath", tint: .orange, hashByName: hashByName)
                    }
                    if !changed.isEmpty {
                        TransferLogGroup(title: L10n.text("transfer.section.changed"), entries: changed, icon: "lock.shield.fill", tint: .green, hashByName: hashByName)
                    }
                    if !skipped.isEmpty {
                        TransferLogGroup(title: L10n.text("transfer.section.skipped"), entries: skipped, icon: "minus", tint: .secondary, hashByName: hashByName)
                    }
                    if !deleted.isEmpty {
                        TransferLogGroup(title: L10n.text("transfer.section.deleted"), entries: deleted, icon: "trash.fill", tint: .red, hashByName: hashByName)
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
                        flashCopied("command.copied")
                    } label: {
                        Self.controlIcon("terminal", tint: .purple)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("button.copyCommand.help"))
                }
                Button {
                    Task {
                        await DiagnosticsCopier.copy(session: session, errorMessage: errorMessage)
                        flashCopied("diagnostics.copied")
                    }
                } label: {
                    Self.controlIcon("doc.on.doc", tint: .blue)
                }
                .buttonStyle(.plain)
                .help(L10n.text("button.copyDiagnostics"))
                // 0.4.2 #22：把这单任务的诊断包导出成 .txt（脱敏 + 后端版本 + 文件系统现场）。
                Button {
                    DiagnosticsCopier.exportReport(session: session, errorMessage: errorMessage)
                } label: {
                    Self.controlIcon("square.and.arrow.up", tint: .teal)
                }
                .buttonStyle(.plain)
                .help(L10n.text("button.exportDiagnostics"))
            }
            if let copiedConfirmationText {
                Text(copiedConfirmationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            CommandOutputLogView(
                text: session.rawOutput.isEmpty ? L10n.text("details.waiting") : session.rawOutput,
                onMeasuredHeight: { measured in
                    let capped = min(measured, Self.commandLogMaxHeight)
                    // 抖动门槛:亚像素差不重设(避免测高→重渲染→再测高的来回)。
                    if abs(capped - commandLogHeight) > 0.5 { commandLogHeight = capped }
                }
            )
                // 测到后收缩到 min(内容高, 上限);未测到前给小初值(短 log 不闪高、长 log 才一次性长到上限)。
                .frame(height: commandLogHeight > 0 ? min(commandLogHeight, Self.commandLogMaxHeight) : 44)
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
            // 0.4.4:报告类任务 → 「查看报告」重开报告 sheet(用户点名:不该为看报告重跑一遍)。
            // 重启后闭包没了 → 用随历史落盘的报告附件重开(用户报「重启后查不了详情」)。
            if !task.status.isRunning, task.openReport != nil || task.reportAttachment != nil {
                Button {
                    if let openReport = task.openReport {
                        openReport()
                    } else if let attachment = task.reportAttachment {
                        onOpenAttachment?(attachment)
                    }
                } label: {
                    Self.controlIcon("doc.text.magnifyingglass", tint: .indigo)
                }
                .buttonStyle(.plain)
                .help(L10n.text("button.openReport"))
            }
            // 0.4.4 C:发布助手失败但产物还在 → 「从失败步继续」(跳过重新打包,对既有产物续跑)。
            if case .failed = task.status, task.resumeFromFailure != nil {
                Button {
                    task.resumeFromFailure?()
                } label: {
                    Self.controlIcon("arrow.uturn.forward", tint: .green)
                }
                .buttonStyle(.plain)
                .help(L10n.text("button.resumeFromFailure"))
            }
            // 0.4.4 D(macOS 26 AI):「解释失败」—— 仅 isReady 且任务失败时出现。读失败消息 + 命令输出,
            // 出可编辑的大白话解释 + 建议;只读、不改任何任务状态、不进安全写入路径。
            if case .failed(let failureMessage) = task.status, AIReportAssistant.isReady {
                Button {
                    showsAIExplainFailure = true
                } label: {
                    Self.controlIcon("sparkles", tint: .purple)
                }
                .buttonStyle(.plain)
                .help(L10n.text("ai.explainFailure"))
                .sheet(isPresented: $showsAIExplainFailure) {
                    AIAssistSheet(
                        title: L10n.text("ai.explainFailure.title"),
                        subtitle: task.title,
                        systemImage: "sparkles"
                    ) {
                        guard #available(macOS 26.0, *) else { throw AIAssistError(message: L10n.text("ai.unavailable.osTooOld")) }
                        let built = AIReportAssistant.failureExplanationPrompt(
                            taskTitle: task.title,
                            failureMessage: failureMessage,
                            output: task.detailsSession?.rawOutput
                        )
                        return try await AIReportAssistant.generate(instructions: built.instructions, prompt: built.prompt)
                    }
                }
            }
            // 0.4.4 D:「以新参数重跑…」—— 创建类任务重开对话框预填(运行时态)。
            if !task.status.isRunning, task.rerunWithChanges != nil {
                Button {
                    task.rerunWithChanges?()
                } label: {
                    Self.controlIcon("slider.horizontal.3", tint: .teal)
                }
                .buttonStyle(.plain)
                .help(L10n.text("button.rerunWithChanges"))
            }
            // 0.4.2 #21：任务结束后可整单重跑（运行时态——重启后的历史任务没有重跑闭包，按钮自然不出现）。
            if !task.status.isRunning, task.rerun != nil {
                Button {
                    task.rerun?()
                } label: {
                    Self.controlIcon("arrow.clockwise", tint: .blue)
                }
                .buttonStyle(.plain)
                .help(L10n.text("button.rerunTask"))
            }
            // 队列管理③:暂停 / 继续 —— 仅后端驱动的任务有此闭包;等并发槽时还没开跑,不给暂停。
            if task.status.isRunning, !task.isAwaitingSlot, task.pause != nil {
                Button {
                    task.isPaused ? task.resume?() : task.pause?()
                } label: {
                    Self.controlIcon(task.isPaused ? "play.fill" : "pause.fill", tint: .orange)
                }
                .buttonStyle(.plain)
                .help(L10n.text(task.isPaused ? "button.resumeTask" : "button.pauseTask"))
            }
            if task.status.isRunning, task.cancel != nil {
                Button {
                    task.cancel?()
                } label: {
                    Self.controlIcon("xmark", tint: .red)
                }
                .buttonStyle(.plain)
                .help(L10n.text("button.cancel"))
            }
            // 只有「真有内容可看」时才给详情入口：归档操作运行中（命令输出随时来）或任何已积累了输出/
            // 哈希信息的任务。这样文件操作平平无奇的复制/移动不再出空面板，失败的也不再卡「正在等待命令输出…」，
            // 而哈希结果 / 粘贴时的源·目标哈希这类有用信息照样能展开看。
            if hasDetails {
                // 用户拍板:详情开关换帮助页同款 —— 分类色 chevron + 淡色圆底,展开旋转 90°。
                Button {
                    isShowingDetails.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(categoryTint)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(categoryTint.opacity(0.14)))
                        .rotationEffect(.degrees(isShowingDetails ? 90 : 0))
                }
                .buttonStyle(.plain)
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
        case .undo:
            return "arrow.uturn.backward"
        case .redo:
            return "arrow.uturn.forward"
        case .search:
            return "text.magnifyingglass"
        case .inspect:
            return "checkmark.shield"
        }
    }

    /// 小控制图标的统一彩色瓦片样式(用户拍板:活动中心所有小图标都走彩色圆底,
    /// 与详情 chevron 同款 —— 不再是裸灰描线)。语义色:复制蓝/导出青/命令紫/重跑蓝/
    /// 续跑绿/暂停橙/取消红。
    static func controlIcon(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
            .background(Circle().fill(tint.opacity(0.14)))
    }

    /// 卡片分类色(与外层 chrome 同源:归档蓝 / 文件橙 / 撤销紫)。
    private var categoryTint: Color {
        switch task.category {
        case .archive: return .blue
        case .fileOperation: return .orange
        case .undoRedo: return .purple
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
            if task.isPaused {
                return L10n.text("tasks.paused")
            }
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
                                // 用户拍板:详情(折叠抽屉)内的图标同样换圆角矩形彩色小瓦片(纯色,浅 30%)。
                                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                    .fill(tint.opacity(0.7))
                                    .overlay(
                                        Image(systemName: icon)
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.white)
                                    )
                                    .frame(width: 16, height: 16)
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
                                    .padding(.leading, 22)
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

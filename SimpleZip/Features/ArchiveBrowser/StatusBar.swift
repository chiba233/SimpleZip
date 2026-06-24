//
//  StatusBar.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI
import AppKit

/// 底部状态栏：显示当前项目数量、任务状态和后端能力提示。
struct StatusBar: View {
    @ObservedObject var model: ArchiveBrowserModel
    @ObservedObject private var taskCenter = TaskCenter.shared

    // contextSummary 需要的文件系统属性，用 .task(id:) 后台异步填充，避免同步 getattrlist 在网络卷阻塞主线程
    // (dev11 取样实证：archiveURL.resourceValues(forKeys:.fileSizeKey) 在 body.getter 里同步阻塞 2427ms)。
    @State private var cachedPackedSize: Int? = nil
    @State private var cachedPackedSizeURL: URL? = nil
    @State private var cachedFreeSpace: Int64? = nil
    @State private var cachedFreeSpaceURL: URL? = nil

    private var currentArchiveURL: URL? { if case .archive(let u) = model.mode { return u }; return nil }
    private var currentFolderURL: URL? { if case .folder(let u) = model.mode { return u }; return nil }

    var body: some View {
        HStack(spacing: 8) {
            // 左侧：运行中显示进度条 + 当前文件（长度多变）；空闲显示状态文字。
            if taskCenter.runningCount > 0 {
                if let fraction = taskCenter.aggregateFraction {
                    ProgressView(value: fraction)
                        .frame(width: 140, alignment: .leading)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.format("tasks.runningCount", taskCenter.runningCount))
                        .foregroundStyle(.secondary)
                    Text(taskCenter.primaryProgressText ?? L10n.text("tasks.running"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else if model.isWorking {
                legacyProgressView
            } else {
                Text(model.status)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Spacer 把右侧操作区顶到尾部固定位置 —— 否则按钮跟在多变长度的文件名后面会左右漂移，
            // 「取消 / 详情」像 FPS 对枪一样难点（用户反馈）。文件名超长时左侧截断，右侧按钮位置不动。
            Spacer(minLength: 12)

            // 右侧固定操作区：详情（有 session 时）+ 取消（运行中且可取消）+ 后端能力提示。
            if taskCenter.runningCount > 0 {
                Button {
                    ActivityWindowController.shared.show(category: taskCenter.primaryActiveCategory)
                } label: {
                    Label(L10n.text("button.details"), systemImage: "info.circle")
                }
                .buttonStyle(.borderless)
                Button {
                    taskCenter.cancelAll()
                } label: {
                    Label(L10n.text("tasks.cancelAll"), systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
            } else if model.operationDetailsSession != nil {
                detailsButton
            }
            if taskCenter.runningCount == 0 && model.isWorking && model.canCancelCurrentOperation {
                Button {
                    model.cancelCurrentOperation()
                } label: {
                    Label(L10n.text("button.cancel"), systemImage: "xmark")
                }
                .buttonStyle(.borderless)
            }
            // 0.4.3 #13:打开的归档不可改写时,状态栏挂「只读」徽章,悬停给统一解释
            // (只读格式 / 临时解包副本 / 嵌套归档 / 后端缺失)—— 写入口不再静默消失得不明不白。
            if let restriction = model.archiveWriteRestriction {
                Label(L10n.text("status.readOnly"), systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .help(Self.restrictionExplanation(restriction))
            }
            // 右下角上下文信息 —— 原本是写死的「原生 ZIP | 7Z 通过 7zz」(早就过时,支持格式远不止这俩)。
            // 0.4.3 起换成动态数据:有选中 → 数量+总大小;归档无选中 → 解压后总大小 vs 包体;文件夹无选中 → 卷可用空间。
            if let contextSummary {
                Text(contextSummary)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // 跟地址栏同一 .bar 材质 —— 上下两条工具条一个质感（0.3.3 UI 现代化）。
        .background(.bar)
        // 归档包体大小：后台异步读，避免 getattrlist 在网络卷阻塞主线程（dev11 取样）。
        .task(id: currentArchiveURL) {
            guard let url = currentArchiveURL else {
                cachedPackedSizeURL = nil; cachedPackedSize = nil; return
            }
            let bytes = await Task.detached(priority: .utility) {
                try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            }.value
            cachedPackedSizeURL = url
            cachedPackedSize = bytes
        }
        // 卷可用空间：后台异步读，理由同上。
        .task(id: currentFolderURL) {
            guard let url = currentFolderURL else {
                cachedFreeSpaceURL = nil; cachedFreeSpace = nil; return
            }
            let bytes = await Task.detached(priority: .utility) {
                try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage
            }.value
            cachedFreeSpaceURL = url
            cachedFreeSpace = bytes
        }
    }

    /// 右下角的上下文摘要。选中条目按已知大小求和(目录 / 未知大小条目自然跳过);
    /// 归档模式的「解压后」是当前列表全部条目的逻辑大小合计,「包体」是归档文件在磁盘上的实际占用;
    /// 取不到数据(虚拟条目 / 卷信息读取失败)就整段不显示,不放占位假数据。
    private var contextSummary: String? {
        switch model.mode {
        case .archive(let archiveURL):
            let selected = model.archiveItems.filter { model.selectedArchiveRows.contains($0.id) }
            if !selected.isEmpty {
                return Self.selectionSummary(count: selected.count, bytes: selected.compactMap(\.size).reduce(0, +))
            }
            let unpacked = model.archiveItems.compactMap(\.size).reduce(0, +)
            // 包体大小由 .task(id:) 后台填入缓存，URL 不匹配时视为「还没拿到」→ 返回 nil 不显示占位
            guard unpacked > 0,
                  cachedPackedSizeURL == archiveURL,
                  let packed = cachedPackedSize else { return nil }
            return L10n.format(
                "status.archiveSummary",
                ByteCountFormatter.string(fromByteCount: unpacked, countStyle: .file),
                ByteCountFormatter.string(fromByteCount: Int64(packed), countStyle: .file)
            )
        case .folder(let folderURL):
            let selected = model.fileItems.filter { model.selection.contains($0.id) }
            if !selected.isEmpty {
                return Self.selectionSummary(count: selected.count, bytes: selected.compactMap(\.size).reduce(0, +))
            }
            // 卷可用空间由 .task(id:) 后台填入缓存
            guard cachedFreeSpaceURL == folderURL, let free = cachedFreeSpace else { return nil }
            return L10n.format("status.freeSpace", ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
        case .tag:
            let selected = model.fileItems.filter { model.selection.contains($0.id) }
            guard !selected.isEmpty else { return nil }
            return Self.selectionSummary(count: selected.count, bytes: selected.compactMap(\.size).reduce(0, +))
        case .aiWorkspace:
            return nil // AI 工作区状态栏不显示文件大小汇总(虚拟视图,无真实条目)。
        }
    }

    /// 全选目录时大小合计为 0,这时只报数量 —— 不显示「Zero KB」这种误导值。
    private static func selectionSummary(count: Int, bytes: Int64) -> String {
        guard bytes > 0 else { return L10n.format("status.selectionCount", count) }
        return L10n.format("status.selectionSummary", count, ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
    }

    /// 写入受限原因 → 用户可读解释(#13 统一文案,en+zh)。
    static func restrictionExplanation(_ restriction: ArchiveWriteRestriction) -> String {
        switch restriction {
        case .backendUnavailable:
            return L10n.text("writeGate.backendUnavailable")
        case .readOnlyFormat(let fileExtension):
            return L10n.format("writeGate.readOnlyFormat", fileExtension)
        case .temporaryExtractedCopy:
            return L10n.text("writeGate.temporaryCopy")
        case .nestedArchive:
            return L10n.text("writeGate.nestedArchive")
        }
    }

    private var legacyProgressView: some View {
        Group {
            if let fraction = model.operationProgress.fraction {
                ProgressView(value: fraction)
                    .frame(width: 140, alignment: .leading)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let progressCountText {
                    Text(progressCountText)
                        .foregroundStyle(.secondary)
                }
                Text(progressPrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var detailsButton: some View {
        Button {
            model.showOperationDetails()
        } label: {
            Label(L10n.text("button.details"), systemImage: "info.circle")
        }
        .buttonStyle(.borderless)
    }

    private var progressCountText: String? {
        guard let completed = model.operationProgress.completedUnitCount,
              let total = model.operationProgress.totalUnitCount,
              total > 0 else {
            return nil
        }
        return "\(min(completed, total))/\(total)"
    }

    private var progressPrimaryText: String {
        if let currentFile = model.operationProgress.currentFile, !currentFile.isEmpty {
            return currentFile
        }
        if let statusText = model.operationProgress.statusText, !statusText.isEmpty {
            return statusText
        }
        return model.status
    }
}

struct ArchiveOperationDetailsView: View {
    @ObservedObject var session: ArchiveOperationDetailsSession
    let close: () -> Void

    /// 「已复制」提示的可见状态。点完按钮 2.5 秒内显示，之后自动隐藏。
    /// 不用 alert / toast 框架是因为这就一行文字，简单的 @State + 延时切回就够。
    @State private var showsCopiedConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.title2.weight(.semibold))
                    if session.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if showsCopiedConfirmation {
                        Text(L10n.text("diagnostics.copied"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                Spacer()
                Button {
                    Task {
                        await DiagnosticsCopier.copy(session: session, errorMessage: nil)
                        withAnimation { showsCopiedConfirmation = true }
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation { showsCopiedConfirmation = false }
                    }
                } label: {
                    Label(L10n.text("button.copyDiagnostics"), systemImage: "doc.on.doc")
                }
                // #17:同一份现场按 GitHub Issue 模板出 Markdown(环境表+复现占位+脱敏日志)。
                Button {
                    Task {
                        await DiagnosticsCopier.copyGitHubIssue(session: session, errorMessage: nil)
                        withAnimation { showsCopiedConfirmation = true }
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation { showsCopiedConfirmation = false }
                    }
                } label: {
                    Label(L10n.text("button.copyAsIssue"), systemImage: "ladybug")
                }
                // B(macOS 26 AI):把同一份(已脱敏的)Issue Markdown 润色得更易读 —— 仅 isReady 时出现。
                AIAssistButton(
                    label: L10n.text("ai.polishIssue"),
                    systemImage: "sparkles",
                    sheetTitle: L10n.text("ai.polishIssue.title"),
                    sheetSubtitle: session.title
                ) {
                    guard #available(macOS 26.0, *) else { throw AIAssistError(message: L10n.text("ai.unavailable.osTooOld")) }
                    let raw = await DiagnosticsCopier.gitHubIssueMarkdown(session: session, errorMessage: nil)
                    let built = AIReportAssistant.issuePolishPrompt(rawIssue: raw)
                    return try await AIReportAssistant.generate(instructions: built.instructions, prompt: built.prompt)
                }
                // #59(macOS 26 AI):在润色之外,智能归类 —— 建议 issue 标题 + 标签 + 一段白话总结(只建议,不替提交)。
                AIAssistButton(
                    label: L10n.text("ai.categorizeIssue"),
                    systemImage: "tag",
                    sheetTitle: L10n.text("ai.categorizeIssue.title"),
                    sheetSubtitle: session.title
                ) {
                    guard #available(macOS 26.0, *) else { throw AIAssistError(message: L10n.text("ai.unavailable.osTooOld")) }
                    let raw = await DiagnosticsCopier.gitHubIssueMarkdown(session: session, errorMessage: nil)
                    let built = AIReportAssistant.issueCategorizePrompt(rawIssue: raw)
                    return try await AIReportAssistant.generate(instructions: built.instructions, prompt: built.prompt)
                }
                Button {
                    close()
                } label: {
                    Label(L10n.text("button.ok"), systemImage: "checkmark")
                }
                .keyboardShortcut(.defaultAction)
            }

            Text(L10n.text("details.commandOutput"))
                .font(.headline)

            // 用 NSTextView 而不是 SwiftUI Text —— Text 渲染大段流式文本（哪怕只有几百行）配 .fixedSize +
            // .textSelection 会很卡；NSTextView 懒布局 + 原生滚动 / 选择，专门干这个的。
            CommandOutputLogView(text: session.rawOutput.isEmpty ? L10n.text("details.waiting") : session.rawOutput)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor))
                )
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 500, idealHeight: 620)
    }
}

/// 高性能命令输出日志视图 —— 用 NSTextView（懒布局 + 原生滚动 / 文本选择），
/// 远比 SwiftUI `Text` 渲染大段流式文本流畅；配合 session 端只留最近 500 行，详情面板不再卡。
/// 0.4.2 嵌套滚动：日志框滚到顶/底后继续滚 → 把滚轮事件交还父级，
/// 外层列表无缝接管 —— 与原生 App 嵌套滚动手感一致。
final class EdgePassthroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let visible = documentVisibleRect
        let docHeight = documentView?.frame.height ?? 0
        let atTop = visible.minY <= 0.5
        let atBottom = visible.maxY >= docHeight - 0.5
        let delta = event.scrollingDeltaY
        // 内容根本不用滚 / 已到边缘还往外滚 → 整个事件给父级。
        if docHeight <= visible.height || (delta > 0 && atTop) || (delta < 0 && atBottom) {
            nextResponder?.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }
}

struct CommandOutputLogView: NSViewRepresentable {
    let text: String
    /// 0.4.4(用户反馈「log 很少也固定高」):回报内容在当前宽度下排版后的真实高度,
    /// 调用方据此 `min(内容高, 上限)` 设 frame —— 内容少就矮、超过上限才内滚。nil = 不测高(沿用外部固定 frame)。
    var onMeasuredHeight: ((CGFloat) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        // 手搭（不用 NSTextView.scrollableTextView()）—— 为了换成边缘穿透的 scroll view 子类。
        let scrollView = EdgePassthroughScrollView()
        let textView = NSTextView()
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.textContainer?.widthTracksTextView = true
            textView.string = text
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let textView = scrollView.documentView as? NSTextView, textView.string != text {
            textView.string = text
            // 始终跟到最新一行 —— 用户看流式 log 首要关心的是最新输出，不是旧的。
            // 用 scrollRangeToVisible(末尾) 而不是 scrollToEndOfDocument：前者会强制把目标 range 布局出来，
            // 刚换完 string 时还没排版完，后者可能滚不到真正的结尾。
            textView.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0))
        }
        // 测高在 string 已是最新、且 scrollView 已有真实宽度(updateNSView 在 SwiftUI 定尺后调)时做。
        reportHeight(of: scrollView)
    }

    /// 当前宽度下排版后的内容高度 = usedRect 高 + 上下内边距。异步回报避免「在视图更新中改 state」。
    private func reportHeight(of scrollView: NSScrollView) {
        guard let onMeasuredHeight,
              let textView = scrollView.documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let height = used + textView.textContainerInset.height * 2
        DispatchQueue.main.async { onMeasuredHeight(height) }
    }
}

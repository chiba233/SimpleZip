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

    var body: some View {
        HStack(spacing: 8) {
            // 左侧：运行中显示进度条 + 当前文件（长度多变）；空闲显示状态文字。
            if model.isWorking {
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
            } else {
                Text(model.status)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Spacer 把右侧操作区顶到尾部固定位置 —— 否则按钮跟在多变长度的文件名后面会左右漂移，
            // 「取消 / 详情」像 FPS 对枪一样难点（用户反馈）。文件名超长时左侧截断，右侧按钮位置不动。
            Spacer(minLength: 12)

            // 右侧固定操作区：详情（有 session 时）+ 取消（运行中且可取消）+ 后端能力提示。
            if model.operationDetailsSession != nil {
                detailsButton
            }
            if model.isWorking && model.canCancelCurrentOperation {
                Button(L10n.text("button.cancel")) {
                    model.cancelCurrentOperation()
                }
                .buttonStyle(.borderless)
            }
            Text(L10n.text("status.backend"))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var detailsButton: some View {
        Button(L10n.text("button.details")) {
            model.showOperationDetails()
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
                Button(L10n.text("button.copyDiagnostics")) {
                    Task {
                        await DiagnosticsCopier.copy(session: session, errorMessage: nil)
                        withAnimation { showsCopiedConfirmation = true }
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation { showsCopiedConfirmation = false }
                    }
                }
                Button(L10n.text("button.ok")) {
                    close()
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
private struct CommandOutputLogView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
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
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        // 跟随尾部：仅当用户当前已滚到底部时，更新后自动滚到底；上滑看历史时不打扰。
        let docHeight = scrollView.documentView?.bounds.height ?? 0
        let wasAtBottom = scrollView.contentView.bounds.maxY >= docHeight - 4
        textView.string = text
        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }
}

//
//  StatusBar.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

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

            ScrollView([.horizontal, .vertical]) {
                Text(session.rawOutput.isEmpty ? L10n.text("details.waiting") : session.rawOutput)
                    .font(.system(.caption, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
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

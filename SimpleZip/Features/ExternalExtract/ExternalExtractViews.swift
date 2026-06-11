//
//  ExternalExtractViews.swift
//  SimpleZip
//
//  0.3.0 架构拆分：从 ExternalExtractWindow.swift 切出的浮窗内容视图，纯移动、零行为变更。
//

import AppKit
import SwiftUI

/// 浮窗头部的纯色图标瓦片 —— 跟侧栏彩色瓦片同一设计语言，稍大一号、带同色软阴影
/// （解压蓝 / 创建橙 / 验证绿，一眼分清浮窗在干什么；box 不渐变）。
private struct FloatIconTile: View {
    let systemImage: String
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(color)
            .saturation(0.75)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: 32, height: 32)
            .shadow(color: color.opacity(0.35), radius: 4, y: 1)
    }
}

/// 单任务浮窗内容：固定 360 宽，VStack 包标题 / 进度条 / 当前文件 / 状态行。
struct ExternalExtractView: View {
    @ObservedObject var session: ExternalExtractSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                FloatIconTile(systemImage: "doc.zipper", color: .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(session.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let fraction = session.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else if session.status == .running {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if let currentFile = session.currentFileName, session.status == .running {
                Text(currentFile)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                switch session.status {
                case .running:
                    Button(L10n.text("tasks.window.title")) {
                        ActivityWindowController.shared.show(category: .archive)
                    }
                    if let onOpenInMainWindow = session.onOpenInMainWindow {
                        Button(L10n.text("externalExtract.openInMainWindow"), action: onOpenInMainWindow)
                    }
                    Spacer()
                    Button(L10n.text("button.cancel")) {
                        session.cancel()
                    }
                case .succeeded:
                    Label(L10n.text("externalExtract.done"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 2) {
                        Label(L10n.text("externalExtract.failed"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let onOpenInMainWindow = session.onOpenInMainWindow {
                        Button(L10n.text("externalExtract.openInMainWindow"), action: onOpenInMainWindow)
                    }
                    Button(L10n.text("tasks.window.title")) {
                        ActivityWindowController.shared.show(category: .archive)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .top)
    }
}

/// 批量浮窗内容：标题显示「解压 N 个压缩包」，进行中显示「N / M：名字」+ 进度；结束显示成功 / 失败汇总。
struct ExternalExtractBatchView: View {
    @ObservedObject var session: ExternalExtractBatchSession

    /// 失败列表最多展示几条，超出折叠成「+N」，避免浮窗被撑爆。
    private let maxFailureLines = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                FloatIconTile(systemImage: "doc.zipper", color: .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.format("externalExtract.batch.title", session.total))
                        .font(.headline)
                        .lineLimit(1)
                    Text(session.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            if !session.isFinished {
                if let fraction = session.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if let currentFile = session.currentFileName {
                    Text(currentFile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button(L10n.text("tasks.window.title")) {
                        ActivityWindowController.shared.show(category: .archive)
                    }
                    Spacer()
                    Button(L10n.text("button.cancel")) { session.cancel() }
                }
            } else if session.failures.isEmpty {
                Label(L10n.format("externalExtract.batch.allDone", session.succeeded.count), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        L10n.format("externalExtract.batch.summary", session.succeeded.count, session.failures.count),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    ForEach(session.failures.prefix(maxFailureLines)) { failure in
                        Text("\(failure.name): \(failure.message)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if session.failures.count > maxFailureLines {
                        Text(L10n.format("externalExtract.batch.moreFailures", session.failures.count - maxFailureLines))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .top)
    }
}

/// `.siz`/`.szs` 准备阶段浮窗内容。
struct ExternalPrepareView: View {
    @ObservedObject var session: ExternalPrepareSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                FloatIconTile(systemImage: "checkmark.seal", color: .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            switch session.phase {
            case .verifying:
                ProgressView().progressViewStyle(.linear)
            case .succeeded(let url):
                Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    if let onOpenInMainWindow = session.onOpenInMainWindow {
                        Button(L10n.text("externalExtract.openInMainWindow"), action: onOpenInMainWindow)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .top)
    }

    private var statusText: String {
        switch session.phase {
        case .verifying: return L10n.text("externalExtract.verifying")
        case .succeeded: return L10n.text("status.done")
        case .failed: return L10n.text("externalExtract.failed")
        }
    }
}

/// Finder 一键创建浮窗内容 —— 和 `ExternalExtractView` 同构（创建文案 + 无「在主窗口打开」）。
struct ExternalCreateView: View {
    @ObservedObject var session: ExternalCreateSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                FloatIconTile(systemImage: "plus.square.on.square", color: .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(session.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let fraction = session.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else if session.status == .running {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if let currentFile = session.currentFileName, session.status == .running {
                Text(currentFile)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                switch session.status {
                case .running:
                    Button(L10n.text("tasks.window.title")) {
                        ActivityWindowController.shared.show(category: .archive)
                    }
                    Spacer()
                    Button(L10n.text("button.cancel")) {
                        session.cancel()
                    }
                case .succeeded:
                    Label(L10n.text("externalCreate.done"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 2) {
                        Label(L10n.text("externalCreate.failed"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(L10n.text("tasks.window.title")) {
                        ActivityWindowController.shared.show(category: .archive)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .top)
    }
}

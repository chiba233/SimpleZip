//
//  AIAssistSheet.swift
//  SimpleZip
//
//  0.4.4 · macOS 26 AI:AI 生成结果的统一展示 sheet。loading → **可编辑** TextEditor(macOS 15.1+ 自动
//  吃 Writing Tools)→ 复制 / 重新生成 / 关闭。输入只读(prompt 在 producer 闭包里组装),输出可编辑由
//  用户审阅后自取;**绝不触发任何写入 / 安全判定**。固定免责声明:AI 可能出错,以实际报告为准。
//

import AppKit
import SwiftUI

struct AIAssistSheet: View {
    let title: String
    let subtitle: String
    let systemImage: String
    /// 生成闭包:组装 prompt + 调 `AIReportAssistant.generate`(仅 macOS 26+,调用点已 isReady 守卫)。
    let produce: () async throws -> String

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(systemImage: systemImage, colors: [.purple, .indigo], title: title, subtitle: subtitle)
                .padding(20)

            Divider()

            content
                .padding(20)

            Divider()

            PinnedBottomBar {
                if !isLoading, errorMessage == nil {
                    Button(action: copy) {
                        Label(copied ? L10n.text("diagnostics.copied") : L10n.text("button.copy"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button { Task { await run() } } label: {
                        Label(L10n.text("ai.regenerate"), systemImage: "arrow.clockwise")
                    }
                }
                Spacer()
                Button { dismiss() } label: {
                    Label(L10n.text("button.ok"), systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 580)
        .task { await run() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.text("ai.generating")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        } else if let errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                Text(errorMessage)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button { Task { await run() } } label: {
                    Label(L10n.text("ai.regenerate"), systemImage: "arrow.clockwise")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // 可编辑:macOS 15.1+ 选中文本即出 Writing Tools(改写 / 缩写 / 校对)。
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 180, maxHeight: 360)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.18))
                    )
                Text(L10n.text("ai.disclaimer"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func run() async {
        isLoading = true
        errorMessage = nil
        copied = false
        do {
            text = try await produce()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}

/// 统一的「AI 助手」按钮:**仅当 `AIReportAssistant.isReady`(开关开 + macOS 26 + 模型可用)时才渲染**,
/// 点开 `AIAssistSheet`。各报告 / 任务面把自己的 prompt 组装放进 `produce` 闭包(只读输入)。
/// 主开关关、旧系统、模型没下完都让整个按钮消失 —— 不留一个点了报错的死入口。
struct AIAssistButton: View {
    let label: String
    let systemImage: String
    let sheetTitle: String
    let sheetSubtitle: String
    let produce: () async throws -> String

    @State private var showsSheet = false

    var body: some View {
        if AIReportAssistant.isReady {
            Button { showsSheet = true } label: {
                Label(label, systemImage: systemImage)
            }
            .sheet(isPresented: $showsSheet) {
                AIAssistSheet(title: sheetTitle, subtitle: sheetSubtitle, systemImage: systemImage, produce: produce)
            }
        }
    }
}

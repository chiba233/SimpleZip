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
    /// 生成闭包:默认组装 prompt + 调 `AIReportAssistant.generate`；`initialText` 模式下只作为防御性 fallback。
    let produce: () async throws -> String
    let allowsRegenerate: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isLoading: Bool
    @State private var errorMessage: String?
    @State private var copied = false

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        initialText: String? = nil,
        allowsRegenerate: Bool = true,
        produce: @escaping () async throws -> String
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.produce = produce
        self.allowsRegenerate = allowsRegenerate
        _text = State(initialValue: initialText ?? "")
        _isLoading = State(initialValue: initialText == nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            // DialogHero 自带 padding(top 20 / bottom 14 / h 20),别再外套一层(否则双倍 = 大额头)。
            DialogHero(systemImage: systemImage, colors: [.purple, .indigo], title: title, subtitle: subtitle)

            Divider()

            content
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

            Divider()

            PinnedBottomBar {
                if !isLoading, errorMessage == nil {
                    Button(action: copy) {
                        Label(copied ? L10n.text("diagnostics.copied") : L10n.text("button.copy"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    if allowsRegenerate {
                        Button { Task { await run() } } label: {
                            Label(L10n.text("ai.regenerate"), systemImage: "arrow.clockwise")
                        }
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
        .task {
            guard text.isEmpty, isLoading else { return }
            await run()
        }
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
        // #76:走 AIGate 统一门控 —— AI 主开关一翻实时显隐(原先直接 `if isReady` 对开关变化不响应)。
        AIGate {
            Button { showsSheet = true } label: {
                Label(label, systemImage: systemImage)
            }
            .sheet(isPresented: $showsSheet) {
                AIAssistSheet(title: sheetTitle, subtitle: sheetSubtitle, systemImage: systemImage, produce: produce)
            }
        }
    }
}

/// #76 AI 门控容器:仅当「AI 主开关开 + macOS 26 + 系统模型可用」时渲染 `content`,且**主开关一翻实时刷新**。
///
/// 关键在 `@AppStorage`:它把视图订阅到 `aiAssistantEnabled`(UserDefaults 键,全 App 范围生效 —— 设置窗里
/// 翻开关,别的窗口里的 AI 门控视图也一并重算)。`AIReportAssistant.isReady` 是静态计算属性、对 SwiftUI 不可见,
/// body 里直接 `if isReady {}` 不会因开关变化而重算 —— 这正是「关掉 AI 后入口不消失」的根因。所有 AI 入口
/// 统一走这个容器:既集中就绪判断,又拿到响应式刷新。**新增 AI 入口请一律用它,别再裸写 `if AIReportAssistant.isReady`。**
struct AIGate<Content: View>: View {
    @AppStorage(AppPreferences.Key.aiAssistantEnabled) private var aiEnabled = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        // aiEnabled 提供响应式依赖;isReady 仍做完整判断(macOS 版本 + 模型 availability + 再读一次主开关,
        // 与 aiEnabled 同源、一致)。响应式刷新由 aiEnabled 这份订阅驱动。
        if aiEnabled, AIReportAssistant.isReady {
            content()
        }
    }
}

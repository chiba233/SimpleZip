//
//  InlineAIAdvisory.swift
//  SimpleZip
//
//  0.4.4 · macOS 26 AI:创建 / 解压对话框预检区的**内联自动 AI 速览**。
//
//  用户点名:打开创建 / 解压窗口就**静默运行**(无需手点),且**动态** —— 输入(文件数 / 格式 / 级别 /
//  目标位置)变了自动重跑。仅 `AIReportAssistant.isReady`(开关开 + macOS 26 + 模型可用)时渲染;
//  不可用整体不出现,对话框保留确定性预检不受影响。失败静默(不在对话框里堆 AI 错误)。
//
//  **红线**:只描述 / 估时 / 建议,绝不改任何创建 / 解压选项,绝不放行安全询问。
//

import SwiftUI

struct InlineAIAdvisory: View {
    /// 输入指纹:变了就重跑(动态)。窗口一开、数据就绪即首跑。
    let token: String
    /// 组装 prompt + 调 `AIReportAssistant.generate`(只读输入)。
    let produce: () async throws -> String

    @State private var text: String?
    // 初始就 true:打开窗口即显示菊花(用户要的「正在生成」反馈),且保证 `.task` 挂在一个**非空**视图上
    // 一定触发(挂在空 ViewBuilder 上 `.task` 不会跑 —— 这是「完全不显示」的根因)。
    @State private var isLoading = true

    var body: some View {
        if AIReportAssistant.isReady {
            content.task(id: token) { await run() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let text, !text.isEmpty {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.purple)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("ai.disclaimer"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 3)
        } else if isLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.text("ai.generating"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 3)
        }
    }

    @MainActor
    private func run() async {
        isLoading = true
        // 防抖:`.task(id:)` 已取消上一个;再等一拍合并连续改动(快速改格式 / 级别滑块等),避免狂跑模型。
        try? await Task.sleep(nanoseconds: 450_000_000)
        // 被取消(token 变了 → 新 task 接手)就**直接退出,不动 isLoading** —— 新 task 已置 true,让菊花
        // 持续显示直到某个 task 真正跑完。这是创建对话框「预估异步到达 → token 抖动 → 菊花被闪没 → 完全不显示」的修复。
        if Task.isCancelled { return }
        do {
            let result = try await produce()
            guard !Task.isCancelled else { return }
            text = result
        } catch {
            // 失败静默:保留上次结果(若有),不打扰创建 / 解压流程。
            guard !Task.isCancelled else { return }
        }
        isLoading = false
    }
}

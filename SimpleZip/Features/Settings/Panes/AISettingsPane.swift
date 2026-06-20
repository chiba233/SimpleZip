//
//  AISettingsPane.swift
//  SimpleZip
//
//  0.4.5 #80:「AI 与智能建议」设置页(白皮书工程补充三「用户开关」/ 建议)。AI 功能的统一开关入口 ——
//  从「自动化」页搬来 AI 助手主开关(单一归属,不留两处),给 AI 一个独立的家,后续数据控制开关在此扩展。
//
//  A4 例外:本页是 AI 主开关的唯一开启入口,**始终可见**(关掉 AI 后主界面其它 AI 入口才隐藏,但这页要让用户能再开回来)。
//  复用现成的、**已接线**的控件与 L10n key —— 不在没有消费者时新增「空开关」(A8)。
//

import AppKit
import SwiftUI

struct AISettingsPane: View {
    /// AI 报告助手主开关。关 → 主界面所有 AI 入口隐藏(各处读 `AppPreferences.aiAssistantEnabled` / `AIReportAssistant.isReady`)。
    @AppStorage(AppPreferences.Key.aiAssistantEnabled) private var aiAssistant = true
    /// AI 建议子开关。关 → 文件浏览器 AI 抽屉不显示 + 后台自动总结模块停跑。
    @AppStorage(AppPreferences.Key.aiSuggestionEnabled) private var aiSuggestion = true

    /// AI 后端运行状态(阶段3:推理迁独立进程后,失败会静默退确定性兜底 → 这里给用户**可见**的健康度)。
    /// 进页自动探一次前台 XPC Service(probeModel);失败时用户一眼看见,不再只是「AI 怎么不出东西」。
    private enum BackendStatus: Equatable {
        case checking          // 探测中
        case healthy           // XPC 后端连通 + 模型可用
        case modelUnavailable  // 本机模型不可用(旧系统 / 没开 Apple Intelligence / 没下完)
        case unreachable       // 后端连不上(已重试仍失败)
    }
    @State private var backendStatus: BackendStatus = .checking

    var body: some View {
        Form {
            // AI 助手主开关 + 能力状态。开但模型不可用(旧系统 / 没开 Apple Intelligence / 没下完)→ 说明文案。
            Section(L10n.text("settings.automation.ai.section")) {
                SettingsToggleRow(
                    title: L10n.text("settings.automation.ai.title"),
                    description: L10n.text("settings.automation.ai.description"),
                    systemImage: "sparkles", iconTint: .purple,
                    isOn: $aiAssistant
                )
                if aiAssistant, !AIReportAssistant.isReady {
                    Text(AIReportAssistant.unavailableReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // AI 建议子开关(主开关开启时才显示)。关 → 文件浏览器抽屉不显示 + 后台自动总结停跑。
                if aiAssistant {
                    SettingsToggleRow(
                        title: L10n.text("settings.ai.suggestion.title"),
                        description: L10n.text("settings.ai.suggestion.desc"),
                        systemImage: "text.line.first.and.arrowtriangle.forward", iconTint: .purple,
                        isOn: $aiSuggestion
                    )
                }
            }
            .settingsAnchor("automation.ai")

            // 运行状态:AI 后端(前台 XPC Service)的实时健康度 + 重新检查(AI 主开关开启时才显示)。
            // 阶段3 推理迁独立进程后,后端失败会静默退确定性兜底 → 这里让失败**可见**,不再「不知道 AI 挂没挂」。
            if aiAssistant {
                Section(L10n.text("settings.ai.status.section")) {
                    HStack(spacing: 10) {
                        Image(systemName: statusSystemImage)
                            .foregroundStyle(statusTint)
                            .font(.body)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(statusTitle).font(.callout)
                            if let detail = statusDetail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 12)
                        Button(L10n.text("settings.ai.status.recheck")) { probeBackend() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(backendStatus == .checking)
                    }
                    if let lastIndex = lastBackgroundIndexText {
                        HStack(spacing: 6) {
                            Text(L10n.text("settings.ai.status.lastIndex"))
                            Spacer(minLength: 12)
                            Text(lastIndex).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }

            // 0.4.5 #89:后台发现与 opt-in 白名单文件预索引(AI 主开关开启时才显示)。
            if aiAssistant {
                AIBackgroundDiscoverySection()
            }

            // 隐私说明:AI 全部在本机运行,涉密内容绝不进入。一行摘要常显,完整「AI 隐私须知」折叠展开。
            Section(L10n.text("settings.ai.privacy.section")) {
                Label(L10n.text("settings.ai.privacy.note"), systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(L10n.text("settings.ai.privacy.disclosure.title")) {
                    VStack(alignment: .leading, spacing: 10) {
                        privacyPoint(L10n.text("settings.ai.privacy.point.data"))
                        privacyPoint(L10n.text("settings.ai.privacy.point.never"))
                        privacyPoint(L10n.text("settings.ai.privacy.point.use"))
                        privacyPoint(L10n.text("settings.ai.privacy.point.model"))
                        privacyPoint(L10n.text("settings.ai.privacy.point.flow"))
                        privacyPoint(L10n.text("settings.ai.privacy.point.promise"))
                        privacyPoint(L10n.text("settings.ai.privacy.point.guarantee"))
                    }
                    .padding(.top, 6)
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .settingsScrollAnchors()
        // 配置同步是默认行为(不靠手动):进页先持久化一次,AI 主/子开关一变就推给 agent(持久化文件 + best-effort 推送)。
        .onAppear {
            AIAgentClient.persistConfiguration()
            if aiAssistant { probeBackend() }   // 进页自动探一次后端健康(开了 AI 才探)
        }
        .onChange(of: aiAssistant) { on in
            AIAgentClient.publishConfiguration()
            if on { probeBackend() }             // 刚开 AI → 探一次
        }
        .onChange(of: aiSuggestion) { _ in AIAgentClient.publishConfiguration() }
    }

    // MARK: - 运行状态:探测 + 展示

    /// 探一次前台 XPC Service 后端健康。先看本机模型可用性(同步),可用再连 XPC 探针(走 AIAgentClient 的冷启动重试);
    /// SUCCESS → 连通,否则 → 连不上(已重试)。结果回主线程更新状态行。
    private func probeBackend() {
        guard AIReportAssistant.isReady else { backendStatus = .modelUnavailable; return }
        backendStatus = .checking
        AIAgentClient.runForegroundProbe { result in
            backendStatus = result.contains("SUCCESS") ? .healthy : .unreachable
        }
    }

    private var statusSystemImage: String {
        switch backendStatus {
        case .checking:          return "ellipsis.circle"
        case .healthy:           return "checkmark.circle.fill"
        case .modelUnavailable:  return "exclamationmark.triangle.fill"
        case .unreachable:       return "xmark.octagon.fill"
        }
    }
    private var statusTint: Color {
        switch backendStatus {
        case .checking:          return .secondary
        case .healthy:           return .green
        case .modelUnavailable:  return .orange
        case .unreachable:       return .red
        }
    }
    private var statusTitle: String {
        switch backendStatus {
        case .checking:          return L10n.text("settings.ai.status.checking")
        case .healthy:           return L10n.text("settings.ai.status.healthy")
        case .modelUnavailable:  return L10n.text("settings.ai.status.modelUnavailable")
        case .unreachable:       return L10n.text("settings.ai.status.unreachable")
        }
    }
    private var statusDetail: String? {
        switch backendStatus {
        case .checking:          return nil
        case .healthy:           return nil
        case .modelUnavailable:  return AIReportAssistant.unavailableReason
        case .unreachable:       return L10n.text("settings.ai.status.unreachable.hint")
        }
    }

    /// 「上次后台索引」时间(agent 跑完后台索引时写的 lastIndexRun;dev 下多为「从未」,正式版更有意义)。
    /// key 与 AIAgentBackgroundIndex 约定一致(agent-only 文件,App 这里直读偏好域字符串常量)。
    private var lastBackgroundIndexText: String? {
        let epoch = UserDefaults.standard.double(forKey: "SimpleZip.ai.agent.lastIndexRun.v1")
        guard epoch > 0 else { return L10n.text("settings.ai.status.never") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: Date(timeIntervalSince1970: epoch), relativeTo: Date())
    }

    /// AI 隐私须知里的一条说明:整段灰色小字,跨多行不截断,左对齐撑满。
    private func privacyPoint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

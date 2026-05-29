//
//  HealthPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 健康检查面板：把「app 关键组件当前状态」集中展示成一个可一眼扫的列表。
///
/// 设计动机：很多用户遇到「为什么我装了 RAR 还是没法压 RAR」「文件关联点 .zip
/// 还是被 Archive Utility 接管了」这类问题时，没有清晰路径自检 —— 总得问别人或者翻
/// 几个 pane 反复确认。这里把所有「我有 / 没有 / 设错了 / 选错了」的状态一字排开，
/// 每条状态自带一个「跳到对应设置」按钮。
struct HealthPane: View {
    /// 把跨 pane 跳转的能力 binding 给父 SettingsView —— 这里改这个 binding 就能直接切 pane。
    @Binding var selectedPane: SettingsPane

    @State private var items: [HealthCheckItem] = []
    @State private var isChecking = false
    /// 上次刷新完成的时间，用来显示「最近一次检查于 xx 之前」之类的提示。
    @State private var lastRefreshedAt: Date?

    var body: some View {
        Form {
            Section(L10n.text("settings.section.health")) {
                Text(L10n.text("health.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isChecking && items.isEmpty {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("health.checking"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(items) { item in
                        HealthCheckRow(item: item)
                    }
                }

                HStack {
                    if let lastRefreshedAt {
                        Text(L10n.format("health.lastChecked", relativeTimeString(from: lastRefreshedAt)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.text("health.recheck"), action: refresh)
                        .disabled(isChecking)
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .onAppear {
            if items.isEmpty {
                refresh()
            }
        }
    }

    /// 重新跑所有检查。Task 包裹是因为 HealthChecker.gather 是 async（取后端版本要 spawn 子进程）。
    private func refresh() {
        Task {
            isChecking = true
            let collected = await HealthChecker.gather { pane in
                selectedPane = pane
            }
            items = collected
            lastRefreshedAt = Date()
            isChecking = false
        }
    }

    /// 用 RelativeDateTimeFormatter 把「3 秒前 / 1 分钟前」之类的相对时间渲染出来。
    /// 不缓存 formatter 是因为这一行只在刷新完成时渲染一次，不在热路径上。
    private func relativeTimeString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// 列表里单条状态行。
///
/// 行布局：状态图标 + 标题 / 细节 + 右侧可选「修复」按钮。
/// 行高跟其它 SettingsControlRow 对齐，整个 pane 的密度一致。
private struct HealthCheckRow: View {
    let item: HealthCheckItem

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.status.iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(item.status.tintColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.callout)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            if let action = item.action {
                Button(action.title) {
                    action.perform()
                }
            }
        }
        .padding(.vertical, 3)
    }
}

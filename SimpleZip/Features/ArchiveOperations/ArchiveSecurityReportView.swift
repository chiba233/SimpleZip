//
//  ArchiveSecurityReportView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  0.4.2 #7：归档路径安全报告 sheet。打开归档后台分析（Core ArchiveSecurityReport）出
//  可疑条目时，列表上方出橙色横幅 →「查看报告」弹本视图。**只告知**：解压 / 打开时的
//  既有安全确认（路径逃逸 / 符号链接 / 可执行内容）不受此报告影响、照常拦截。
//

import SwiftUI

struct ArchiveSecurityReportView: View {
    @ObservedObject var model: ArchiveBrowserModel

    /// 每类最多列这么多条目，其余折成「+N 项」—— 报告要能一眼扫完，不是堆日志。
    private static let maxPathsPerFinding = 12

    private var archiveName: String {
        if case .archive(let url) = model.mode { return url.lastPathComponent }
        return ""
    }

    /// 干净包也能看报告（菜单项随归档打开常亮）：有发现 = 橙色警示态,没发现 = 绿色全清态。
    private var hasFindings: Bool {
        !model.archiveSecurityFindings.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: hasFindings ? "exclamationmark.shield.fill" : "checkmark.shield.fill",
                colors: hasFindings ? [.orange, .red] : [.green, .mint],
                title: L10n.text("security.report.title"),
                subtitle: archiveName
            )

            HeightCappedScrollView(maxHeight: 620) {
                VStack(alignment: .leading, spacing: 12) {
                    if hasFindings {
                        Text(L10n.text("security.report.note"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(model.archiveSecurityFindings) { finding in
                            findingSection(finding)
                        }
                    } else {
                        allClearSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            PinnedBottomBar {
                Spacer()
                Button {
                    model.showsArchiveSecurityReport = false
                } label: {
                    Label(L10n.text("button.ok"), systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 560)
    }

    private var allClearSection: some View {
        DialogSection {
            VStack(alignment: .leading, spacing: 6) {
                Label(L10n.text("security.report.clean"), systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Text(L10n.text("security.report.clean.desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func findingSection(_ finding: ArchiveSecurityFinding) -> some View {
        DialogSection {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(
                        L10n.text("security.kind.\(finding.kind.rawValue)"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                    Spacer()
                    Text("\(finding.entryPaths.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(L10n.text("security.kind.\(finding.kind.rawValue).desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(finding.entryPaths.prefix(Self.maxPathsPerFinding), id: \.self) { path in
                        Text(path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(path)
                    }
                    if finding.entryPaths.count > Self.maxPathsPerFinding {
                        Text(L10n.format("security.report.more", "\(finding.entryPaths.count - Self.maxPathsPerFinding)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

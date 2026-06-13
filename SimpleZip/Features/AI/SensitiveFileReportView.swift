//
//  SensitiveFileReportView.swift
//  SimpleZip
//
//  0.4.4 #68:归档里的「敏感 / 配置 / 脚本 / 许可证」文件报告。确定性扫描(SensitiveFileScan,按文件名归类),
//  AI 只在结果上**解释**(它擅长的事,不让它扫列表)。AI 入口仅 `AIReportAssistant.isReady` 时出现。
//

import AppKit
import SwiftUI

/// 报告载体(挂 model 驱动 sheet)。
struct SensitiveFileReport: Identifiable {
    let id = UUID()
    let archiveName: String
    let result: SensitiveFileScanResult
}

struct SensitiveFileReportView: View {
    let report: SensitiveFileReport
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "doc.text.magnifyingglass",
                colors: [.orange, .pink],
                title: L10n.text("sensitive.title"),
                subtitle: report.archiveName
            )
            HeightCappedScrollView(maxHeight: 560) {
                VStack(alignment: .leading, spacing: 12) {
                    if report.result.isEmpty {
                        Label(L10n.text("sensitive.empty"), systemImage: "checkmark.seal")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    } else {
                        ForEach(report.result.groups) { group in
                            DialogSection(L10n.text("sensitive.category.\(group.category.rawValue)")) {
                                ForEach(group.paths.prefix(40), id: \.self) { path in
                                    HStack(spacing: 8) {
                                        Image(systemName: icon(for: group.category))
                                            .foregroundStyle(tint(for: group.category))
                                            .frame(width: 16)
                                        Text(path)
                                            .font(.caption.monospaced())
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .textSelection(.enabled)
                                        Spacer(minLength: 0)
                                    }
                                }
                                if group.paths.count > 40 {
                                    Text(L10n.format("security.report.more", "\(group.paths.count - 40)"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text(L10n.format("sensitive.scanned", "\(report.result.scannedFileCount)"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(L10n.text("sensitive.disclaimer"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            Divider()
            PinnedBottomBar {
                // AI 在确定性结果上解释「这些是什么、机密类要注意什么」。仅 isReady 时出现,有命中才有意义。
                if !report.result.isEmpty {
                    AIAssistButton(
                        label: L10n.text("ai.explainSensitive"),
                        systemImage: "sparkles",
                        sheetTitle: L10n.text("ai.explainSensitive.title"),
                        sheetSubtitle: report.archiveName
                    ) {
                        guard #available(macOS 26.0, *) else { throw AIAssistError(message: L10n.text("ai.unavailable.osTooOld")) }
                        let built = AIReportAssistant.sensitiveFilesExplanationPrompt(for: report)
                        return try await AIReportAssistant.generate(instructions: built.instructions, prompt: built.prompt)
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Label(L10n.text("button.ok"), systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 620)
    }

    private func icon(for category: SensitiveFileCategory) -> String {
        switch category {
        case .secretsKeys: return "key.fill"
        case .license: return "checkmark.seal.fill"
        case .config: return "gearshape.fill"
        case .scripts: return "terminal.fill"
        }
    }

    private func tint(for category: SensitiveFileCategory) -> Color {
        switch category {
        case .secretsKeys: return .red
        case .license: return .green
        case .config: return .blue
        case .scripts: return .purple
        }
    }
}

extension ArchiveBrowserModel {
    /// #68:扫当前打开归档的条目,按敏感/配置/脚本/许可证归类 → 弹报告(确定性扫描;AI 仅在报告里解释)。
    func presentSensitiveFileReport() {
        guard case .archive(let url) = mode else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }
        // 显式排除加密条目:其名字绝不进 AI prompt(红线),且已加密 = 已受保护,不必再标为「敏感」。
        let result = SensitiveFileScan.scan(session.allItems.filter { !$0.isEncrypted }.map { $0.name })
        sensitiveFileReport = SensitiveFileReport(
            archiveName: (archiveDisplayOverride ?? url).lastPathComponent,
            result: result
        )
    }
}

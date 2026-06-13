//
//  NearDuplicateReportView.swift
//  SimpleZip
//
//  0.4.4 #69:近似重复文件报告。确定性扫描(ArchiveNearDuplicates,按归一化文件名分组),AI 只在结果上**解释**。
//

import AppKit
import SwiftUI

struct NearDuplicateReport: Identifiable {
    let id = UUID()
    let archiveName: String
    let result: NearDuplicateResult
}

struct NearDuplicateReportView: View {
    let report: NearDuplicateReport
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "doc.on.doc",
                colors: [.teal, .blue],
                title: L10n.text("nearDup.title"),
                subtitle: report.archiveName
            )
            HeightCappedScrollView(maxHeight: 560) {
                VStack(alignment: .leading, spacing: 12) {
                    if report.result.isEmpty {
                        Label(L10n.text("nearDup.empty"), systemImage: "checkmark.seal")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    } else {
                        ForEach(report.result.groups) { group in
                            DialogSection {
                                HStack(spacing: 6) {
                                    Text(group.displayName)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Label(
                                        L10n.text(group.hasByteIdentical ? "nearDup.group.identical" : "nearDup.group.versions"),
                                        systemImage: group.hasByteIdentical ? "equal.circle.fill" : "arrow.triangle.branch"
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(group.hasByteIdentical ? Color.orange : Color.secondary)
                                    .labelStyle(.titleAndIcon)
                                }
                                ForEach(group.entries, id: \.path) { entry in
                                    HStack(spacing: 8) {
                                        Image(systemName: "doc")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 14)
                                        Text(entry.path)
                                            .font(.caption.monospaced())
                                            .lineLimit(1).truncationMode(.middle)
                                            .textSelection(.enabled)
                                        Spacer(minLength: 8)
                                        Text(entry.sizeText)
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                    Text(L10n.format("nearDup.scanned", "\(report.result.scannedFileCount)"))
                        .font(.caption2).foregroundStyle(.tertiary)
                    Text(L10n.text("nearDup.disclaimer"))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            Divider()
            PinnedBottomBar {
                if !report.result.isEmpty {
                    AIAssistButton(
                        label: L10n.text("ai.explainNearDup"),
                        systemImage: "sparkles",
                        sheetTitle: L10n.text("ai.explainNearDup.title"),
                        sheetSubtitle: report.archiveName
                    ) {
                        guard #available(macOS 26.0, *) else { throw AIAssistError(message: L10n.text("ai.unavailable.osTooOld")) }
                        let built = AIReportAssistant.nearDuplicateExplanationPrompt(for: report)
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
}

extension ArchiveBrowserModel {
    /// #69:扫当前打开归档,按归一化文件名找近似重复(版本/改名/副本)→ 弹报告(确定性;AI 仅解释)。
    func presentNearDuplicateReport() {
        guard case .archive(let url) = mode else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }
        let result = ArchiveNearDuplicates.find(session.allItems)
        nearDuplicateReport = NearDuplicateReport(
            archiveName: (archiveDisplayOverride ?? url).lastPathComponent,
            result: result
        )
    }
}

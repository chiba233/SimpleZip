//
//  ReproducibilityReportView.swift
//  SimpleZip
//
//  0.4.4 #43:可复现构建深度报告。顶部给「双打包是否逐字节相同」的硬结论,下面如实列因素;
//  纯展示(只读报告),不改任何文件。
//

import SwiftUI

struct ReproducibilityReportView: View {
    let report: ReproducibilityReport
    let onClose: () -> Void

    private var isReproducible: Bool { report.identical == true }

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: isReproducible ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                colors: isReproducible ? [.green, .teal] : [.orange, .red],
                title: L10n.text("repro.title"),
                subtitle: L10n.text(isReproducible ? "repro.identical" : "repro.notIdentical")
            )

            HeightCappedScrollView(maxHeight: 560) {
                VStack(alignment: .leading, spacing: 12) {
                    // 双打包实证:两份产物的 SHA-256。
                    DialogSection {
                        VStack(alignment: .leading, spacing: 6) {
                            hashRow(L10n.text("repro.hashFirst"), report.firstSHA256)
                            hashRow(L10n.text("repro.hashSecond"), report.secondSHA256)
                        }
                    }

                    Text(L10n.text("repro.factors.section"))
                        .font(.subheadline.weight(.semibold))

                    DialogSection {
                        ForEach(report.factors) { result in
                            HStack {
                                Text(L10n.text("repro.factor.\(result.factor.rawValue)"))
                                Spacer(minLength: 12)
                                Text(L10n.text("repro.status.\(result.status.rawValue)"))
                                    .font(.callout)
                                    .foregroundStyle(statusColor(result.status))
                            }
                            .padding(.vertical, 1)
                        }
                    }

                    if !isReproducible, !report.nonReproducibleFactors.isEmpty {
                        Text(L10n.format(
                            "repro.nonReproducible.note",
                            report.nonReproducibleFactors
                                .map { L10n.text("repro.factor.\($0.rawValue)") }
                                .joined(separator: ", ")
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            PinnedBottomBar {
                // #53:AI 白话解释可复现报告(两次打包是否一致 + 哪些因素可能破坏可复现)。
                AIAssistButton(
                    label: L10n.text("ai.explainRepro"),
                    systemImage: "sparkles",
                    sheetTitle: L10n.text("ai.explainRepro.title"),
                    sheetSubtitle: L10n.text(isReproducible ? "repro.identical" : "repro.notIdentical")
                ) {
                    guard #available(macOS 26.0, *) else { throw AIAssistError(message: L10n.text("ai.unavailable.osTooOld")) }
                    let built = AIReportAssistant.reproducibilityExplanationPrompt(for: report)
                    return try await AIReportAssistant.generate(instructions: built.instructions, prompt: built.prompt)
                }
                Spacer()
                Button(action: onClose) {
                    Label(L10n.text("button.ok"), systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 560)
    }

    private func hashRow(_ label: String, _ hash: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(hash ?? "—")
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusColor(_ status: ReproducibilityReport.FactorStatus) -> Color {
        switch status {
        case .normalized, .stripped: return .green
        case .storedAsIs: return .orange
        case .notApplicable: return .gray
        }
    }
}

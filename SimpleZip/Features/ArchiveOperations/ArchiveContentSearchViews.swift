//
//  ArchiveContentSearchViews.swift
//  SimpleZip
//
//  队列 #11:归档内容搜索的两张 sheet —— 搜索词输入(主动触发)与结果报告。
//  匹配引擎在 Core(ArchiveContentSearch,已单测),解包与临时区在模型
//  (ArchiveBrowserModel.runContentSearch:解到临时目录、搜完即删)。
//

import AppKit
import SwiftUI

/// 搜索词输入 sheet:一个搜索词 + 单文件大小上限,范围说明写明砍掉了什么。
struct ContentSearchPromptView: View {
    @State var request: ArchiveBrowserModel.ContentSearchRequest
    let confirm: (ArchiveBrowserModel.ContentSearchRequest) -> Void
    let cancel: () -> Void

    private static let sizeOptions: [Int64] = [500_000, 2_000_000, 8_000_000]

    var body: some View {
        TaskDialogShell(
            heroSystemImage: "text.magnifyingglass",
            heroColors: [.indigo, .purple],
            title: L10n.text("contentSearch.title"),
            subtitle: request.archiveURL.lastPathComponent,
            width: 460,
            confirmTitle: L10n.text("contentSearch.start"),
            confirmSystemImage: "magnifyingglass",
            confirmDisabled: request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            confirm: { confirm(request) },
            cancel: cancel
        ) {
            DialogSection {
                HStack(alignment: .center, spacing: 12) {
                    DialogRowLabel(L10n.text("contentSearch.query.label"), systemImage: "magnifyingglass", tint: .indigo)
                    Spacer(minLength: 12)
                    TextField(L10n.text("contentSearch.query.label"), text: $request.query)
                        .textFieldStyle(.roundedBorder)
                        .dialogFieldEmphasis()
                        .frame(maxWidth: 260)
                        .onSubmit {
                            if !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                confirm(request)
                            }
                        }
                }
                HStack(alignment: .center, spacing: 12) {
                    DialogRowLabel(L10n.text("contentSearch.maxSize.label"), systemImage: "scalemass", tint: .gray)
                    Spacer(minLength: 12)
                    Picker("", selection: $request.maxBytes) {
                        ForEach(Self.sizeOptions, id: \.self) { bytes in
                            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).tag(bytes)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            // 长说明放卡片外当脚注(布局准则):写清楚范围 —— 只文本、不二进制、不 PDF、临时区即用即删。
            Text(L10n.text("contentSearch.scope.note"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 14)
        }
    }
}

/// 结果报告 sheet:按文件分卡,每条命中 = 行号 + 行预览;整份可复制。
struct ContentSearchResultsView: View {
    let report: ArchiveBrowserModel.ContentSearchReport
    let onClose: () -> Void

    private var matchesByFile: [(path: String, matches: [ArchiveContentSearch.Match])] {
        var order: [String] = []
        var grouped: [String: [ArchiveContentSearch.Match]] = [:]
        for match in report.matches {
            if grouped[match.entryPath] == nil { order.append(match.entryPath) }
            grouped[match.entryPath, default: []].append(match)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "text.magnifyingglass",
                colors: [.indigo, .purple],
                title: L10n.text("contentSearch.results.title"),
                subtitle: report.archiveName
            )

            HeightCappedScrollView(maxHeight: 480) {
                VStack(alignment: .leading, spacing: 12) {
                    if report.candidateCount == 0 {
                        Label(L10n.text("contentSearch.noCandidates"), systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if report.matches.isEmpty {
                        Label(
                            L10n.format("contentSearch.results.none", report.query, "\(report.candidateCount)"),
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L10n.format(
                            "contentSearch.results.summary",
                            report.query, "\(report.candidateCount)", "\(report.matches.count)"
                        ))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        ForEach(matchesByFile, id: \.path) { group in
                            DialogSection {
                                Text(group.path)
                                    .font(.subheadline.weight(.semibold))
                                    .textSelection(.enabled)
                                ForEach(group.matches) { match in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(L10n.format("contentSearch.line", "\(match.lineNumber)"))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .frame(width: 76, alignment: .trailing)
                                        Text(match.lineText)
                                            .font(.caption.monospaced())
                                            .lineLimit(2)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            PinnedBottomBar {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plainTextSummary, forType: .string)
                } label: {
                    Label(L10n.text("button.copyAll"), systemImage: "doc.on.doc")
                }
                Spacer()
                Button {
                    onClose()
                } label: {
                    Label(L10n.text("button.ok"), systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 560)
    }

    private var plainTextSummary: String {
        var lines = ["\(L10n.text("contentSearch.results.title")): \(report.archiveName)"]
        if report.matches.isEmpty {
            lines.append(L10n.format("contentSearch.results.none", report.query, "\(report.candidateCount)"))
        } else {
            lines.append(L10n.format(
                "contentSearch.results.summary",
                report.query, "\(report.candidateCount)", "\(report.matches.count)"
            ))
            for group in matchesByFile {
                lines.append("")
                lines.append("— \(group.path)")
                for match in group.matches {
                    lines.append("  \(match.lineNumber): \(match.lineText)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

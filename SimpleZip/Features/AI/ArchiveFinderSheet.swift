//
//  ArchiveFinderSheet.swift
//  SimpleZip
//
//  0.4.4 #63 · macOS 26 AI:「文件X在哪个包」—— 一句话 → AI 抽出文件名关键词 → 在**已打开归档的清单缓存**里
//  确定性搜索 → 列出含该文件的归档,点一下就打开。
//
//  **红线**:AI 只把口语抽成一个关键词(只读),真正的匹配走确定性的 `ArchiveListingCacheStore.search`;
//  只搜**非加密**清单条目名(头加密归档根本列不出名字,自然不会进缓存)。仅 `AIReportAssistant.isReady` 时可用。
//

import AppKit
import SwiftUI

/// 菜单触发的只读 marker(数据在 sheet 里现查缓存)。
struct ArchiveFinderRequest: Identifiable {
    let id = UUID()
}

struct ArchiveFinderSheet: View {
    let onClose: () -> Void

    @State private var query = ""
    @State private var keyword = ""            // 当前搜索词(= 用户输入,用于结果标题回显)
    @State private var groups: [ResultGroup] = []
    @State private var searched = false
    @State private var error: String?

    /// 按归档分组的命中(一个归档一行,附命中的条目名)。
    struct ResultGroup: Identifiable {
        let id: String                 // archivePath
        let archivePath: String
        let archiveName: String
        let entries: [String]
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "magnifyingglass.circle",
                colors: [.blue, .teal],
                title: L10n.text("finder.title"),
                subtitle: L10n.text("finder.subtitle")
            )
            Divider()
            content
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            PinnedBottomBar {
                Spacer()
                Button { onClose() } label: {
                    Label(L10n.text("button.close"), systemImage: "xmark")
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 560)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.text("finder.prompt"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { run() }
                Button(L10n.text("finder.search")) { run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if searched {
                if groups.isEmpty {
                    Label(L10n.format("finder.noResults", keyword), systemImage: "magnifyingglass")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L10n.format("finder.resultsHeader", keyword, "\(groups.count)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HeightCappedScrollView(maxHeight: 320) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(groups) { group in resultRow(group) }
                        }
                        // 给滚动条留出「水槽」—— 否则覆盖式滚动条压住结果行右缘的「打开」箭头。
                        .padding(.trailing, 14)
                    }
                }
            } else {
                Text(L10n.text("finder.hint"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func resultRow(_ group: ResultGroup) -> some View {
        Button {
            let url = URL(fileURLWithPath: group.archivePath)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            AppDelegate.openExternalArchive(url)
            onClose()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.archiveName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text(group.entries.prefix(5).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
        .buttonStyle(.plain)
        .help(group.archivePath)
    }

    @MainActor
    private func run() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        error = nil
        keyword = q
        // 确定性子串搜索(大小写不敏感):直接拿用户输入搜已打开归档的非加密清单缓存,按归档分组。不经 AI。
        let hits = ArchiveListingCacheStore().search(q, limit: 200)
        var entriesByPath: [String: [String]] = [:]
        var nameByPath: [String: String] = [:]
        var order: [String] = []
        for hit in hits {
            if entriesByPath[hit.archivePath] == nil {
                order.append(hit.archivePath)
                nameByPath[hit.archivePath] = hit.archiveName
            }
            if !(entriesByPath[hit.archivePath]?.contains(hit.entryName) ?? false) {
                entriesByPath[hit.archivePath, default: []].append(hit.entryName)
            }
        }
        groups = order.map {
            ResultGroup(id: $0, archivePath: $0,
                        archiveName: nameByPath[$0] ?? URL(fileURLWithPath: $0).lastPathComponent,
                        entries: entriesByPath[$0] ?? [])
        }
        searched = true
    }
}

extension ArchiveBrowserModel {
    /// #63:菜单触发「文件X在哪个包」sheet(仅 marker,数据在 sheet 里现查缓存)。
    func presentArchiveFinder() {
        archiveFinderRequest = ArchiveFinderRequest()
    }
}

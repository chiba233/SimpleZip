//
//  HashResultsView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import SwiftUI

/// 哈希结果弹窗，提供完整结果查看和复制。
struct HashResultsView: View {
    let report: HashReport
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("hash.title"))
                        .font(.title2.weight(.semibold))
                    Text(L10n.format("hash.summary", report.fileCount, ByteCountFormatter.string(fromByteCount: report.totalSize, countStyle: .file)))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(L10n.text("button.copyAll")) {
                    copyAllResults()
                }

                Button(L10n.text("button.ok")) {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(report.results) { result in
                        HashResultCard(result: result)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 340)
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 900, minHeight: 460, idealHeight: 620)
    }

    private func copyAllResults() {
        let text = report.results.map { result in
            """
            \(result.url.path)
            CRC32: \(result.crc32)
            MD5: \(result.md5)
            SHA1: \(result.sha1)
            SHA256: \(result.sha256)
            SHA512: \(result.sha512)
            """
        }.joined(separator: "\n\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct HashResultCard: View {
    let result: FileHashResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(result.displayName, systemImage: "doc")
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Text(ByteCountFormatter.string(fromByteCount: result.size, countStyle: .file))
                    .foregroundStyle(.secondary)
            }

            Text(result.url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                HashRow(name: "CRC32", value: result.crc32)
                HashRow(name: "MD5", value: result.md5)
                HashRow(name: "SHA1", value: result.sha1)
                HashRow(name: "SHA256", value: result.sha256)
                HashRow(name: "SHA512", value: result.sha512)
            }
            .textSelection(.enabled)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor))
        )
    }
}

private struct HashRow: View {
    let name: String
    let value: String

    var body: some View {
        GridRow {
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Text(value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
        }
    }
}

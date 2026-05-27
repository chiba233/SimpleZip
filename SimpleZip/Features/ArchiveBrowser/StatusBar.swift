//
//  StatusBar.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 底部状态栏：显示当前项目数量、任务状态和后端能力提示。
struct StatusBar: View {
    @ObservedObject var model: ArchiveBrowserModel

    var body: some View {
        HStack {
            if model.isWorking {
                HStack(spacing: 8) {
                    if let fraction = model.operationProgress.fraction {
                        ProgressView(value: fraction)
                            .frame(width: 140, alignment: .leading)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        if let progressCountText {
                            Text(progressCountText)
                                .foregroundStyle(.secondary)
                        }
                        Text(progressPrimaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if model.operationDetailsSession != nil {
                    detailsButton
                }
                if model.canCancelCurrentOperation {
                    Button(L10n.text("button.cancel")) {
                        model.cancelCurrentOperation()
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Text(model.status)
                    .lineLimit(1)
                if model.operationDetailsSession != nil {
                    detailsButton
                }
            }
            Spacer()
            Text(L10n.text("status.backend"))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var detailsButton: some View {
        Button(L10n.text("button.details")) {
            model.showOperationDetails()
        }
        .buttonStyle(.borderless)
    }

    private var progressCountText: String? {
        guard let completed = model.operationProgress.completedUnitCount,
              let total = model.operationProgress.totalUnitCount,
              total > 0 else {
            return nil
        }
        return "\(min(completed, total))/\(total)"
    }

    private var progressPrimaryText: String {
        if let currentFile = model.operationProgress.currentFile, !currentFile.isEmpty {
            return currentFile
        }
        if let statusText = model.operationProgress.statusText, !statusText.isEmpty {
            return statusText
        }
        return model.status
    }
}

struct ArchiveOperationDetailsView: View {
    @ObservedObject var session: ArchiveOperationDetailsSession
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.title2.weight(.semibold))
                    if session.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Spacer()
                Button(L10n.text("button.ok")) {
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }

            Text(L10n.text("details.commandOutput"))
                .font(.headline)

            ScrollView([.horizontal, .vertical]) {
                Text(session.rawOutput.isEmpty ? L10n.text("details.waiting") : session.rawOutput)
                    .font(.system(.caption, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor))
            )
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 500, idealHeight: 620)
    }
}

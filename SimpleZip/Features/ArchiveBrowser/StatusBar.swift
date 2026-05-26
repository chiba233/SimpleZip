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
                if let fraction = model.operationProgress.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 140, alignment: .leading)
                } else {
                    ProgressView()
                        .controlSize(.small)
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

            ScrollView {
                Text(session.rawOutput.isEmpty ? L10n.text("details.waiting") : session.rawOutput)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
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

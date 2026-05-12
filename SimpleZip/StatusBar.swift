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
                Group {
                    if let fraction = model.operationProgress.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: 140, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.status)
                        .lineLimit(1)
                    if let currentFile = model.operationProgress.currentFile, !currentFile.isEmpty {
                        Text(L10n.format("status.currentFile", currentFile))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }
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
}

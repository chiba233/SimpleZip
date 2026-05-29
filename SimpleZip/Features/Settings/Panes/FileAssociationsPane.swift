//
//  FileAssociationsPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 文件关联面板：列出支持的扩展名，让用户把 SimpleZip 设为默认应用。
///
/// 默认应用状态保存在 LaunchServices，不在 UserDefaults，
/// 所以 onAppear 时主动 `refresh()` 一次，setDefault 之后也要刷一次。
struct FileAssociationsPane: View {
    @State private var defaultAppMessage: String?
    @State private var associationStatus: [String: String] = [:]

    var body: some View {
        Form {
            Section(L10n.text("settings.section.fileAssociations")) {
                Text(L10n.text("settings.association.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(ArchiveAssociationService.supportedAssociations) { association in
                        FileAssociationRow(
                            association: association,
                            currentDefaultApp: associationStatus[association.id] ?? L10n.text("settings.association.loading"),
                            isSimpleZipDefault: ArchiveAssociationService.isSimpleZipDefault(for: association)
                        ) {
                            setDefaultArchiveApp(for: association)
                        }

                        if association.id != ArchiveAssociationService.supportedAssociations.last?.id {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }

                if let defaultAppMessage {
                    Text(defaultAppMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .onAppear(perform: refresh)
    }

    private func setDefaultArchiveApp(for association: ArchiveAssociation) {
        do {
            try ArchiveAssociationService.setAsDefault(for: association)
            defaultAppMessage = L10n.format("settings.defaultArchiveTypeDone", ".\(association.fileExtension)")
            refresh()
        } catch {
            defaultAppMessage = error.localizedDescription
        }
    }

    private func refresh() {
        associationStatus = Dictionary(uniqueKeysWithValues: ArchiveAssociationService.supportedAssociations.map { association in
            (association.id, ArchiveAssociationService.currentDefaultAppName(for: association))
        })
    }
}

/// 单个扩展名的关联行。
///
/// 左侧固定 48pt 宽显示后缀名（让多行后缀对齐），右侧根据「是否已是 SimpleZip 默认」
/// 切换显示绿色勾或者「设为默认」按钮。
struct FileAssociationRow: View {
    let association: ArchiveAssociation
    let currentDefaultApp: String
    let isSimpleZipDefault: Bool
    let setDefault: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(".\(association.fileExtension)")
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
                .frame(width: 48, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(association.title)
                Text(L10n.format("settings.association.currentDefault", currentDefaultApp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isSimpleZipDefault {
                Label(L10n.text("settings.association.simpleZipDefault"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button(L10n.text("settings.association.setDefault")) {
                    setDefault()
                }
            }
        }
        .padding(.vertical, 8)
        .controlSize(.small)
    }
}

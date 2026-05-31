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
    /// 上次「设为默认」成功针对的扩展名 id —— 用来在该类型不再是 SimpleZip 默认时撤掉那条
    /// 「已设为默认」提示，避免用户在别处取消关联后这里仍挂着「关联成功」。
    @State private var lastSucceededID: String?

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
        .onAppear {
            // 每次进入面板都先清掉上次的成功提示 —— 它是「刚刚点击」的瞬时反馈，
            // 重新打开面板（或在别处改过默认 App 后回来）不该再挂着「关联成功」。
            defaultAppMessage = nil
            lastSucceededID = nil
            refresh()
        }
    }

    private func setDefaultArchiveApp(for association: ArchiveAssociation) {
        do {
            try ArchiveAssociationService.setAsDefault(for: association)
            defaultAppMessage = L10n.format("settings.defaultArchiveTypeDone", ".\(association.fileExtension)")
            lastSucceededID = association.id
            refresh()
            // LaunchServices 的 `LSSetDefaultRoleHandlerForContentType` 同步成功，
            // 但同进程内 `LSCopyDefaultRoleHandlerForContentType` 短时间会读到旧缓存
            // —— 立即 refresh 看到的还是「未设为默认」，给用户「明明点了为什么没生效」的疑惑。
            // 多个时间点 retry 让 LS settle 后 UI 自动跟上，不需要用户切走 pane 再切回来。
            // 时间点根据实测：第一次 ~300ms 大概率已经更新；1.5s 是兜底（系统负载高时 LS 慢）。
            for delay in [0.3, 0.8, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    refresh()
                }
            }
        } catch {
            defaultAppMessage = error.localizedDescription
        }
    }

    private func refresh() {
        associationStatus = Dictionary(uniqueKeysWithValues: ArchiveAssociationService.supportedAssociations.map { association in
            (association.id, ArchiveAssociationService.currentDefaultAppName(for: association))
        })
        // 若「上次设默认成功」的那个类型现在已不再是 SimpleZip 默认（用户在别处取消了关联），
        // 撤掉那条成功提示，免得它误导成「还关联着」。
        if let id = lastSucceededID,
           let association = ArchiveAssociationService.supportedAssociations.first(where: { $0.id == id }),
           !ArchiveAssociationService.isSimpleZipDefault(for: association) {
            defaultAppMessage = nil
            lastSucceededID = nil
        }
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

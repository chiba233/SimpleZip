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
    /// 上次「全部设为默认」尝试过的一组扩展名 id —— `.dmg/.pkg` 这类受保护类型 `setAsDefault`
    /// 会异步弹系统确认框,用户拒绝则默认不变。底部提示必须按**实际生效数**算(在 refresh 里复核),
    /// 否则会误报「已设 N 个」。空 = 没有待复核的分组操作。
    @State private var pendingGroupIDs: [String] = []

    var body: some View {
        Form {
            // #81:描述已抬到 hero 副标题,删掉重复的小节头 + 描述。
            Section {
                // 0.4.3 用户拍板:按类别分组排布,同类同色(压缩包蓝 / 磁盘镜像紫 / SimpleZip 专属绿 / 分卷橙)。
                associationGroup(
                    titleKey: "settings.association.group.archives",
                    systemImage: "doc.zipper",
                    tint: .blue,
                    category: .archive
                )
                .settingsAnchor("fileAssociations")
                // 0.4.4:磁盘镜像与安装包从压缩包拆出(dmg/iso 是镜像、xip/pkg 是 Apple 安装包,均非压缩)。
                associationGroup(
                    titleKey: "settings.association.group.diskImages",
                    systemImage: "opticaldiscdrive",
                    tint: .purple,
                    category: .diskImage
                )
                associationGroup(
                    titleKey: "settings.association.group.simplezip",
                    systemImage: "checkmark.seal",
                    tint: .green,
                    category: .simpleZip
                )
                associationGroup(
                    titleKey: "settings.association.group.volumes",
                    systemImage: "square.stack.3d.down.right",
                    tint: .orange,
                    category: .volume
                )

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
            pendingGroupIDs = []
            refresh()
        }
    }

    /// 一个类别的分组:瓦片小标题 + 该类格式行(行内徽章用类别色,同类同色)。
    @ViewBuilder
    private func associationGroup(
        titleKey: String,
        systemImage: String,
        tint: Color,
        category: ArchiveAssociation.Category
    ) -> some View {
        let items = ArchiveAssociationService.supportedAssociations.filter { $0.category == category }
        // 该组是否还有没设为默认的 —— 全设了就不显示「全部设为默认」按钮(无事可做)。
        let hasUnset = items.contains { !ArchiveAssociationService.isSimpleZipDefault(for: $0) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SettingsRowIcon(systemImage: systemImage, tint: tint)
                Text(L10n.text(titleKey)).font(.headline)
                Spacer(minLength: 12)
                // 0.4.4 用户点名:每组一个「全部设为默认」—— 一键把本组所有格式关联到 SimpleZip。
                if hasUnset {
                    Button {
                        setGroupDefault(for: items)
                    } label: {
                        Label(L10n.text("settings.association.setGroupDefault"), systemImage: "checkmark.circle")
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            .padding(.vertical, 6)

            ForEach(items) { association in
                FileAssociationRow(
                    association: association,
                    currentDefaultApp: associationStatus[association.id] ?? L10n.text("settings.association.loading"),
                    isSimpleZipDefault: ArchiveAssociationService.isSimpleZipDefault(for: association)
                ) {
                    setDefaultArchiveApp(for: association)
                }
                if association.id != items.last?.id {
                    Divider().padding(.leading, 48)
                }
            }
        }
    }

    /// 0.4.4:把一个分组里的所有格式一键关联到 SimpleZip。
    /// **不**按「调了几次 setAsDefault」报成功 —— `.dmg/.pkg` 等受保护类型会异步弹系统确认框,
    /// 用户拒绝则默认不变。这里只发起请求,底部提示由 `refresh()` 按**实际生效数**复核给出
    /// (用户在系统弹窗拒绝的不计入,全没生效则不显示提示)。同单个设默认的自纠正机制。
    private func setGroupDefault(for items: [ArchiveAssociation]) {
        let targets = items.filter { !ArchiveAssociationService.isSimpleZipDefault(for: $0) }
        var failure: String?
        for association in targets {
            do {
                try ArchiveAssociationService.setAsDefault(for: association)
            } catch {
                failure = error.localizedDescription
            }
        }
        lastSucceededID = nil
        if let failure {
            defaultAppMessage = failure
            pendingGroupIDs = []
            return
        }
        // 待复核的这组 —— refresh 会数实际生效的;先清空提示,有结果再显示。
        pendingGroupIDs = targets.map(\.id)
        defaultAppMessage = nil
        refresh()
        // LaunchServices 写入同步返回但读缓存有延迟、系统确认框异步,多点 retry 让实际状态 settle 后再复核。
        for delay in [0.3, 0.8, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { refresh() }
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
        // 「全部设为默认」的实际生效复核:只数这组里**现在真的是** SimpleZip 默认的(用户在系统
        // 确认框拒绝的 .dmg/.pkg 不算)。生效 >0 才显示数量提示,全没生效则不显示 —— 不再误报。
        if !pendingGroupIDs.isEmpty {
            let nowDefaultCount = pendingGroupIDs.filter { id in
                guard let association = ArchiveAssociationService.supportedAssociations.first(where: { $0.id == id }) else { return false }
                return ArchiveAssociationService.isSimpleZipDefault(for: association)
            }.count
            defaultAppMessage = nowDefaultCount > 0
                ? L10n.format("settings.association.setGroupDefaultDone", "\(nowDefaultCount)")
                : nil
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
            // 与全设置同一套瓦片制度,但「图标」就是扩展名本身:彩色底 + 文字(用户拍板),同类同色。
            Text(association.fileExtension)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .padding(.horizontal, 3)
                .frame(width: 38, height: 24)
                .background(association.category.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .saturation(0.75)

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
                Button {
                    setDefault()
                } label: {
                    Label(L10n.text("settings.association.setDefault"), systemImage: "checkmark.circle")
                }
            }
        }
        // 0.4.3 用户点名「太紧凑」:行距放宽到新间距。
        .padding(.vertical, 10)
    }
}

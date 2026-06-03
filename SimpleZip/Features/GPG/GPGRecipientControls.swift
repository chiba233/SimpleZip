//
//  GPGRecipientControls.swift
//  SimpleZip
//
//  0.3.0 去重：GPG 收件人选择 UI 此前在 5 个对话框里逐字重复（add-recipient Menu、chip 样式、
//  unknown-recipient 文案）。这里抽出**逐字一致的内核**——chip、Menu、chip 横向列表——
//  各调用方保留自己的 label / row 布局（遵循「每个对话框有自己的 row idiom」），只复用内核，零行为变更。
//
//  过滤逻辑（recipient 仅 `.userKeyring`、chip 反查用哪个集合）由调用方通过 `eligibleKeys` /
//  `lookupKeys` 显式传入 —— 不同对话框这两者并不相同（如 CreateSZSSheet 的 chip 反查用已过滤集合，
//  GPGEncryptOptionsView 用全部 keys），各自保留。
//

import SwiftUI

/// 单个收件人 chip：`userID · shortFingerprint`（在 `lookupKeys` 里查不到时显示「未知收件人 + 末 16 位」）+ × 移除。
struct GPGRecipientChip: View {
    let fingerprint: String
    /// 把 fingerprint 反查成 userID 的 key 列表（各调用方传自己原来用的集合，保留行为）。
    let lookupKeys: [GPGBackend.GPGKey]
    let onRemove: () -> Void

    var body: some View {
        let key = lookupKeys.first(where: { $0.fingerprint == fingerprint })
        HStack(spacing: 4) {
            Text(key.map { "\($0.userID) · \($0.shortFingerprint)" }
                ?? L10n.format("archive.gpgEncrypt.unknownRecipient", String(fingerprint.suffix(16))))
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(Capsule())
    }
}

/// 「添加收件人」Menu：列出候选公钥、勾选切换；空 ring 时显示提示。
/// 各对话框外层 label / 布局不同，但这个 Menu 的内容逐字一致，故只抽 Menu。
struct GPGAddRecipientMenu: View {
    /// 候选公钥（调用方已按 `.userKeyring` 过滤）。
    let eligibleKeys: [GPGBackend.GPGKey]
    @Binding var selection: [String]

    var body: some View {
        Menu {
            if eligibleKeys.isEmpty {
                Text(L10n.text("archive.gpgEncrypt.noKeysInRing"))
            } else {
                ForEach(eligibleKeys) { key in
                    Button {
                        toggle(key.fingerprint)
                    } label: {
                        HStack {
                            Image(systemName: selection.contains(key.fingerprint) ? "checkmark.circle.fill" : "circle")
                            Text("\(key.userID) · \(key.shortFingerprint)")
                        }
                    }
                }
            }
        } label: {
            Text(L10n.text("archive.gpgEncrypt.addRecipient"))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func toggle(_ fingerprint: String) {
        if let idx = selection.firstIndex(of: fingerprint) {
            selection.remove(at: idx)
        } else {
            selection.append(fingerprint)
        }
    }
}

/// 已选收件人的横向 chip 列表 —— `selection` 非空时展示。内部用 `GPGRecipientChip`。
struct GPGRecipientChipRow: View {
    @Binding var selection: [String]
    let lookupKeys: [GPGBackend.GPGKey]

    var body: some View {
        if !selection.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(selection, id: \.self) { fingerprint in
                        GPGRecipientChip(fingerprint: fingerprint, lookupKeys: lookupKeys) {
                            selection.removeAll { $0 == fingerprint }
                        }
                    }
                }
            }
        }
    }
}

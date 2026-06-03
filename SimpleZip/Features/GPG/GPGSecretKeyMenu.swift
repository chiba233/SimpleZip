//
//  GPGSecretKeyMenu.swift
//  SimpleZip
//
//  0.3.0 去重：单选「签名 / 解密私钥」Menu 此前在 4 个对话框里逐字重复
//  （创建 .siz 签名 ArchiveCreationOptionsView、创建 .szs 签名 CreateSZSSheet、
//   解压解密 ExtractArchiveOptionsView、.siz 打开解密 SIZSignatureSheet）。
//  这里抽出**逐字一致的内核**——auto 项 + Divider + 私钥列表 + 三态按钮文案——
//  各调用方保留自己的 row 外层布局（label 字号 / 对齐 / padding / Spacer 各不同，遵循
//  「每个对话框有自己的 row idiom」A1），只复用这个 Menu，零行为变更。
//
//  与 GPGRecipientControls（多选收件人公钥）对称：那个抽 add-recipient Menu，这个抽单选私钥 Menu。
//
//  差异通过参数显式传入，不另造 DTO：
//   - `secretKeys`：候选私钥，调用方已按 `hasSecretKey` 过滤（创建签名处历史上传全部 ring 再过滤，
//     等价于传过滤后集合——`secretKeys.first(where: fp)` ≡ 旧的 `availableKeys.first(where: fp && hasSecretKey)`）。
//   - `autoLabelKey` / `missingFingerprintKey`：签名走 `archive.gpgSign.*` / `szs.create.signingKey.*`，
//     解密走 `extract.gpgDecryptionKey.*`，各对话框原文案保留。
//

import SwiftUI

/// 单选私钥选择 Menu：首项「自动」对应空 fingerprint（= 让 gpg 按 default-key / keyring 自己挑），
/// 其后列出所有候选私钥（`userID · shortFingerprint`）。按钮文案三态：未选→auto；选了能反查→key 名；
/// 选了但列表里找不到→`missingFingerprintKey` + 末 16 位。
struct GPGSecretKeyMenu: View {
    /// 选中的私钥 fingerprint，空串 = 自动。
    @Binding var selection: String
    /// 候选私钥（调用方已按 `hasSecretKey` 过滤）。
    let secretKeys: [GPGBackend.GPGKey]
    /// 「自动」项文案的 L10n key（签名 / 解密各异）。
    let autoLabelKey: String
    /// 选了但反查不到时的文案 L10n key（带末 16 位指纹参数）。
    let missingFingerprintKey: String

    var body: some View {
        Menu {
            Button(L10n.text(autoLabelKey)) {
                selection = ""
            }
            if !secretKeys.isEmpty {
                Divider()
                ForEach(secretKeys) { key in
                    Button("\(key.userID) · \(key.shortFingerprint)") {
                        selection = key.fingerprint
                    }
                }
            }
        } label: {
            Text(menuLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// 按钮显示文案：未选 / 选了但找不到 / 选了能映射到列表 三种情形。
    private var menuLabel: String {
        if selection.isEmpty {
            return L10n.text(autoLabelKey)
        }
        if let matched = secretKeys.first(where: { $0.fingerprint == selection }) {
            return "\(matched.userID) · \(matched.shortFingerprint)"
        }
        // String(...) 包一层避免 Substring → CVarArg 的 printf 序列化 bug（之前掉过的坑）。
        return L10n.format(missingFingerprintKey, String(selection.suffix(16)))
    }
}

//
//  GPGBackend.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/29.
//

import Foundation

/// GnuPG CLI 后端 —— 探测 / 元信息 / 后续会承担「列出密钥 / 导入公钥 / 签名压缩包 / 验签」等动作。
///
/// 跟其它 backend (7zz / RAR / NativeZip / DMG) 的关键差别：
/// - **不**内置 gpg 二进制 —— GnuPG 是 GPL，本身不复杂，但依赖链（libgpg-error / libgcrypt / libassuan /
///   libksba / npth / pinentry-mac …）多到本地脚本编译不现实；让用户走 `brew install gnupg` 或者装
///   GPGTools 的官方签名 macOS 安装包是唯一合理选择。
/// - 私钥 / passphrase 全交给 `gpg-agent` + `pinentry-mac` —— SimpleZip 自己**不**碰 passphrase
///   （安全敏感且容易写错）。只要用户的 brew gnupg 安装包带了 pinentry-mac（默认就带）就行。
///
/// 设计动机：跟其它 backend 一样，让上层（Settings GPG pane / 创建对话框 / 验签流程）只调本 namespace 的
/// 静态方法，不用关心 gpg 路径在哪、版本怎么解析、子进程怎么跑。
///
/// **GPG 功能全可选**：`AppPreferences.gpgEnabled` 主开关关闭时，调用方应该完全跳过本 backend ——
/// 但本 backend 自己的方法仍然能正常工作（探测后端可用性等纯查询行为不依赖主开关）。
enum GPGBackend {
}

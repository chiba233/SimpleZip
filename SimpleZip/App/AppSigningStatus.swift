//
//  AppSigningStatus.swift
//  SimpleZip
//
//  0.4.5:Shortcuts / App Intents 按签名门控。
//
//  根因(linkd 日志实证):macOS 26 的 App Intents / Shortcuts 执行链要求 "validated bundle" ——
//  `linkd` 校验连接来源 app 的代码签名,拿不到 TeamIdentifier(ad-hoc `-` 签名 / 无签名)就直接
//  `Rejecting invalid client due to requiresValidatedBundle`,intent 永远跑不起来,Shortcuts 只报
//  「无法与 App 通信」。本项目 MIT 开源、ad-hoc 本地签名(无付费 Developer ID),发布产物没有 teamId,
//  所以 Shortcuts 在用户机器上必然失败。
//
//  既然修不了(签名是分发层的事、不买证书就没有 teamId),就**按签名门控**:app 内一切 Shortcuts/Siri
//  入口仅在「当前 bundle 带 TeamIdentifier(= 苹果认证签名)」时渲染 —— ad-hoc 构建整体隐藏,避免用户
//  发现一个注定失败的功能去 report;哪天有了合法签名,门自动开。
//

import Foundation
import Security

enum AppSigningStatus {
    /// 当前运行 app bundle 的代码签名是否带非空 TeamIdentifier。
    /// 运行期签名不变,算一次缓存。读不到签名信息一律按「无」处理(保守:宁可隐藏)。
    static let hasAppleTeamIdentifier: Bool = (teamIdentifier()?.isEmpty == false)

    /// Shortcuts / Siri / App Intents 在本构建是否可用(= 有 teamId,linkd 才不拒)。门控调用点用这个语义名。
    static var supportsShortcuts: Bool { hasAppleTeamIdentifier }

    /// 读自身代码签名的 TeamIdentifier;ad-hoc / 未签名 / 读取失败返回 nil。
    private static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

//
//  BrowserNavigation.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

/// 后退/前进栈里的一个落点。
///
/// 之所以用枚举而不是 URL：浏览器三种 mode（普通文件夹 / 压缩包内某路径 / Finder 标签）
/// 都要进入历史，单纯 URL 表达不了「压缩包内的位置」和「标签搜索结果」。
/// 用一个统一类型让 back/forward 栈成为齐次列表，避免每次出栈 switch case。
enum NavigationLocation: Equatable {
    case folder(URL)
    case archive(URL, String)
    case tag(String)
}

/// 已挂载的 DMG 会话。
///
/// 同时持有 `sourceURL`（用户打开的 .dmg 文件）和 `mountPoint`（hdiutil 挂载产生的卷路径），
/// 让退出 / 切换到非挂载目录时能精确卸载 —— 仅用 mountPoint 一项无法回溯是哪个 dmg。
struct MountedDiskImageSession {
    let sourceURL: URL
    let mountPoint: URL
}

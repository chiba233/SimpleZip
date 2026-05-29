//
//  ArchiveOperationFeedback.swift
//  SimpleZip
//
//  Created by Copilot on 2026/05/28.
//

import Foundation

/// 失败 alert 顶部预览的截断逻辑 —— 完整文案仍存在 ArchiveBrowserModel.errorMessage，
/// 这里只负责生成「顶部摘要」（trim + 截断到 limit + 加 `\n…` 尾），完整内容用户点「打开详情」时另外看。
///
/// 之前是 `ArchiveOperationFailureAlert` struct（fullMessage + previewLimit + previewMessage 计算属性）；
/// previewLimit 从未被设过别的值，跟 `errorMessage` getter/setter 互相把对方藏起来，是过度抽象。
/// 收成纯函数 helper，model 直接调，单测仍覆盖这两条断言。
enum ArchiveOperationFailurePreview {
    static func truncate(_ fullMessage: String, limit: Int = 600) -> String {
        let trimmed = fullMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "\n…"
    }
}

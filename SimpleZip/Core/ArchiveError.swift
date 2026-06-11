//
//  ArchiveError.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

/// 归档操作中可预期的错误，负责把底层失败转成用户可读提示。
enum ArchiveError: LocalizedError {
    case unsupportedFormat
    case missingSevenZip
    case missingRarTool
    case missingGPG
    case invalidSevenZipVolumeSize
    case singleFileCompressionRequiresSingleFile
    case passwordsDoNotMatch
    case extractedItemNotFound
    case openExtractedItemFailed
    case exportDestinationExists
    case unsafeArchiveEntries([String])
    case unsafeArchiveLinks([String])
    case blockedBySecurityPolicy
    case sizContainerUnsupportedOptions(String)
    case passwordPromptExhausted
    /// 0.4.3 #3:写回前发现归档在打开后被外部(Finder / 其他 App / 其他窗口进程)修改 —— 停止写入。
    case archiveExternallyModified(String)
    /// 0.4.3 #4:磁盘空间预检不通过(needed = 估算需要,available = 当前剩余,均字节)。
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return L10n.text("error.unsupportedFormat")
        case .missingSevenZip:
            return L10n.text("error.missingSevenZip")
        case .missingRarTool:
            return L10n.text("error.missingRarTool")
        case .missingGPG:
            return L10n.text("error.missingGPG")
        case .invalidSevenZipVolumeSize:
            return L10n.text("error.invalidSevenZipVolumeSize")
        case .singleFileCompressionRequiresSingleFile:
            return L10n.text("error.singleFileCompressionRequiresSingleFile")
        case .passwordsDoNotMatch:
            return L10n.text("error.passwordsDoNotMatch")
        case .extractedItemNotFound:
            return L10n.text("error.extractedItemNotFound")
        case .openExtractedItemFailed:
            return L10n.text("error.openExtractedItemFailed")
        case .exportDestinationExists:
            return L10n.text("error.exportDestinationExists")
        case .unsafeArchiveEntries(let names):
            return L10n.format("error.unsafeArchiveEntries", names.joined(separator: ", "))
        case .unsafeArchiveLinks(let names):
            return L10n.format("error.unsafeArchiveLinks", names.joined(separator: ", "))
        case .blockedBySecurityPolicy:
            return L10n.text("error.blockedBySecurityPolicy")
        case .sizContainerUnsupportedOptions(let reason):
            return L10n.format("error.siz.unsupportedOptions", reason)
        case .passwordPromptExhausted:
            return L10n.text("error.passwordPromptExhausted")
        case .archiveExternallyModified(let name):
            return L10n.format("error.archive.externallyModified", name)
        case .insufficientDiskSpace(let needed, let available):
            return L10n.format(
                "error.insufficientDiskSpace",
                ByteCountFormatter.string(fromByteCount: needed, countStyle: .file),
                ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            )
        case .commandFailed(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

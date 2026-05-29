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
        case .commandFailed(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

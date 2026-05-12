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
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return L10n.text("error.unsupportedFormat")
        case .missingSevenZip:
            return L10n.text("error.missingSevenZip")
        case .commandFailed(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

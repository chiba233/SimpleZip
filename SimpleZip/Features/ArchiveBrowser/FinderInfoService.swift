//
//  FinderInfoService.swift
//  SimpleZip
//
//  Created by Codex on 2026/06/01.
//

import AppKit
import Foundation

enum FinderInfoService {
    enum Failure: LocalizedError {
        case scriptUnavailable
        case finderError(String)

        var errorDescription: String? {
            switch self {
            case .scriptUnavailable:
                return "AppleScript is unavailable."
            case .finderError(let message):
                return message
            }
        }
    }

    static func openInfoWindows(for urls: [URL]) throws {
        guard !urls.isEmpty else { return }
        let body = urls
            .map { #"open information window of (POSIX file "\#(appleScriptStringLiteralContent($0.path))" as alias)"# }
            .joined(separator: "\n")
        let source = "tell application \"Finder\"\nactivate\n\(body)\nend tell"
        guard let script = NSAppleScript(source: source) else {
            throw Failure.scriptUnavailable
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? (errorInfo[NSAppleScript.errorBriefMessage] as? String)
                ?? String(describing: errorInfo)
            throw Failure.finderError(message)
        }
    }

    private static func appleScriptStringLiteralContent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

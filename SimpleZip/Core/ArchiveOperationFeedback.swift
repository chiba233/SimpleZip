//
//  ArchiveOperationFeedback.swift
//  SimpleZip
//
//  Created by Copilot on 2026/05/28.
//

import Foundation

struct ArchiveOperationFailureAlert: Identifiable, Equatable {
    let id = UUID()
    let fullMessage: String
    let previewLimit: Int

    init(message: String, previewLimit: Int = 600) {
        self.fullMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.previewLimit = previewLimit
    }

    var previewMessage: String {
        guard fullMessage.count > previewLimit else { return fullMessage }
        let preview = String(fullMessage.prefix(previewLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(preview)\n…"
    }
}

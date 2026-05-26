//
//  TemporaryResourceManager.swift
//  SimpleZip
//
//  Created by OpenAI on 2026/05/18.
//

import Foundation

enum TemporaryResourceManager {
    static let openedArchiveItemsDirectoryName = "SimpleZipArchiveOpen"

    static func openedArchiveItemsRoot(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(openedArchiveItemsDirectoryName, isDirectory: true)
    }

    static func cleanStaleOpenedArchiveItems(fileManager: FileManager = .default) {
        let root = openedArchiveItemsRoot(fileManager: fileManager)
        guard fileManager.fileExists(atPath: root.path) else { return }
        try? fileManager.removeItem(at: root)
    }

    static func makeOpenedArchiveItemDirectory(fileManager: FileManager = .default) throws -> URL {
        let root = openedArchiveItemsRoot(fileManager: fileManager)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

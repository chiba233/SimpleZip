//
//  FileColumn.swift
//  SimpleZip
//
//  Created by Codex on 2026/06/01.
//

import CoreGraphics
import Foundation

enum FileColumn: String, TableColumnDescriptor {
    case name
    case size
    case type
    case application
    case lastOpened
    case dateAdded
    case modified
    case created
    case symlink
    case permissions
    case owner

    init?(identifier: String) {
        self.init(rawValue: identifier)
    }

    var identifier: String { rawValue }

    var title: String {
        switch self {
        case .name:
            return L10n.text("column.name")
        case .size:
            return L10n.text("column.size")
        case .type:
            return L10n.text("column.kind")
        case .application:
            return L10n.text("column.application")
        case .lastOpened:
            return L10n.text("column.lastOpened")
        case .dateAdded:
            return L10n.text("column.dateAdded")
        case .modified:
            return L10n.text("column.modified")
        case .created:
            return L10n.text("column.created")
        case .symlink:
            return L10n.text("column.symlink")
        case .permissions:
            return L10n.text("column.permissions")
        case .owner:
            return L10n.text("column.owner")
        }
    }

    var width: CGFloat {
        switch self {
        case .name:
            return 420
        case .size:
            return 110
        case .type:
            return 180
        case .application:
            return 160
        case .lastOpened, .dateAdded, .modified, .created:
            return 170
        case .symlink:
            return 240
        case .permissions:
            return 130
        case .owner:
            return 120
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name:
            return 240
        case .size:
            return 90
        case .type:
            return 120
        case .application:
            return 120
        case .lastOpened, .dateAdded, .modified, .created:
            return 140
        case .symlink:
            return 140
        case .permissions:
            return 110
        case .owner:
            return 90
        }
    }

    func value(for item: FileItem) -> String {
        switch self {
        case .name:
            return item.displayName
        case .size:
            return item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        case .type:
            return item.typeDescription
        case .application:
            return item.applicationName
        case .lastOpened:
            return item.lastOpened.map(Self.dateFormatter.string(from:)) ?? ""
        case .dateAdded:
            return item.dateAdded.map(Self.dateFormatter.string(from:)) ?? ""
        case .modified:
            return item.modified.map(Self.dateFormatter.string(from:)) ?? ""
        case .created:
            return item.created.map(Self.dateFormatter.string(from:)) ?? ""
        case .symlink:
            return item.symlinkTarget
        case .permissions:
            return item.permissions
        case .owner:
            return item.owner
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

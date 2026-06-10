//
//  ArchiveColumn.swift
//  SimpleZip
//
//  Created by Codex on 2026/06/11.
//

import CoreGraphics
import Foundation

enum ArchiveColumn: String, TableColumnDescriptor {
    case name
    case kind
    case size
    case modified
    case method
    // 0.1.10 起的可选列。path / encrypted 不需要 parser 工作（ArchiveItem 已有字段），
    // packedSize / crc / created / attributes 走 7zz -slt 输出；zip 后备路径和 DMG 后端会留空。
    case path
    case encrypted
    case packedSize
    case crc
    case created
    case attributes
    // 0.3.2：对照官方 7-Zip GUI 补的可选列（accessed / host OS / characteristics / symlink target）。
    case accessed
    case hostOS
    case characteristics
    case symlink
    // 0.3.3：注释列（zip per-entry Comment，7zz -slt 的 `Comment` 字段；无注释的格式留空）。
    case comment

    init?(identifier: String) {
        self.init(rawValue: identifier)
    }

    var identifier: String { rawValue }

    var title: String {
        switch self {
        case .name:
            return L10n.text("column.name")
        case .kind:
            return L10n.text("column.kind")
        case .size:
            return L10n.text("column.size")
        case .modified:
            return L10n.text("column.modified")
        case .method:
            return L10n.text("column.method")
        case .path:
            return L10n.text("column.path")
        case .encrypted:
            return L10n.text("column.encrypted")
        case .packedSize:
            return L10n.text("column.packedSize")
        case .crc:
            return L10n.text("column.crc")
        case .created:
            return L10n.text("column.created")
        case .attributes:
            return L10n.text("column.attributes")
        case .accessed:
            return L10n.text("column.accessed")
        case .hostOS:
            return L10n.text("column.hostOS")
        case .characteristics:
            return L10n.text("column.characteristics")
        case .symlink:
            return L10n.text("column.symlink")
        case .comment:
            return L10n.text("column.comment")
        }
    }

    var width: CGFloat {
        switch self {
        case .name:
            return 400
        case .kind:
            return 160
        case .size:
            return 120
        case .modified:
            return 180
        case .method:
            return 120
        case .path:
            return 280
        case .encrypted:
            return 80
        case .packedSize:
            return 120
        case .crc:
            return 110
        case .created:
            return 180
        case .attributes:
            return 120
        case .accessed:
            return 180
        case .hostOS:
            return 110
        case .characteristics:
            return 150
        case .symlink:
            return 220
        case .comment:
            return 220
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name:
            return 260
        case .kind:
            return 120
        case .size:
            return 90
        case .modified:
            return 140
        case .method:
            return 90
        case .path:
            return 160
        case .encrypted:
            return 60
        case .packedSize:
            return 90
        case .crc:
            return 80
        case .created:
            return 140
        case .attributes:
            return 80
        case .accessed:
            return 140
        case .hostOS:
            return 80
        case .characteristics:
            return 100
        case .symlink:
            return 140
        case .comment:
            return 120
        }
    }

    func value(for item: ArchiveItem) -> String {
        switch self {
        case .name:
            return item.displayName
        case .kind:
            return item.typeDescription
        case .size:
            return item.sizeText
        case .modified:
            return item.modifiedText
        case .method:
            return item.method
        case .path:
            return item.name
        case .encrypted:
            // 用 SF Symbol 「锁」字符代替 Yes/No；空字符串明确「未加密」时不画。
            return item.isEncrypted ? "🔒" : ""
        case .packedSize:
            return item.packedSizeText
        case .crc:
            return item.crc
        case .created:
            return item.createdText
        case .attributes:
            return item.attributes
        case .accessed:
            return item.accessedText
        case .hostOS:
            return item.hostOS
        case .characteristics:
            return item.characteristics
        case .symlink:
            return item.symlinkTarget
        case .comment:
            return item.comment
        }
    }
}

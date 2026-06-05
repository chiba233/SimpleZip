//
//  ArchiveModels.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation
import UniformTypeIdentifiers

/// 文件夹浏览模式下的一行文件或文件夹。
struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let displayName: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    /// 是否算隐藏。判定方式由用户偏好 `hiddenDetectionMode` 决定：
    /// `.dotfilesOnly`（默认）仅看名字是否以 . 开头；`.macOSHidden` 再算上 macOS UF_HIDDEN 标志。
    /// 0.2.0：开启「显示隐藏文件」后，隐藏项不再平铺，而是收进默认折叠的「隐藏文件」分组节点。
    let isHidden: Bool
    let size: Int64?
    let modified: Date?
    let created: Date?
    let dateAdded: Date?
    let lastOpened: Date?
    let typeDescription: String
    let applicationName: String
}

/// 地址栏补全候选项。
struct LocationCompletion: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let displayName: String
    let path: String
}

/// 压缩包浏览模式下的一行归档内项目。
///
/// 0.1.10 起：除了基础 4 列（kind/size/modified/method）以外，再保留可选的 packedSize/CRC/created/attributes
/// —— 这些字段只有 7zz `-slt` 长格式才有，zip 后备路径和 DMG 后端会用 nil / "" 填空，UI 自然显示空。
struct ArchiveItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    let sizeText: String
    let modifiedText: String
    let method: String
    let isEncrypted: Bool
    let packedSize: Int64?
    let packedSizeText: String
    let crc: String
    let created: Date?
    let createdText: String
    let attributes: String
    // 0.3.2 起的可选列（对照官方 7-Zip GUI）。都来自 7zz `-slt` 长格式；zip 后备路径 / DMG 后端留空。
    let accessed: Date?
    let accessedText: String
    /// 主操作系统（`Host OS`）—— 归档由哪个系统创建（Unix / FAT / NTFS …）。
    let hostOS: String
    /// 特征（`Characteristics`）—— 7zz 报告的条目内部标志位串。
    let characteristics: String
    /// 符号链接目标（`Symbolic Link`）—— 条目是符号链接时其指向；非符号链接为空。
    let symlinkTarget: String

    init(
        name: String,
        isDirectory: Bool,
        size: Int64?,
        modified: Date?,
        sizeText: String,
        modifiedText: String,
        method: String,
        isEncrypted: Bool = false,
        packedSize: Int64? = nil,
        packedSizeText: String = "",
        crc: String = "",
        created: Date? = nil,
        createdText: String = "",
        attributes: String = "",
        accessed: Date? = nil,
        accessedText: String = "",
        hostOS: String = "",
        characteristics: String = "",
        symlinkTarget: String = ""
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.sizeText = sizeText
        self.modifiedText = modifiedText
        self.method = method
        self.isEncrypted = isEncrypted
        self.packedSize = packedSize
        self.packedSizeText = packedSizeText
        self.crc = crc
        self.created = created
        self.createdText = createdText
        self.attributes = attributes
        self.accessed = accessed
        self.accessedText = accessedText
        self.hostOS = hostOS
        self.characteristics = characteristics
        self.symlinkTarget = symlinkTarget
    }

    /// 列表里只展示当前层级的名称，完整路径继续保留在 name 中用于解压。
    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmedName.split(separator: "/").last.map(String.init) ?? name
    }

    var typeDescription: String {
        if isDirectory {
            return L10n.text("type.folder")
        }
        let ext = URL(fileURLWithPath: displayName).pathExtension
        if let description = UTType(filenameExtension: ext)?.localizedDescription {
            return description
        }
        if !ext.isEmpty {
            return ext.uppercased()
        }
        return L10n.text("type.file")
    }
}

/// 主列表当前展示的是普通文件夹，还是某个压缩包的内容。
enum BrowserMode: Equatable {
    case folder(URL)
    case archive(URL)
    case tag(String)
}

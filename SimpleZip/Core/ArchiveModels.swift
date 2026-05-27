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
struct ArchiveItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    let sizeText: String
    let modifiedText: String
    let method: String

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

//
//  ArchiveModels.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

/// 文件夹浏览模式下的一行文件或文件夹。
struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    let typeDescription: String
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
}

/// 主列表当前展示的是普通文件夹，还是某个压缩包的内容。
enum BrowserMode: Equatable {
    case folder(URL)
    case archive(URL)
    case tag(String)
}

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
    let sizeText: String
    let modifiedText: String
    let method: String
}

/// 主列表当前展示的是普通文件夹，还是某个压缩包的内容。
enum BrowserMode: Equatable {
    case folder(URL)
    case archive(URL)
}

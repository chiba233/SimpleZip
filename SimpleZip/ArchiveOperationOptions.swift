//
//  ArchiveOperationOptions.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

/// 创建压缩包时可选择的格式。
enum ArchiveCreateFormat: String, CaseIterable, Identifiable {
    case zip
    case sevenZip = "7z"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zip:
            return "ZIP"
        case .sevenZip:
            return "7z"
        }
    }

    var pathExtension: String { rawValue }
}

/// 压缩等级。数值直接映射到 zip/7zz 的常用等级。
enum CompressionLevel: Int, CaseIterable, Identifiable {
    case store = 0
    case fast = 1
    case normal = 5
    case maximum = 9

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .store:
            return L10n.text("archive.level.store")
        case .fast:
            return L10n.text("archive.level.fast")
        case .normal:
            return L10n.text("archive.level.normal")
        case .maximum:
            return L10n.text("archive.level.maximum")
        }
    }
}

/// 创建压缩包时收集的选项。
struct ArchiveCreationOptions {
    var format: ArchiveCreateFormat = .zip
    var compressionLevel: CompressionLevel = .normal
    var password = ""
    var skipDSStore = true
    var skipHiddenFiles = true
    var customExcludes = ""
}

/// 创建压缩包的待确认请求。
struct ArchiveCreationRequest: Identifiable {
    let id = UUID()
    let sourceURLs: [URL]
    let directoryURL: URL
    var destinationURL: URL
    var options = ArchiveCreationOptions()
}

/// 整包解压的待确认请求。
struct ExtractArchiveRequest: Identifiable {
    let id = UUID()
    let archiveURL: URL
    var destinationURL: URL
    var password = ""
}

/// 选中解压时的目录处理方式。
enum ExtractPathMode: String, CaseIterable, Identifiable {
    case preserve
    case flatten

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preserve:
            return L10n.text("extract.path.preserve")
        case .flatten:
            return L10n.text("extract.path.flatten")
        }
    }
}

/// 选中解压的待确认请求。
struct ExtractSelectionRequest: Identifiable {
    let id = UUID()
    let archiveURL: URL
    let entries: [ArchiveItem]
    var destinationURL: URL
    var pathMode: ExtractPathMode = .preserve
    var password = ""
}

/// 压缩/解压过程中的进度信息。
struct ArchiveProgressState {
    var fraction: Double?
    var currentFile: String?
    var statusText: String?
}

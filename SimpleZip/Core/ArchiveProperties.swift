//
//  ArchiveProperties.swift
//  SimpleZip
//
//  0.4.4 #13:归档元数据报告的纯逻辑层。
//  - `parse`:从 `7zz l -slt` 输出抽**头部块**(Type/Physical Size/Headers Size/Method/Solid/
//    Blocks/Volumes)—— 条目解析(parseSevenZipList)一直把这一块过滤掉,这里把它拿回来。
//  - `aggregate`:对已列出的条目做聚合(压缩方法分布 / 加密条目 / AppleDouble 痕迹 / 属性分布)。
//  纯函数,SwiftPM 可测。
//

import Foundation

/// `7zz l -slt` 头部块的归档级属性(字段缺失 = 该格式/后端没报)。
nonisolated struct ArchiveProperties: Equatable {
    var type: String?
    var physicalSizeBytes: Int64?
    var headersSizeBytes: Int64?
    var method: String?
    var solid: Bool?
    var blocks: Int?
    var volumes: Int?

    /// 从 `l -slt` 完整输出解析头部块:取第一个 `----------` 分隔线**之前**的 `Key = Value` 行。
    /// (条目块都在分隔线之后;头部块的 Comment 由现成 parseArchiveHeaderComment 负责,这里不重复。)
    static func parse(listOutput: String) -> ArchiveProperties {
        var properties = ArchiveProperties()
        for rawLine in listOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("----------") { break }
            guard let separatorRange = line.range(of: " = ") else { continue }
            let key = String(line[line.startIndex..<separatorRange.lowerBound])
            let value = String(line[separatorRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "Type": properties.type = value
            case "Physical Size": properties.physicalSizeBytes = Int64(value)
            case "Headers Size": properties.headersSizeBytes = Int64(value)
            case "Method": properties.method = value
            case "Solid": properties.solid = value == "+"
            case "Blocks": properties.blocks = Int(value)
            case "Volumes": properties.volumes = Int(value)
            default: break
            }
        }
        return properties
    }
}

/// 条目侧聚合(对已打开归档的现成 items 做,零额外后端调用)。
nonisolated struct ArchiveMetadataAggregate: Equatable {
    struct MethodShare: Equatable {
        let method: String
        let count: Int
    }

    let fileCount: Int
    let folderCount: Int
    /// 压缩方法分布(按条目数降序;空 method 归入 "—")。
    let methodDistribution: [MethodShare]
    let encryptedCount: Int
    /// AppleDouble / __MACOSX 痕迹:`._*` 文件与 `__MACOSX/` 条目 —— 提示「xattr 以兼容形态混进了包」。
    let appleDoubleCount: Int
    /// 属性字符串分布 Top N(7zz 的 Attributes 列,Unix 权限/DOS 属性混排,按出现次数降序)。
    let topAttributes: [MethodShare]

    static func aggregate(items: [ArchiveItem], topAttributeLimit: Int = 6) -> ArchiveMetadataAggregate {
        var fileCount = 0
        var folderCount = 0
        var methodCounts: [String: Int] = [:]
        var encrypted = 0
        var appleDouble = 0
        var attributeCounts: [String: Int] = [:]
        for item in items {
            if item.isDirectory { folderCount += 1 } else { fileCount += 1 }
            if !item.isDirectory {
                let method = item.method.isEmpty ? "—" : item.method
                methodCounts[method, default: 0] += 1
            }
            if item.isEncrypted { encrypted += 1 }
            let lastComponent = (item.name as NSString).lastPathComponent
            if lastComponent.hasPrefix("._") || item.name.split(separator: "/").contains("__MACOSX") {
                appleDouble += 1
            }
            if !item.attributes.isEmpty {
                attributeCounts[item.attributes, default: 0] += 1
            }
        }
        func ranked(_ counts: [String: Int], limit: Int? = nil) -> [MethodShare] {
            let sorted = counts
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { MethodShare(method: $0.key, count: $0.value) }
            if let limit { return Array(sorted.prefix(limit)) }
            return sorted
        }
        return ArchiveMetadataAggregate(
            fileCount: fileCount,
            folderCount: folderCount,
            methodDistribution: ranked(methodCounts),
            encryptedCount: encrypted,
            appleDoubleCount: appleDouble,
            topAttributes: ranked(attributeCounts, limit: topAttributeLimit)
        )
    }
}

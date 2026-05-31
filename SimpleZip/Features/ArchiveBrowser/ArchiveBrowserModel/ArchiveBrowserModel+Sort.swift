//
//  ArchiveBrowserModel+Sort.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//
//  排序：表头点击触发，model 按 column key + ascending 排表。
//

import Foundation

extension ArchiveBrowserModel {
    func sortFileItems(by key: String, ascending: Bool) {
        fileItems.sort { lhs, rhs in
            compareFileItem(lhs, rhs, by: key, ascending: ascending)
        }
    }

    func sortArchiveItems(by key: String, ascending: Bool) {
        archiveItems.sort { lhs, rhs in
            compareArchiveItem(lhs, rhs, by: key, ascending: ascending)
        }
    }

    private func compareFileItem(_ lhs: FileItem, _ rhs: FileItem, by key: String, ascending: Bool) -> Bool {
        let result: ComparisonResult
        switch key {
        case "size":
            result = NSNumber(value: lhs.size ?? -1).compare(NSNumber(value: rhs.size ?? -1))
        case "type":
            result = lhs.typeDescription.localizedStandardCompare(rhs.typeDescription)
        case "application":
            result = lhs.applicationName.localizedStandardCompare(rhs.applicationName)
        case "lastOpened":
            result = (lhs.lastOpened ?? .distantPast).compare(rhs.lastOpened ?? .distantPast)
        case "dateAdded":
            result = (lhs.dateAdded ?? .distantPast).compare(rhs.dateAdded ?? .distantPast)
        case "modified":
            result = (lhs.modified ?? .distantPast).compare(rhs.modified ?? .distantPast)
        case "created":
            result = (lhs.created ?? .distantPast).compare(rhs.created ?? .distantPast)
        default:
            result = lhs.displayName.localizedStandardCompare(rhs.displayName)
        }
        return ascending ? result != .orderedDescending : result == .orderedDescending
    }

    private func compareArchiveItem(_ lhs: ArchiveItem, _ rhs: ArchiveItem, by key: String, ascending: Bool) -> Bool {
        let result: ComparisonResult
        switch key {
        case "kind":
            result = lhs.typeDescription.localizedStandardCompare(rhs.typeDescription)
        case "size":
            result = NSNumber(value: lhs.size ?? -1).compare(NSNumber(value: rhs.size ?? -1))
        case "modified":
            result = (lhs.modified ?? .distantPast).compare(rhs.modified ?? .distantPast)
        case "method":
            result = lhs.method.localizedStandardCompare(rhs.method)
        case "path":
            result = lhs.name.localizedStandardCompare(rhs.name)
        case "encrypted":
            // false<true 让未加密排在前面、加密排在后面（升序）
            result = NSNumber(value: lhs.isEncrypted).compare(NSNumber(value: rhs.isEncrypted))
        case "packedSize":
            result = NSNumber(value: lhs.packedSize ?? -1).compare(NSNumber(value: rhs.packedSize ?? -1))
        case "crc":
            result = lhs.crc.localizedStandardCompare(rhs.crc)
        case "created":
            result = (lhs.created ?? .distantPast).compare(rhs.created ?? .distantPast)
        case "attributes":
            result = lhs.attributes.localizedStandardCompare(rhs.attributes)
        default:
            result = lhs.displayName.localizedStandardCompare(rhs.displayName)
        }
        return ascending ? result != .orderedDescending : result == .orderedDescending
    }
}

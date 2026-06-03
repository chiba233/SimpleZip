//
//  UndoFileSnapshot.swift
//  SimpleZip
//
//  0.3.0 #86 阶段2：撤销/重做的**数据安全核心**——「这个文件还是不是原来那个、有没有被外部改动」的判定。
//  仓库铁律「绝不静默覆盖用户数据」就靠它:每一步撤销/重做前都用它确认「源仍在且未变、目标空闲」,
//  不匹配就跳过该步并提示,绝不覆盖外部期间新建/改动的同名文件。
//
//  原先是 ArchiveBrowserModel+Undo.swift 里的 `private struct`、零测试。这是整个撤销系统里唯一纯逻辑、
//  又最该被测的部分,提到 Core(SwiftPM 可测);递归的 `performUndoable*` 编排因深度耦合 NSUndoManager 留在 model。
//  纯移动、零行为变更。
//

import Foundation

/// 某个 URL 在某一时刻的「身份指纹」:类型 + 大小 + 修改时间 + 设备号 + inode 号。
/// 五项全等才算「还是同一个文件、且没被改过」。设备号 + inode 防的是「原文件被删、又新建一个同名同大小同时间的」。
struct UndoFileSnapshot {
    let fileType: FileAttributeType?
    let fileSize: UInt64?
    let modificationDate: Date?
    let systemNumber: UInt64?
    let fileNumber: UInt64?

    /// 读不到属性(文件不存在 / 无权限)→ 返回 nil,调用方据此判「源已不在」直接跳过。
    init?(url: URL, fileManager: FileManager) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        fileType = attributes[.type] as? FileAttributeType
        fileSize = (attributes[.size] as? NSNumber)?.uint64Value
        modificationDate = attributes[.modificationDate] as? Date
        systemNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// 当前 `url` 处的文件是否与本快照完全一致(存在 + 五项全等)。任一项不同或文件不在 → false。
    func matches(url: URL, fileManager: FileManager) -> Bool {
        guard let current = UndoFileSnapshot(url: url, fileManager: fileManager) else { return false }
        return current.fileType == fileType
            && current.fileSize == fileSize
            && current.modificationDate == modificationDate
            && current.systemNumber == systemNumber
            && current.fileNumber == fileNumber
    }
}

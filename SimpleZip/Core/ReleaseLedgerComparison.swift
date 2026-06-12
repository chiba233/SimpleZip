//
//  ReleaseLedgerComparison.swift
//  SimpleZip
//
//  0.4.4 #3:发布产物的「账面对比」—— 只用账本字段,产物文件不在也能比:
//  体积/文件数变化、结构指纹是否变化、junk 是否回潮。文件级对比(产物都在时)
//  直接复用 ArchiveDiff + 现有比较弹窗,不在这里重做。纯函数,SwiftPM 可测。
//

import Foundation

nonisolated struct ReleaseLedgerComparison: Equatable {
    /// new - old(任一侧没记录大小 → nil)。
    let totalBytesDelta: Int64?
    /// new - old(任一侧没记录文件数 → nil)。
    let fileCountDelta: Int?
    /// 结构指纹变了没(任一侧无指纹 → nil = 无从比较)。
    let fingerprintChanged: Bool?
    /// junk 回潮:上次 0 这次 >0 —— 发布卫生倒退,单独点名。
    let junkRegression: Bool

    static func compare(old: ReleaseLedgerEntry, new: ReleaseLedgerEntry) -> ReleaseLedgerComparison {
        let bytesDelta: Int64?
        if let oldBytes = old.totalBytes, let newBytes = new.totalBytes {
            bytesDelta = newBytes - oldBytes
        } else {
            bytesDelta = nil
        }
        let countDelta: Int?
        if let oldCount = old.fileCount, let newCount = new.fileCount {
            countDelta = newCount - oldCount
        } else {
            countDelta = nil
        }
        let fingerprintChanged: Bool?
        if let oldPrint = old.structuralFingerprint, let newPrint = new.structuralFingerprint {
            fingerprintChanged = oldPrint != newPrint
        } else {
            fingerprintChanged = nil
        }
        let junkRegression = (old.junkCount ?? 0) == 0 && (new.junkCount ?? 0) > 0
        return ReleaseLedgerComparison(
            totalBytesDelta: bytesDelta,
            fileCountDelta: countDelta,
            fingerprintChanged: fingerprintChanged,
            junkRegression: junkRegression
        )
    }
}

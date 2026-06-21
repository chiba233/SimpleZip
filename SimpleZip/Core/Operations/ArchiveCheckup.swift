//
//  ArchiveCheckup.swift
//  SimpleZip
//
//  0.4.4 #7:归档体检批处理的纯逻辑层 —— 条目侧事实聚合(可疑路径 / 垃圾 / 加密)。
//  全部薄封装在已单测的现成件上(ArchiveSecurityReport / ArchiveJunkFiles);
//  跑后端(列目录 / 测试)的部分在 app 侧任务里串行做。
//

import Foundation

nonisolated enum ArchiveCheckup {
    struct EntryFacts: Equatable {
        let suspiciousPathCount: Int
        let junkCount: Int
        let encryptedCount: Int
    }

    static func entryFacts(items: [ArchiveItem]) -> EntryFacts {
        EntryFacts(
            suspiciousPathCount: ArchiveSecurityReport.analyze(items).reduce(0) { $0 + $1.entryPaths.count },
            junkCount: items.filter { ArchiveJunkFiles.isJunkPath($0.name) }.count,
            encryptedCount: items.filter(\.isEncrypted).count
        )
    }
}

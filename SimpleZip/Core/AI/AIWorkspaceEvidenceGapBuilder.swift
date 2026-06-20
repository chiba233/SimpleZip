//
//  AIWorkspaceEvidenceGapBuilder.swift
//  SimpleZip
//
//  0.4.5 #80(工程补充五接线 Phase 1):从工作区成员 + 已算哈希的 ref 集,确定性地判出「补充证据」缺口,
//  喂 `AIBackgroundPlanner.plan` 产 evidence job(Phase 1 只产 missingHash → calculateCheapHashes)。
//
//  纯函数:输入全是值快照(成员 ref 字典 + 已哈希 ref 集),**不依赖任何 store / IndexStore 实例**,
//  不读磁盘、不碰 FSEvents reload —— SwiftPM 可断言、off-main 可调。其余 gap 种类(清单 / 健康 /
//  默认打开方式)后续 Phase 扩;此处只接最安全的「缺哈希」一种(执行/去重/写回流水已在 pending 队列跑通)。
//

import Foundation

nonisolated enum AIWorkspaceEvidenceGapBuilder {
    /// 判出「工作区成员缺哈希」缺口。每个工作区里**还没算过校验和**(不在 `hashedSourceRefs`)的成员聚成
    /// 一条 `missingHash` 缺口(`AIWorkspaceEvidenceGap.missingHash` 自带「算 SHA256」增强动作)。
    ///
    /// 确定性:工作区按 UUID 字符串升序、缺哈希成员按 ref id 升序 —— 同输入永远同输出(可断言)。
    /// 空成员 / 成员全部已哈希的工作区不产缺口。
    static func deriveMissingHash(memberRefsByWorkspace: [UUID: [AIContextSourceRef]],
                                  hashedSourceRefs: Set<AIContextSourceRef>) -> [AIWorkspaceEvidenceGap] {
        var gaps: [AIWorkspaceEvidenceGap] = []
        for workspaceID in memberRefsByWorkspace.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let refs = memberRefsByWorkspace[workspaceID] ?? []
            let missing = refs
                .filter { !hashedSourceRefs.contains($0) }
                .sorted { $0.id < $1.id }
            guard !missing.isEmpty else { continue }
            gaps.append(.missingHash(
                id: "missing-hash-\(workspaceID.uuidString)",
                workspaceID: workspaceID,
                refs: missing,
                reason: "工作区有 \(missing.count) 个成员尚无校验和"))
        }
        return gaps
    }

    /// 判出「工作区里是归档、尚未测过完整性的小包成员」缺口(Phase 2)。`archiveSourceRefs` = 调用方已判定为
    /// 归档且在体积封顶内的成员;`testedSourceRefs` = 已测过(派生索引里有 test 内联结果)的成员。每个工作区里
    /// **是小归档但还没测**的成员聚成一条 `missingArchiveHealth` 缺口(自带「测试归档」增强动作 → testSmallArchives job)。
    /// 确定性排序、空则不产。体积封顶 / 归档判定留给调用方(纯函数不读磁盘)。
    static func deriveMissingArchiveHealth(memberRefsByWorkspace: [UUID: [AIContextSourceRef]],
                                           archiveSourceRefs: Set<AIContextSourceRef>,
                                           testedSourceRefs: Set<AIContextSourceRef>) -> [AIWorkspaceEvidenceGap] {
        var gaps: [AIWorkspaceEvidenceGap] = []
        for workspaceID in memberRefsByWorkspace.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let refs = memberRefsByWorkspace[workspaceID] ?? []
            let untested = refs
                .filter { archiveSourceRefs.contains($0) && !testedSourceRefs.contains($0) }
                .sorted { $0.id < $1.id }
            guard !untested.isEmpty else { continue }
            gaps.append(.missingArchiveHealth(
                id: "missing-health-\(workspaceID.uuidString)",
                workspaceID: workspaceID,
                refs: untested,
                reason: "工作区有 \(untested.count) 个归档成员尚未测试完整性"))
        }
        return gaps
    }
}

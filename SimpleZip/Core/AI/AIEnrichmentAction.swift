//
//  AIEnrichmentAction.swift
//  SimpleZip
//
//  0.4.5 #80:AI 只读数据增强动作(白皮书「AI 只读数据增强动作」 638-670)。AI 不能只被动等已有缓存 ——
//  对低风险、只读、可取消的动作,AI 可以**建议**「补充数据」,让 App 执行后把结果写进派生索引,使 AI 文件夹
//  和建议卡更准(哈希、测试归档、刷新清单、结构指纹、刷新文件 facts / 默认打开方式)。
//
//  安全边界(硬约束):
//  - 只有 App 能把 `sourceRefs` 回查成真实 URL;模型不能输出任意路径去执行。
//  - 全部是 `readOnlyDataEnrichment`:**不写用户文件**,但可能耗 CPU/IO —— 前台建议需用户点击确认,后台
//    执行须低负载 + 白名单 + 可取消(由调度器保证,见 AIPrefetch)。
//  - 加密归档 / GPG 密文 / 无读权限 / 被排除路径 / 临时解密目录 / 敏感目录只能记「无法增强」omission,不尝试读取。
//  - 结果只进派生索引,**绝不**存文件内容摘要 / 文本片段 / 二进制内容。
//
//  纯值类型 + 确定性,SwiftPM 可断言。算法复用 Core `HashAlgorithm`(不 stringly-type,A2)。
//

import Foundation

/// 受控的只读数据增强动作。AI 只能从这几种里建议,且只携带候选集内的 `sourceRefs`。
nonisolated enum AIReadOnlyEnrichmentAction: Codable, Equatable, Sendable {
    case calculateHashes(sourceRefs: [AIContextSourceRef], algorithms: [HashAlgorithm])
    case testArchives(sourceRefs: [AIContextSourceRef])
    case refreshArchiveListing(sourceRefs: [AIContextSourceRef])
    case computeArchiveFingerprint(sourceRefs: [AIContextSourceRef])
    case refreshFileSystemFacts(sourceRefs: [AIContextSourceRef])
    case refreshDefaultOpenApps(sourceRefs: [AIContextSourceRef])

    /// 稳定英文 token,用于日志 / 结果回填 / debug。
    var kind: String {
        switch self {
        case .calculateHashes: return "calculate-hashes"
        case .testArchives: return "test-archives"
        case .refreshArchiveListing: return "refresh-archive-listing"
        case .computeArchiveFingerprint: return "compute-archive-fingerprint"
        case .refreshFileSystemFacts: return "refresh-filesystem-facts"
        case .refreshDefaultOpenApps: return "refresh-default-open-apps"
        }
    }

    /// 本动作携带的来源引用(每种 case 都有一组 sourceRefs)。
    var sourceRefs: [AIContextSourceRef] {
        switch self {
        case let .calculateHashes(refs, _): return refs
        case let .testArchives(refs): return refs
        case let .refreshArchiveListing(refs): return refs
        case let .computeArchiveFingerprint(refs): return refs
        case let .refreshFileSystemFacts(refs): return refs
        case let .refreshDefaultOpenApps(refs): return refs
        }
    }

    /// 全部是只读数据增强:不写用户文件,但可能耗 CPU/IO。
    var isReadOnlyDataEnrichment: Bool { true }

    /// 前台建议需用户点击确认(耗 CPU/IO);后台执行由调度器保证低负载 / 可取消。
    var requiresUserClickInForeground: Bool { true }

    /// 确定性 action id(kind + 排序后的 ref 身份)。结果用它回填 `generatedByActionID`,可去重 / 追溯。
    var actionID: String {
        let refKey = sourceRefs
            .map { $0.kind.rawValue + ":" + $0.id }
            .sorted()
            .joined(separator: ",")
        return "enrich-" + kind + "-" + AIStableHash.fnv1a32Hex(refKey)
    }

    /// 用相同动作语义替换 sourceRefs(校验剔除非法 ref 后重建动作用)。
    func replacingSourceRefs(_ refs: [AIContextSourceRef]) -> AIReadOnlyEnrichmentAction {
        switch self {
        case let .calculateHashes(_, algorithms): return .calculateHashes(sourceRefs: refs, algorithms: algorithms)
        case .testArchives: return .testArchives(sourceRefs: refs)
        case .refreshArchiveListing: return .refreshArchiveListing(sourceRefs: refs)
        case .computeArchiveFingerprint: return .computeArchiveFingerprint(sourceRefs: refs)
        case .refreshFileSystemFacts: return .refreshFileSystemFacts(sourceRefs: refs)
        case .refreshDefaultOpenApps: return .refreshDefaultOpenApps(sourceRefs: refs)
        }
    }
}

/// 增强动作的安全闸:校验 ref 在候选集内 + 判定某文件能否被增强(加密 / 无权限 / 排除一律拒绝)。
nonisolated enum AIEnrichmentGate {
    /// 把模型建议的动作里**不在候选集**的 ref 剔除;ref 全被剔光的动作整条丢弃。模型不能凭空指定路径。
    static func sanitized(_ actions: [AIReadOnlyEnrichmentAction],
                          allowed: Set<AIContextSourceRef>) -> [AIReadOnlyEnrichmentAction] {
        actions.compactMap { action in
            let valid = action.sourceRefs.filter { allowed.contains($0) }
            guard !valid.isEmpty else { return nil }
            return action.replacingSourceRefs(valid)
        }
    }

    /// 增强被拒的原因(稳定 token);nil = 允许增强。
    nonisolated enum BlockReason: String, Codable, Equatable, Sendable {
        case noReadPermission = "no_read_permission"
        case excludedByUser = "excluded_by_user"
        case encryptedArchive = "encrypted_listing_unavailable"
        case sensitiveDirectory = "sensitive_directory"
        case decryptTempDirectory = "decrypt_temp_directory"
    }

    /// 一个文件 / 归档能否被增强(读取以算哈希 / 测试 / 刷新清单)。注意:增强产出**派生信号 / 摘要,不存内容**,
    /// 因此门控比内容可读性宽 ——「疑似密钥文件名」不挡增强(哈希只产摘要),但加密归档清单不可见时必须挡。
    /// 顺序固定 → 确定性。
    static func blockReason(absolutePath: String, currentUserCanRead: Bool,
                            isExcludedByUser: Bool, isEncryptedArchive: Bool) -> BlockReason? {
        if !currentUserCanRead { return .noReadPermission }
        if isExcludedByUser { return .excludedByUser }
        if isEncryptedArchive { return .encryptedArchive }
        if AIFileReadabilityPolicy.isSensitiveDirectory(absolutePath) { return .sensitiveDirectory }
        if AIFileReadabilityPolicy.isDecryptOrTempPath(absolutePath) { return .decryptTempDirectory }
        return nil
    }
}

/// 一次增强执行的结果。**只存派生信号,绝不存文件内容**。供 AI 中心调试 / 清空 / 追溯。
/// `startedAt` / `completedAt` 由 App 侧传入(Core 不取 wall-clock,保持确定性可测)。
nonisolated struct AIEnrichmentResult: Codable, Equatable, Sendable {
    let generatedByActionID: String
    let actionKind: String
    /// 实际处理到的来源引用。
    let sourceRefs: [AIContextSourceRef]
    let startedAt: Date
    let completedAt: Date
    /// 产出的派生信号 token(如 `sha256-computed`、`listing-refreshed`、`fingerprint-computed`)—— 不含任何文件内容。
    let producedSignals: [String]
    let omissions: [AIContextOmission]

    init(action: AIReadOnlyEnrichmentAction, startedAt: Date, completedAt: Date,
         producedSignals: [String] = [], omissions: [AIContextOmission] = []) {
        self.generatedByActionID = action.actionID
        self.actionKind = action.kind
        self.sourceRefs = action.sourceRefs
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.producedSignals = producedSignals
        self.omissions = omissions
    }
}

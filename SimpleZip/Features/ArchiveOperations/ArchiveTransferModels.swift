//
//  ArchiveTransferModels.swift
//  SimpleZip
//
//  0.3.0 架构拆分：从 ArchiveExtractionCoordinator.swift 切出的传输/冲突数据模型，纯移动、零行为变更。
//

import Foundation

/// 一次粘贴 / 拖放 / 合并操作期间共享的冲突解决状态：记住的选择、哈希比对结果、逐文件传输日志。
final class ConflictResolutionSession {
    let allowsRememberedChoice: Bool
    var rememberedChoice: PasteConflictChoice?
    var hashResults: [HashOverwriteResult] = []
    /// 本次操作的逐文件结果（新增 / 覆盖 / 跳过）—— 结束汇总弹窗与活动中心都从这里取，统一来源。
    var transferLog: [TransferLogEntry] = []

    init(allowsRememberedChoice: Bool = true) {
        self.allowsRememberedChoice = allowsRememberedChoice
    }
}

/// 同名冲突时用户的处理选择。两个正交的轴：合并/整体替换 × 总是覆盖/仅当哈希不同时覆盖。
/// - `.replace` / `.replaceIfDifferent`：把目标当整体处理（替换 / 仅指纹不同时替换）。
/// - `.merge` / `.mergeIfDifferent`：仅文件夹 vs 同名文件夹，深度递归合并、保留目标里多余的文件，
///   对同名项分别执行覆盖 / 仅哈希不同时覆盖。
enum PasteConflictChoice: Equatable {
    case replace
    case replaceIfDifferent
    case merge
    case mergeIfDifferent
    case skip
    case cancel
    /// 创建压缩包输出冲突专用：两个都保留（产物自动去重改名）。仅 .archiveOutput 场景出现。
    case keepBoth

    /// 该选择在「仅当哈希不同时才覆盖」这个轴上是否开启。
    var prefersHashGate: Bool {
        self == .replaceIfDifferent || self == .mergeIfDifferent
    }

    /// 该选择是否要求对文件夹做深度合并（而非整体替换）。
    var prefersMerge: Bool {
        self == .merge || self == .mergeIfDifferent
    }
}

/// 一次传输里对单个项目实际做了什么 —— 供活动中心逐文件展示，避免「只记哈希比对、新增文件无痕」的盲点。
enum TransferAction: String, Codable {
    case added        // 新增：目标原本没有，直接写入
    case overwritten  // 覆盖：目标已有同名项，被替换
    case changed      // 更改：项目本身保留，只改了属性（如 chmod / chown 权限与属主）；`detail` 带新值
    case skipped      // 跳过：同名项未替换（用户选跳过 / 哈希相同）
    case deleted      // 删除：移到废纸篓
    case failed       // 失败：该项未能完成（批量操作里某些项失败但其它项成功）；`detail` 带原因
    case passed       // 通过：完整性测试通过（0.4.2 批量测试）

    /// 解码容错：**新版本写的新 case 被旧版本读到**时不抛错（抛错会废掉那条任务乃至整段历史 ——
    /// 0.4.2 用户报「活动中心经常丢历史」的根因之一）。未知值降级成中性的 `.changed`。
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TransferAction(rawValue: raw) ?? .changed
    }
}

/// 活动中心逐文件日志条目。随任务历史持久化，重启后仍可查看。
struct TransferLogEntry: Codable {
    let name: String
    let action: TransferAction
    let isDirectory: Bool
    /// 可空备注 —— 目前用于 `.failed` 项的失败原因（活动中心红色行下展示）。向后兼容（旧历史无此键）。
    let detail: String?

    init(name: String, action: TransferAction, isDirectory: Bool, detail: String? = nil) {
        self.name = name
        self.action = action
        self.isDirectory = isDirectory
        self.detail = detail
    }

    // 自定义解码：旧版本历史没有 isDirectory / detail 键，缺省安全回退，避免整段历史解码失败。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        action = try container.decode(TransferAction.self, forKey: .action)
        isDirectory = try container.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }
}

/// `transferItem` 递归传输的统计结果，供活动中心汇总「成功 / 跳过 / 哈希相同跳过」数量。
struct TransferStats {
    var transferred = 0
    var skipped = 0
    var sameHashSkips = 0

    mutating func merge(_ other: TransferStats) {
        transferred += other.transferred
        skipped += other.skipped
        sameHashSkips += other.sameHashSkips
    }
}

struct HashOverwriteResult: Codable {
    let sourceURL: URL
    let targetURL: URL
    let sourceHash: String
    let targetHash: String
    let isSame: Bool
}

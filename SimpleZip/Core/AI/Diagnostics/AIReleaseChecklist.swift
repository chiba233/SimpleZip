//
//  AIReleaseChecklist.swift
//  SimpleZip
//
//  0.4.5 #80:发布前 checklist(白皮书 Feat 20)。SimpleZip 对 release 包 / SIZ-SZS / 签名 / hash / 报告已有
//  很多上下文。这里把它们组织成一份发布前自查清单:**清单项来自固定模板,状态来自确定性 facts**(模型只把
//  清单组织得自然,绝不决定项目或状态)。
//
//  与 ReleaseDirectoryAudit / Quick Verify(#44)不重叠:那些算「发布目录里有什么」;这里只把那些结果摆成
//  「勾选项 + 下一步动作」的轻量清单。GPG 关闭时签名 / 公钥项整体不出现(A4 门控,见 [[feedback_gpg_visibility]])。
//  纯函数、确定性,SwiftPM 可断言。
//

import Foundation

/// 清单项标识(稳定 token)。App 按它做 L10n 与图标。
nonisolated enum AIReleaseChecklistItemID: String, Codable, Equatable, CaseIterable, Sendable {
    case testArchive = "test-archive"
    case verifyHash = "verify-hash"
    case checkSignature = "check-signature"
    case publicKeyPresent = "public-key-present"
    case verifyDocPresent = "verify-doc-present"
    case inspectReport = "inspect-report"

    /// 该项缺失时对应的建议动作 id(在 App 的发布动作 allowlist 内);纯展示项无动作返回 nil。
    var missingActionID: String? {
        switch self {
        case .testArchive: return "runTest"
        case .verifyHash: return "verifyChecksums"
        case .checkSignature: return "checkSignature"
        case .inspectReport: return "runReleaseInspection"
        case .publicKeyPresent, .verifyDocPresent: return nil
        }
    }

    /// 是否是 GPG / 签名相关项(GPG 关闭时不出现)。
    var isSignatureRelated: Bool { self == .checkSignature || self == .publicKeyPresent }
}

/// 清单项状态。
nonisolated enum AIReleaseChecklistItemState: String, Codable, Equatable, Sendable {
    case missing    // 缺失 / 未做
    case available  // 材料就绪但未执行核对
    case passed     // 已通过
}

nonisolated struct AIReleaseChecklistItem: Codable, Equatable, Identifiable, Sendable {
    let id: AIReleaseChecklistItemID
    let state: AIReleaseChecklistItemState
}

/// 发布前 checklist 的确定性事实(App adapter 从 Quick Verify / 目录审计 / 任务结果填充)。
nonisolated struct AIReleaseChecklistFacts: Codable, Equatable, Sendable {
    let hasChecksumFile: Bool   // SHA256SUMS
    let hasSignature: Bool      // .szs / .asc
    let hasPublicKey: Bool      // PUBLIC_KEY.asc
    let hasVerifyDoc: Bool      // VERIFY.md
    let archiveTested: Bool
    let inspectionDone: Bool
    /// GPG 总开关 —— 关闭时签名 / 公钥项整体不渲染(A4)。
    let gpgEnabled: Bool

    init(hasChecksumFile: Bool = false, hasSignature: Bool = false, hasPublicKey: Bool = false,
         hasVerifyDoc: Bool = false, archiveTested: Bool = false, inspectionDone: Bool = false,
         gpgEnabled: Bool = false) {
        self.hasChecksumFile = hasChecksumFile
        self.hasSignature = hasSignature
        self.hasPublicKey = hasPublicKey
        self.hasVerifyDoc = hasVerifyDoc
        self.archiveTested = archiveTested
        self.inspectionDone = inspectionDone
        self.gpgEnabled = gpgEnabled
    }
}

nonisolated struct AIReleaseChecklist: Codable, Equatable, Sendable {
    let items: [AIReleaseChecklistItem]
    /// 第一个「缺失且有动作」的项对应的建议动作;全部就绪则 nil。
    let primaryActionID: String?
}

nonisolated enum AIReleaseChecklistBuilder {
    /// 从确定性 facts 构建清单(固定项顺序 → 确定性)。GPG 关闭时跳过签名 / 公钥项。
    static func build(from f: AIReleaseChecklistFacts) -> AIReleaseChecklist {
        var items: [AIReleaseChecklistItem] = []
        func add(_ id: AIReleaseChecklistItemID, _ state: AIReleaseChecklistItemState) {
            if id.isSignatureRelated && !f.gpgEnabled { return }
            items.append(AIReleaseChecklistItem(id: id, state: state))
        }
        add(.testArchive, f.archiveTested ? .passed : .missing)
        add(.verifyHash, f.hasChecksumFile ? .available : .missing)
        add(.checkSignature, f.hasSignature ? .available : .missing)
        add(.publicKeyPresent, f.hasPublicKey ? .available : .missing)
        add(.verifyDocPresent, f.hasVerifyDoc ? .available : .missing)
        add(.inspectReport, f.inspectionDone ? .passed : .missing)

        let primary = items.first { $0.state == .missing && $0.id.missingActionID != nil }?.id.missingActionID
        return AIReleaseChecklist(items: items, primaryActionID: primary)
    }
}

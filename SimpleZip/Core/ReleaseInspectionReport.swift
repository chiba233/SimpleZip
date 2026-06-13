//
//  ReleaseInspectionReport.swift
//  SimpleZip
//
//  一次发布包检查的结果(0.4.2 #15)。条目侧统计在 Core(ReleaseInspection),这里聚合
//  测试 / SHA-256 / 注释 / 安全发现 / bundle 检查 / 质量门 / 步骤耗时。
//
//  纯值类型(Codable,无副作用)—— 从 `ArchiveBrowserModel` 的 extension 下沉到 Core,
//  让 SwiftPM 能直接测 Codable 往返。`ReportExportable` 导出适配 + L10n 仍留在 Features
//  (ReleaseInspectionView.swift),因为它们要 app 层的 L10n / 导出底座。
//

import Foundation

nonisolated struct ReleaseInspectionReport: Identifiable, Codable {
    let id = UUID()
    /// Codable 排除 `id`(带初值的 let 不能解码)—— 0.4.4 报告随任务历史持久化用。
    private enum CodingKeys: String, CodingKey {
        case archiveURL, listable, stats, securityFindings, testPassed, testFailureMessage
        case sha256, hasComment, publicKeyBesideSignature, structuralFingerprint
        case bundleFindings, isBundleOnly, gateViolations, steps
    }
    let archiveURL: URL
    var listable = false
    var stats: ReleaseInspectionStats?
    var securityFindings: [ArchiveSecurityFinding] = []
    var testPassed: Bool?
    var testFailureMessage: String?
    var sha256: String?
    var hasComment = false
    /// 公钥分发检查:归档同目录有签名容器(.szs/.siz)时,旁边有没有可分发的公钥(.asc)。
    /// nil = 目录里没有签名容器,报告不显示该行;false = 有容器没公钥(收件人无法独立验证,提醒)。
    var publicKeyBesideSignature: Bool?
    /// 结构指纹(#9):条目结构(路径/类型/大小/CRC)的 SHA-256,忽略时间戳/注释/垃圾 ——
    /// 两个包指纹相同 = 结构上同一份东西(哪怕重新打包、文件级 SHA-256 不同)。listable 才有。
    var structuralFingerprint: String?
    /// #6 专项检查:目标是 .app/.dmg/.xip 时的 bundle 级结论(Info.plist/codesign/spctl/
    /// DMG 顶层结构/XIP 签名)。空 = 不适用,报告不显示该区。
    var bundleFindings: [BundleReleaseCheck.Finding] = []
    /// true = 直接对 .app 目录跑的检查 —— 归档侧区块(完整性测试/条目/SHA-256)整段不渲染。
    var isBundleOnly = false
    /// #10:质量门触发的违规(发布助手跑、且开了规则才非空;阻断的运行不会走到报告 sheet)。
    var gateViolations: [ReleaseGate.Violation] = []
    /// C:本次发布运行的步骤耗时(右键检查流程为空 —— 它没有步骤引擎)。
    var steps: [ReleaseRunStep] = []
}

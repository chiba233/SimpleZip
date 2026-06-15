//
//  AILens.swift
//  SimpleZip
//
//  0.4.5 #80:AI Lens 视图 ——「视角切换」(白皮书 Feat 2)。Lens 不改变真实文件,只换一个 query plan
//  把同一批已索引对象重新虚拟组织。它比完整 AI 工作区更轻:用户在当前目录 / 归档上切一个 lens,App 用
//  对应 plan 确定性召回并分组。
//
//  关键:**每个 lens 的 query plan 完全确定性**(不依赖模型),模型只负责给分组命名 / 排序理由。这里把
//  每个 lens 映射成一个稳定的 `AIWorkspaceQueryPlan`(复用 Feat 6 的执行器召回真实 source ref),
//  纯值 + 确定性,SwiftPM 可断言。rawValue 是稳定英文 token(prompt / 调试 / 缓存共用,不随 UI 语言走)。
//
//  注:Lens 的人类可读标题由 UI 层本地化(不在 Core 引 L10n key,避免半接线);Core 只给稳定 token、
//  SF Symbol 名和确定性 plan。
//

import Foundation

/// 主窗口的 AI 视角。稳定英文 token。
nonisolated enum AILens: String, Codable, Equatable, CaseIterable, Sendable {
    /// 发布视角:发布产物、校验文件、签名、发布检查任务。
    case release
    /// 源码视角:源码包、Package.swift / package.json / README / LICENSE、代码文件。
    case source
    /// 失败视角:失败任务、checksum mismatch / permission denied / 缺卷、可重跑项。
    case failures
    /// 签名 / 校验视角:.siz / .szs / .asc、签名报告、hash 报告、VERIFY.md。
    case signing
    /// 清理视角:疑似重复包、散落解压痕迹、__MACOSX / AppleDouble、同名旧产物。
    case cleanup

    /// 对应的确定性查询计划。Lens 切换 = 换 plan 重组,召回由 `AIWorkspaceQueryExecutor` 完成。
    var queryPlan: AIWorkspaceQueryPlan {
        switch self {
        case .release:
            return AIWorkspaceQueryPlan(
                semanticTags: ["release-artifact"],
                taskTags: ["checksum-mismatch", "signature-problem"],
                markerFiles: ["SHA256SUMS", "VERIFY.md", "signature.asc"],
                includeArchives: true,
                includeArchiveEntries: true,
                includeTasks: true,
                includeReports: true
            )
        case .source:
            return AIWorkspaceQueryPlan(
                semanticTags: ["source-archive", "swift-project", "localized-app"],
                markerFiles: ["Package.swift", "package.json", "pyproject.toml", "README.md", "LICENSE"],
                includeArchives: true,
                includeArchiveEntries: true,
                includeTasks: false
            )
        case .failures:
            return AIWorkspaceQueryPlan(
                taskTags: AIDiagnosticTag.allCases.map(\.rawValue),
                includeArchives: false,
                includeTasks: true,
                includeActions: true
            )
        case .signing:
            return AIWorkspaceQueryPlan(
                semanticTags: ["signed-container-related"],
                taskTags: ["signature-problem"],
                markerFiles: ["signature.asc", "VERIFY.md"],
                includeArchives: true,
                includeArchiveEntries: true,
                includeTasks: true,
                includeReports: true
            )
        case .cleanup:
            return AIWorkspaceQueryPlan(
                semanticTags: ["backup"],
                keywords: ["__macosx", ".ds_store", "appledouble"],
                includeArchives: true,
                includeArchiveEntries: true,
                includeTasks: false
            )
        }
    }

    /// 视角图标(SF Symbol)。
    var iconSystemName: String {
        switch self {
        case .release: return "shippingbox"
        case .source: return "chevron.left.forwardslash.chevron.right"
        case .failures: return "exclamationmark.triangle"
        case .signing: return "checkmark.seal"
        case .cleanup: return "trash"
        }
    }
}

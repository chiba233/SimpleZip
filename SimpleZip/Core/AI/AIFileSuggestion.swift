//
//  AIFileSuggestion.swift
//  SimpleZip
//
//  0.4.5 #80:AI suggestion **主场** —— 文件浏览器里「每个文件行内展开抽屉」的一条建议。
//
//  用户拍板的新方向(见 memory ai_suggestion_inline_direction):AI 文件夹概念废弃,AI 退居配角,
//  在用户已打开的文件夹里给眼前的文件做注解。每个文件行可展开一个抽屉:第一行是 AI 对这个文件的
//  **一句话定性**,后面跟几个**类型相关的快捷动作**。得益于后台索引 + 调度,这些建议早就预解析缓存好,
//  打开文件夹瞬间就有,不是点开才现算。
//
//  本类型是**确定性**组装层:输入 = 即时类型判定(AIFileType)+ 后台预解析事实(AIFileContentSummary /
//  归档清单)+ 派生信号(疑似重复 / 更合适的打开 App);输出 = **结构化** headline + action。
//  **Core 不出人话整句**(只携带已脱敏的专有名词:文档主题词 / 归档条目名 / App 名 / 语言 token);
//  完整文案由 App 侧按界面语言本地化渲染。纯值类型 + 确定性,SwiftPM 可断言。
//
//  红线:文档主题词只来自**已脱敏**的 `AIFileContentSummary`(后台填充前已过 AISensitiveRedactor);
//  归档条目名同理。本层不读文件系统、不跑模型 —— 只折叠已有事实。
//

import Foundation

nonisolated struct AIFileSuggestion: Equatable, Codable, Sendable {
    /// 一句话定性(**结构化**,App 渲染本地化文案)。关联值是已脱敏、可直接展示的专有名词 / token。
    nonisolated enum Headline: Equatable, Codable, Sendable {
        /// 文档 / markdown:「关于 <topic> 的文档」。`topic` 来自后台短摘要 / 大纲首条,缺失 → 泛化「文档」。
        case document(topic: String?)
        /// 发布物(校验 + 签名 / 安装包齐全的成品)。
        case releaseArtifact
        /// 校验 / 签名文件(SHA256SUMS / *.asc …)。
        case integrityFile
        /// 归档:「N 个文件 · 已加密」。`entryCount` 可空(清单还没预解析到)。
        case archive(entryCount: Int?, encrypted: Bool)
        /// 归档内容感知:「也许你要的是包里的 <entryName>」。
        case archiveWantsEntry(name: String)
        /// 源码:`language` 是扩展名 token(swift/py/ts…),App 映射成显示名。
        case sourceCode(language: String?)
        /// 配置:「<subject> 的配置」,subject 可空 → 泛化「配置文件」。
        case config(subject: String?)
        /// 媒体:`kind` ∈ image / video / audio。
        case media(kind: String)
        /// 安装包 / 磁盘镜像 / 应用。
        case installer
        /// 疑似重复:「和 <ofName> 像是同一份」。
        case duplicate(ofName: String)
    }

    /// 抽屉里的快捷动作(**结构化**,App 映射到真实操作 + 本地化标题)。关联值是已脱敏的目标名。
    nonisolated enum Action: Equatable, Codable, Sendable {
        /// 展开更完整的本地摘要(大纲 + 几句),不动文件本体。
        case viewSummary
        /// 打包压缩(多文件折叠组也用它)。
        case compress
        /// 提取归档内某条目。
        case extractEntry(name: String)
        /// 预览归档内某条目(不解压)。
        case previewEntry(name: String)
        /// 测试归档完整性。
        case test
        /// 验证签名(.szs / .siz / .asc)。
        case verifySignature
        /// 推荐用更合适的 App 打开(`appName` 已脱敏)。
        case openWith(appName: String)
        /// 与疑似同源文件对比。
        case compareDuplicate(ofName: String)
        /// 在 Finder 中显示。
        case revealInFinder
    }

    let headline: Headline
    /// 次要说明 —— 仅承载**已脱敏的专有名词**(大纲第二条 / 归档压缩方法等),App 拼进整句。多数情况 nil。
    let detail: String?
    let actions: [Action]
    /// 来源标记(稳定 token,给抽屉角标 / DevTools):`model`(含端上模型短摘要)> `prefetched`(后台已预解析
    /// 结构信号)> `instant`(仅即时类型判定)。最强者在前。
    let provenanceTokens: [String]

    /// 归档清单事实(后台预解析 / 清单缓存派生),喂给建议生成。
    nonisolated struct ArchiveFacts: Equatable, Codable, Sendable {
        let entryCount: Int?
        let encrypted: Bool
        /// 「也许你要的是包里的 X」—— 后台按近期意图挑出的显著条目名(已脱敏),可空。
        let notableEntryName: String?
        init(entryCount: Int? = nil, encrypted: Bool = false, notableEntryName: String? = nil) {
            self.entryCount = entryCount
            self.encrypted = encrypted
            self.notableEntryName = notableEntryName
        }
    }

    /// 从一个文件的可用事实**确定性**组装建议。没什么有用的可说(普通未知 / 二进制 / 裸文件夹且无任何增强)
    /// 时返回 `nil` —— **不展示空抽屉**。优先级固定 → 同输入同输出。
    ///
    /// - Parameters:
    ///   - type: 文件类型;`nil` 时按 `fileName` 即时分类(`AIFileType.classify`)。
    ///   - roleTags: 角色标签(后台已派生);`nil`/空时按 `fileName` 即时派生。
    ///   - contentSummary: 后台内容预解析(已脱敏)。`shortSummary`(模型)优先,退回 `headings.first`。
    ///   - archive: 归档清单事实(仅归档类有意义)。
    ///   - duplicateOfDisplayName: 疑似同源文件的展示名(已脱敏),非空即出「重复」建议。
    ///   - betterOpenAppName: 更合适的打开 App 名(已脱敏),非空给可打开类型追加 openWith。
    static func make(
        fileName: String,
        isDirectory: Bool,
        byteSize: Int64? = nil,
        type explicitType: AIFileType? = nil,
        roleTags explicitRoles: [String]? = nil,
        contentSummary: AIFileContentSummary? = nil,
        archive: ArchiveFacts? = nil,
        duplicateOfDisplayName: String? = nil,
        betterOpenAppName: String? = nil
    ) -> AIFileSuggestion? {
        let type = explicitType ?? AIFileType.classify(fileName: fileName, isDirectory: isDirectory)
        let roles = explicitRoles ?? AIFileType.roleTags(fileName: fileName, isDirectory: isDirectory, type: type)
        let roleSet = Set(roles)

        let provenance = provenanceTokens(contentSummary: contentSummary)
        let docTopic = documentTopic(from: contentSummary)

        // 1) 疑似重复优先(最强信号,跨类型)。
        if let dup = nonEmpty(duplicateOfDisplayName) {
            return AIFileSuggestion(headline: .duplicate(ofName: dup), detail: nil,
                                    actions: [.compareDuplicate(ofName: dup), .revealInFinder],
                                    provenanceTokens: provenance)
        }

        // 2) 归档:条目数 / 加密 / 「也许你要包里的 X」+ 提取 / 测试 / 验签。
        if type == .archive {
            var actions: [Action] = []
            if let want = nonEmpty(archive?.notableEntryName) {
                actions.append(.extractEntry(name: want))
                actions.append(.previewEntry(name: want))
            }
            actions.append(.test)
            if roleSet.contains("signed") || ["siz", "szs"].contains((fileName as NSString).pathExtension.lowercased()) {
                actions.append(.verifySignature)
            }
            let headline: Headline = nonEmpty(archive?.notableEntryName).map { Headline.archiveWantsEntry(name: $0) }
                ?? .archive(entryCount: archive?.entryCount, encrypted: archive?.encrypted ?? false)
            return AIFileSuggestion(headline: headline, detail: nil, actions: actions,
                                    provenanceTokens: provenance)
        }

        // 3) 完整性:校验 / 签名文件。
        if type == .checksum || type == .signature || roleSet.contains("integrity-data") {
            return AIFileSuggestion(headline: .integrityFile, detail: nil,
                                    actions: [.verifySignature, .revealInFinder], provenanceTokens: provenance)
        }

        // 4) 发布物角色(校验 + 签名 / 安装包齐全)。
        if roleSet.contains("release") {
            return AIFileSuggestion(headline: .releaseArtifact, detail: nil,
                                    actions: [.verifySignature, .revealInFinder], provenanceTokens: provenance)
        }

        // 5) 文档 / 说明类:document/markdown/text 类型,或 project-doc / release-notes / reference-data 角色。
        let docRoles: Set<String> = ["project-doc", "release-notes", "reference-data", "document"]
        if type == .markdown || type == .text || !roleSet.isDisjoint(with: docRoles) {
            var actions: [Action] = [.viewSummary]
            if let app = nonEmpty(betterOpenAppName) { actions.append(.openWith(appName: app)) }
            return AIFileSuggestion(headline: .document(topic: docTopic),
                                    detail: secondaryHeading(from: contentSummary),
                                    actions: actions, provenanceTokens: provenance)
        }

        // 6) 源码。
        if type == .sourceCode {
            var actions: [Action] = []
            if let app = nonEmpty(betterOpenAppName) { actions.append(.openWith(appName: app)) }
            let lang = nonEmpty((fileName as NSString).pathExtension.lowercased())
            return AIFileSuggestion(headline: .sourceCode(language: lang), detail: nil,
                                    actions: actions, provenanceTokens: provenance)
        }

        // 7) 配置。
        if type == .config {
            var actions: [Action] = []
            if let app = nonEmpty(betterOpenAppName) { actions.append(.openWith(appName: app)) }
            return AIFileSuggestion(headline: .config(subject: nil), detail: nil,
                                    actions: actions, provenanceTokens: provenance)
        }

        // 8) 媒体。
        if type == .image || type == .video || type == .audio {
            return AIFileSuggestion(headline: .media(kind: type.rawValue), detail: nil,
                                    actions: [.compress, .revealInFinder], provenanceTokens: provenance)
        }

        // 9) 安装包 / 镜像 / 应用。
        if type == .diskImage || type == .package || type == .appBundle {
            return AIFileSuggestion(headline: .installer, detail: nil,
                                    actions: [.revealInFinder], provenanceTokens: provenance)
        }

        // 没什么有用的可说 —— 不出空抽屉。
        return nil
    }

    // MARK: - 派生

    /// 文档主题词:模型短摘要优先(已脱敏),退回大纲首条标题;都没有 → nil(App 展示泛化「文档」)。
    private static func documentTopic(from summary: AIFileContentSummary?) -> String? {
        guard let summary else { return nil }
        if let s = nonEmpty(summary.shortSummary) { return s }
        return summary.headings.first.flatMap(nonEmpty)
    }

    /// 次要说明:大纲第二条标题(已脱敏),给抽屉补一行;没有则 nil。
    private static func secondaryHeading(from summary: AIFileContentSummary?) -> String? {
        guard let summary, summary.headings.count >= 2 else { return nil }
        return nonEmpty(summary.headings[1])
    }

    /// 来源标记(最强者在前):有模型短摘要 → model;有结构预解析 → prefetched;否则 instant。
    private static func provenanceTokens(contentSummary: AIFileContentSummary?) -> [String] {
        guard let summary = contentSummary else { return ["instant"] }
        if nonEmpty(summary.shortSummary) != nil { return ["model", "prefetched"] }
        return ["prefetched"]
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

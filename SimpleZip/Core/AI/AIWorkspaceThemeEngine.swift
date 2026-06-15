//
//  AIWorkspaceThemeEngine.swift
//  SimpleZip
//
//  0.4.5 #80 #89:推荐工作区主题的**确定性生成器**(白皮书建议四「动态主题是硬约束」1010-1017 / 「主动主题
//  发现」1068-1090)。
//
//  这是真正的 AI 工作区的来源 —— 按**当前文件夹的真实内容**(项目 marker、发布校验物、混合素材、长期未动大
//  文件)识别**有目的的主题**,标题用真实文件夹名作种子(模型再润色),而不是把活动中心的失败任务 / 最近归档
//  换皮成固定工作区(那已被删),也不是泛泛的「documents in this folder」。
//
//  两层(白皮书硬约束):① 这里的确定性引擎从文件事实识别主题候选 + 指纹(用于「不感兴趣」去重);② 模型
//  (可选,空闲时)把候选重命名 / 排序 / 写分组标题。模型不可用时也能工作,只是名字朴素。
//
//  纯值 + 确定性(`now` 由 App 传入,不取 wall-clock),SwiftPM 可断言。复用 `AIFileSystemFact.roleTags`
//  (文件类型派生)+ `AIAgeFacts`(统一时间语义)+ `AILocationContext`,不重造分类。
//

import Foundation

/// 主题指纹(白皮书 `AIWorkspaceThemeFingerprint`)。用于:① 用户点「不感兴趣」后,下一轮生成必须避开同款主题;
/// ② 判断两次生成是不是「同一个主题刷新」而非新主题。确定性:各分量排序去重,与输入序无关。
nonisolated struct AIWorkspaceThemeFingerprint: Codable, Equatable, Hashable, Sendable {
    let themeTokens: [String]
    let sourceRefHashes: [String]
    let dominantRoleTags: [String]
    let locationKinds: [String]

    init(themeTokens: [String], sourceRefHashes: [String], dominantRoleTags: [String], locationKinds: [String]) {
        self.themeTokens = themeTokens.map { $0.lowercased() }.sorted()
        self.sourceRefHashes = sourceRefHashes.sorted()
        self.dominantRoleTags = Array(Set(dominantRoleTags.map { $0.lowercased() })).sorted()
        self.locationKinds = Array(Set(locationKinds.map { $0.lowercased() })).sorted()
    }

    /// 从主题 token + source refs + 角色 + 位置确定性派生。`sourceRefHashes` 用稳定 64-bit id(非加密)。
    static func make(themeTokens: [String], sourceRefs: [AIContextSourceRef],
                     dominantRoleTags: [String], locationKinds: [String]) -> AIWorkspaceThemeFingerprint {
        AIWorkspaceThemeFingerprint(
            themeTokens: themeTokens,
            sourceRefHashes: sourceRefs.map { AIStableHash.stableID64($0.kind.rawValue + ":" + $0.id) },
            dominantRoleTags: dominantRoleTags,
            locationKinds: locationKinds)
    }
}

nonisolated enum AIWorkspaceThemeEngine {
    /// 从当前文件夹的文件事实确定性识别**有目的的推荐主题**。按优先级:发布校验物 → 项目工作区 → 混合素材
    /// (按文件夹命名)→ 长期未动大文件。只读;不扫描文件系统(事实由 App 侧组装后传入)。返回已排序(命中
    /// 信号多者优先)的候选,每个带指纹。
    static func deterministicThemes(
        from facts: [AIFileSystemFact],
        location: AILocationContext,
        folderDisplayName: String,
        now: Date,
        minGroupSize: Int = 3, staleDays: Int = 90, largeBytes: Int64 = 50_000_000
    ) -> [AIWorkspaceThemeCandidate] {
        let files = facts.filter { !$0.isDirectory }
        guard !files.isEmpty else { return [] }
        let folderToken = folderDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let locationKinds = [location.kind.rawValue]
        var themes: [AIWorkspaceThemeCandidate] = []

        func role(_ tags: [String]) -> String { tags.first ?? "file" }
        func has(role r: String) -> Bool { files.contains { role($0.roleTags) == r } }
        func filesWith(roles rs: Set<String>) -> [AIFileSystemFact] { files.filter { rs.contains(role($0.roleTags)) } }
        let projectMarkers = files.contains { isProjectMarker($0.displayName) }

        // 1) 发布校验物:有校验文件 / 签名,且有归档 / 安装包 → 「发布校验材料」。
        let verifyRoles = filesWith(roles: ["checksum", "signature", "archive", "installer"])
        if (has(role: "checksum") || has(role: "signature")),
           (has(role: "archive") || has(role: "installer")), verifyRoles.count >= 2 {
            themes.append(make(
                idSeed: "release", location: location,
                titleSeed: folderToken.isEmpty ? "release verification materials" : folderToken,
                themeTokens: ["release", "verify"] + location.folderNameTokens,
                facts: verifyRoles,
                scoreSignals: ["release-markers", "count=\(verifyRoles.count)"],
                evidenceLabel: "release verification materials (checksums / signatures / archives)"))
        }

        // 2) 项目工作区:目录是项目根(marker)→ 用真实文件夹名作主题,收纳源码 / 配置 / 文档 / 校验。
        if location.kind == .projectFolder || projectMarkers {
            let projectFiles = filesWith(roles: ["source", "config", "document", "checksum"])
            if projectFiles.count >= 2 {
                themes.append(make(
                    idSeed: "project", location: location,
                    titleSeed: folderToken.isEmpty ? "this project" : folderToken,
                    themeTokens: ["project"] + location.folderNameTokens,
                    facts: projectFiles,
                    scoreSignals: ["project-folder", "count=\(projectFiles.count)"],
                    evidenceLabel: "project working set (source / config / docs)"))
            }
        }

        // 3) 混合素材:文件夹里 ≥minGroupSize 个文件、≥2 种角色,且没被项目主题覆盖 → 按文件夹名整理。
        //    这就是白皮书「论文目录里 doc/ppt/csv/png 进同一工作区」的模式(标题=真实文件夹名,非泛化分类词)。
        let distinctRoles = Set(files.map { role($0.roleTags) })
        let specialCovered = themes.contains { $0.themeTokens.contains("project") || $0.themeTokens.contains("release") }
        if !specialCovered, files.count >= minGroupSize, distinctRoles.count >= 2, !folderToken.isEmpty {
            themes.append(make(
                idSeed: "folder", location: location,
                titleSeed: folderToken,
                themeTokens: ["folder"] + location.folderNameTokens,
                facts: files,
                scoreSignals: ["mixed-content", "roles=\(distinctRoles.count)", "count=\(files.count)"],
                evidenceLabel: "mixed materials in this folder"))
        }

        // 4) 长期未动的大文件(白皮书例:「长期未动的大文件」)。
        let staleLarge = files.filter { fact in
            guard let size = fact.byteSize, size >= largeBytes, let modified = fact.modifiedAt else { return false }
            return AIAgeFacts.make(from: modified, now: now).ageDays >= staleDays
        }
        if staleLarge.count >= minGroupSize {
            themes.append(make(
                idSeed: "stale-large", location: location,
                titleSeed: "long-idle large files",
                themeTokens: ["stale", "large"],
                facts: staleLarge,
                scoreSignals: ["stale-large", "count=\(staleLarge.count)"],
                evidenceLabel: "long-idle large files"))
        }

        return AIWorkspaceCandidateRanker.rankThemes(themes)
    }

    /// 组装一个主题候选(确定性 id 含位置哈希 → 不同文件夹的同类主题互不相同;指纹随附)。
    private static func make(
        idSeed: String, location: AILocationContext, titleSeed: String,
        themeTokens: [String], facts: [AIFileSystemFact], scoreSignals: [String], evidenceLabel: String
    ) -> AIWorkspaceThemeCandidate {
        let refs = facts.map(\.sourceRef)
        let tokens = dedup(themeTokens)
        let roles = dedup(facts.flatMap { $0.roleTags })
        let fingerprint = AIWorkspaceThemeFingerprint.make(
            themeTokens: tokens, sourceRefs: refs, dominantRoleTags: roles,
            locationKinds: [location.kind.rawValue])
        return AIWorkspaceThemeCandidate(
            id: "theme-" + idSeed + "-" + location.pathHash,
            titleSeed: titleSeed,
            themeTokens: tokens,
            sourceRefs: refs,
            scoreSignals: scoreSignals,
            evidence: [AIEvidenceFact(label: evidenceLabel, facts: scoreSignals)],
            fingerprint: fingerprint)
    }

    private static func dedup(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for x in xs where !x.isEmpty && !seen.contains(x) { seen.insert(x); out.append(x) }
        return out
    }

    /// 文件名是否是项目根 marker(小写比较)。
    private static func isProjectMarker(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.hasPrefix("readme") { return true }
        return projectMarkerNames.contains(n)
    }

    private static let projectMarkerNames: Set<String> = [
        "package.swift", "package.json", "cargo.toml", "go.mod", "pyproject.toml",
        "pom.xml", "build.gradle", "makefile", "cmakelists.txt", ".gitignore", "license", "license.md"
    ]
}

extension AIWorkspaceThemeCandidate {
    /// 落成一个推荐工作区(`origin == .recommended`)。确定性 UUID(可复现);`title` 暂用 `titleSeed`,模型
    /// 整理时可改名。`generatedAt` 由 App 传入。query plan 带上主题 token,便于后续召回 / 解释。
    func toRecommendedWorkspace(generatedAt: Date, iconSystemName: String = "sparkles") -> AIWorkspace {
        AIWorkspace(
            id: AIStableHash.deterministicUUID("workspace:" + id),
            origin: .recommended,
            title: titleSeed,
            queryPlan: AIWorkspaceQueryPlan(taskTags: [], keywords: themeTokens),
            iconSystemName: iconSystemName,
            generatedAt: generatedAt)
    }
}

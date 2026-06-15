//
//  AIWorkspaceThemeEngine.swift
//  SimpleZip
//
//  0.4.5 #80 #89:推荐工作区主题的**确定性生成器**(白皮书建议四「生成方式」)。
//
//  这是真正的 AI 工作区的来源 —— 按**当前文件夹的真实内容**(文件角色、体积、年龄)分出主题,而不是把活动
//  中心的失败任务 / 最近归档换皮成固定工作区(那已被删除)。两层:① 这里的确定性引擎从文件事实产候选;
//  ② 模型(可选,空闲时)把候选重命名 / 排序 / 写分组标题。模型不可用时也能工作,只是名字朴素。
//
//  纯值 + 确定性(`now` 由 App 传入,不取 wall-clock),SwiftPM 可断言。复用 `AIFileSystemFact.roleTags`
//  (文件类型派生)+ `AIAgeFacts`(统一时间语义),不重造分类。
//

import Foundation

nonisolated enum AIWorkspaceThemeEngine {
    /// 从当前文件夹的文件事实确定性生成推荐主题候选。按角色分组(每组 ≥ `minGroupSize` 才出主题),外加
    /// 「长期未动的大文件」专题。只读;不扫描文件系统(事实由 App 侧组装后传入)。
    static func deterministicThemes(
        from facts: [AIFileSystemFact], now: Date,
        minGroupSize: Int = 3, staleDays: Int = 90, largeBytes: Int64 = 50_000_000
    ) -> [AIWorkspaceThemeCandidate] {
        var themes: [AIWorkspaceThemeCandidate] = []

        // 1) 按文件角色分组(只取文件,不取目录)。
        var byRole: [String: [AIFileSystemFact]] = [:]
        for fact in facts where !fact.isDirectory {
            byRole[fact.roleTags.first ?? "file", default: []].append(fact)
        }
        for (role, group) in byRole where group.count >= minGroupSize {
            themes.append(AIWorkspaceThemeCandidate(
                id: "theme-role-" + role,
                titleSeed: roleSeed(role),
                themeTokens: [role],
                sourceRefs: group.map(\.sourceRef),
                scoreSignals: ["role=\(role)", "count=\(group.count)"],
                evidence: [AIEvidenceFact(label: "grouped by file role",
                                          facts: ["role=\(role)", "count=\(group.count)"])]))
        }

        // 2) 长期未动的大文件(白皮书例:「长期未动的大文件」)。
        let staleLarge = facts.filter { fact in
            guard !fact.isDirectory, let size = fact.byteSize, size >= largeBytes,
                  let modified = fact.modifiedAt else { return false }
            return AIAgeFacts.make(from: modified, now: now).ageDays >= staleDays
        }
        if staleLarge.count >= minGroupSize {
            themes.append(AIWorkspaceThemeCandidate(
                id: "theme-stale-large",
                titleSeed: "long-idle large files",
                themeTokens: ["stale", "large"],
                sourceRefs: staleLarge.map(\.sourceRef),
                scoreSignals: ["stale-large", "count=\(staleLarge.count)"],
                evidence: [AIEvidenceFact(label: "long-idle large files",
                                          facts: ["count=\(staleLarge.count)", "idle-days>=\(staleDays)"])]))
        }

        // 确定性排序:命中文件数降序,再 id 升序。
        return themes.sorted {
            $0.sourceRefs.count != $1.sourceRefs.count
                ? $0.sourceRefs.count > $1.sourceRefs.count
                : $0.id < $1.id
        }
    }

    /// 角色 → 英文 title 种子(模型可后续 refine 成更自然的名字)。
    private static func roleSeed(_ role: String) -> String {
        switch role {
        case "source": return "source code in this folder"
        case "archive": return "archives in this folder"
        case "document": return "documents in this folder"
        case "image", "media": return "images in this folder"
        case "checksum": return "checksums in this folder"
        case "signature": return "signatures in this folder"
        case "installer": return "installers in this folder"
        case "config": return "config files in this folder"
        default: return "\(role) files in this folder"
        }
    }
}

extension AIWorkspaceThemeCandidate {
    /// 落成一个推荐工作区(`origin == .recommended`)。确定性 UUID(可复现);`title` 暂用 `titleSeed`,模型
    /// 整理时可改名。`generatedAt` 由 App 传入。
    func toRecommendedWorkspace(generatedAt: Date, iconSystemName: String = "sparkles") -> AIWorkspace {
        AIWorkspace(
            id: AIStableHash.deterministicUUID("workspace:" + id),
            origin: .recommended,
            title: titleSeed,
            queryPlan: AIWorkspaceQueryPlan(taskTags: themeTokens),
            iconSystemName: iconSystemName,
            generatedAt: generatedAt)
    }
}

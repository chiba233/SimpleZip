//
//  AIFileSuggestionMapping.swift
//  SimpleZip
//
//  0.4.5 独立 AI 进程:把引擎 `fileSuggestion` pass 的**原始输出**(动作 token 列表 + openWith 序号 + 候选 app)
//  校验并转成结构化建议动作 `[AIFileSuggestedAction]`。前台 App(AIVirtualFolderModelPlanner,经 XPC 引擎)和
//  后台 agent(AIAgentBaker,进程内直调引擎)**共用这一份转换** —— 避免两边各写一份校验逻辑而漂移。
//
//  红线:token 必须在 `allowedSuggestionDescriptors` 词表内、且适用该 kind(file / archive),去重;openWith
//  序号回查候选 app 安全合成(模型只给序号,绝不发明 bundle id)。纯值 + 确定性,SwiftPM 可断言。
//

import Foundation

nonisolated enum AIFileSuggestionMapping {
    /// 校验并转换引擎输出为结构化建议动作。
    /// - actionTokens: 引擎给的动作 token 原串(大小写 / 空白不规范都接受,内部归一)。
    /// - openWithAppNumber: 引擎挑的「推荐打开方式」候选序号(1-based;0 / 越界 = 不推荐)。
    /// - kind: `"file"` / `"archive"`,决定哪些 token 适用。
    /// - candidateOpenApps: App 提供的非默认候选 app(bundleID + 名);序号据此回查。
    static func actions(actionTokens: [String],
                        openWithAppNumber: Int,
                        kind: String,
                        candidateOpenApps apps: [(bundleID: String, name: String)]) -> [AIFileSuggestedAction] {
        var seen = Set<String>()
        let tokens = actionTokens.compactMap { raw -> String? in
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard AIVirtualNodeActionDeriver.allowedSuggestionDescriptors
                .contains(where: { $0.id == t && $0.appliesToKinds.contains(kind) }),
                  seen.insert(t).inserted else { return nil }
            return t
        }
        var actions = tokens.map { AIFileSuggestedAction(token: $0) }
        // 推荐打开方式(只推非默认 app):模型按序号挑;据 bundleID 安全合成动作。
        if !apps.isEmpty, openWithAppNumber >= 1, openWithAppNumber <= apps.count {
            let app = apps[openWithAppNumber - 1]
            actions.append(AIFileSuggestedAction(token: "openWith", payload: app.bundleID, label: app.name))
        }
        return actions
    }
}

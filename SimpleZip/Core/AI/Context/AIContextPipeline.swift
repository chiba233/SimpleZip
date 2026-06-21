//
//  AIContextPipeline.swift
//  SimpleZip
//
//  0.4.5 #80:统一 Core 级 AI Pipeline(白皮书工程补充一·加固 1 + acceptance #1)。
//
//  把 `collect facts -> (privacy gate) -> encode -> compact -> produce request` 串成**固定流程**,让每个业务
//  builder 不再各自手写信封组装、确定性编码、压缩和 source-ref 校验。它**不调用模型**,只产出可直接喂给模型的
//  `AIContextRequest`:受控信封 + 压缩后的 prompt JSON + 允许的 source ref 集合 + 预算消耗。
//
//  分工:
//  - **redact**(脱敏)发生在 facts 进入之前 —— facts 是强类型,各 builder 用 `AISensitiveRedactor` 脱敏后再传入;
//    pipeline 的隐私闸是 `AIContextEnvelope.make` 拒绝 `blockedSensitive`(红线由类型系统兜底)。
//  - **budget**(预算)对候选 / 文本的截断由 builder 用 `AIBudget.cap/sample/clampText` 在 facts 里完成;
//    pipeline 只对最终 prompt 做总额**守卫与度量**(超额是信号,不裁断 JSON —— 裁 JSON 会产出非法结构)。
//  - **validate**:pipeline 暴露 `validate` / `keepingValid`,让 builder 用同一候选集校验模型回传的 ref,
//    不再各处手拼 `AIContextSourceRefValidator`。
//
//  纯值类型 + 确定性,SwiftPM 可断言。
//

import Foundation

/// pipeline 的产物:一次可直接发给模型的受控请求。
nonisolated struct AIContextRequest<Facts: Codable & Equatable & Sendable>: Equatable, Sendable {
    /// 受控信封(经安全工厂构造,绝不含 blockedSensitive)。
    let envelope: AIContextEnvelope<Facts>
    /// 压缩后(或原始,若 < 1.5KB)的确定性 prompt JSON。
    let promptJSON: String
    /// 是否真的压缩了。
    let compacted: Bool
    /// 本次提供的候选 ref 集合 —— 模型回传 ref 必须落在这里。
    let allowedSourceRefs: Set<AIContextSourceRef>
    /// prompt 字符数(调试 / 度量)。
    let charCount: Int
    /// nil = 未提供预算;否则 prompt 是否在 `maxTotalChars` 内(超额 = builder 欠裁,是信号不是错误)。
    let withinBudget: Bool?

    /// 校验模型回传 ref 是否全部在候选集内(空 ref 默认拒绝,边界二)。
    func validate(_ refs: [AIContextSourceRef], emptyPolicy: AIEmptyRefPolicy = .reject) -> Bool {
        AIContextSourceRefValidator.allRefsValid(refs, allowed: allowedSourceRefs, emptyPolicy: emptyPolicy)
    }

    /// 过滤一组带 ref 的模型输出(节点 / 建议 / 动作):只留引用全部有效的;含发明 ref 的整条丢弃。
    func keepingValid<Element>(_ elements: [Element], emptyPolicy: AIEmptyRefPolicy = .reject,
                               refs: (Element) -> [AIContextSourceRef]) -> [Element] {
        AIContextSourceRefValidator.keepingValid(elements, allowed: allowedSourceRefs,
                                                 emptyPolicy: emptyPolicy, refs: refs)
    }
}

/// 固定的 Core 级 AI pipeline。所有 facts builder 走这一个入口产请求,不再各自 new 信封 + 编码 + 压缩 + 校验。
nonisolated enum AIContextPipeline {
    /// 把已采集 / 已脱敏 / 已按预算截断的 facts 折成一次受控请求。
    /// `privacyLevel == .blockedSensitive` 由 `AIContextEnvelope.make` 抛 `AIContextBuildError`(红线兜底)。
    static func makeRequest<Facts>(
        purpose: AIContextPurpose,
        privacyLevel: AIPrivacyLevel,
        mode: AIContextMode = .standardLocalContext,
        facts: Facts,
        omissions: [AIContextOmission] = [],
        sourceRefs: [AIContextSourceRef] = [],
        budget: AIBudget? = nil
    ) throws -> AIContextRequest<Facts> {
        let envelope = try AIContextEnvelope.make(
            purpose: purpose, privacyLevel: privacyLevel, mode: mode,
            facts: facts, omissions: omissions, sourceRefs: sourceRefs)
        let json = try envelope.jsonString()
        let (compactJSON, didCompact) = AICompactContextCodec.compact(json)
        let withinBudget = budget.map { compactJSON.count <= $0.maxTotalChars }
        return AIContextRequest(
            envelope: envelope, promptJSON: compactJSON, compacted: didCompact,
            allowedSourceRefs: Set(sourceRefs), charCount: compactJSON.count, withinBudget: withinBudget)
    }
}

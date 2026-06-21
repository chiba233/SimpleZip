//
//  AIAgentBaker.swift
//  SimpleZipAIAgent
//
//  独立 AI 进程 · **后台真烘焙**:agent 被 launchd 拉起跑完元数据扫描后,在**本进程内直接调端上模型**
//  (`AIPassEngine.run`,不经 XPC —— agent 自己就是引擎宿主),把各模型 pass 的预烘焙数据写回共享派生索引。
//  这才是后台 agent 存在的意义:App 关着时也把「一句话摘要 / 动作建议 / 网页 / 包内 / 包定性…」预烘焙好,
//  App 再开只读缓存。App 开着时归 App 前台烘焙(app/agent 前台锁互斥,不重叠)。
//
//  数据 agent 全自取:`AIIndexerScan.redactedExcerpt` 自己读文件头 + 脱敏,`AIURLCandidateExtractor` 自己跑正则,
//  候选选取走 Core `AIPrereadSelection`,引擎在进程内。校验/转换与 App 前台共用 Core 的 `AIFileSuggestionMapping`。
//
//  红线:只产出受约束字段(摘要文本 / 词表内动作 token / URL 序号回查),绝不删除 / 放行 / 修复;
//  口令 / 密钥 / 加密内容从不进 prompt(脱敏 + 红线门控在 `AIIndexerScan` / 引擎里)。
//  单次 timeout 折进 `deadline`,每个候选前问一次 —— 模型单次生成方差极大(2~34s),到时即停、下轮续。
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AIAgentBaker {
    nonisolated struct Summary: Sendable {
        var fileSummaries = 0
        var urlSuggestions = 0
        var note = ""
    }

    /// 跑一轮后台模型烘焙。返回更新后的索引 + 摘要。门控:AI 建议子开关 + 内容预读 + 端上模型可用。
    @available(macOS 26.0, *)
    static func bake(index: AIFileMemoryIndex,
                     config: AIAgentConfiguration,
                     budget: AIArchivePrefetchBudget,
                     deadline: Date,
                     log: (String) -> Void) async -> (index: AIFileMemoryIndex, summary: Summary) {
        var index = index
        var summary = Summary()

        guard config.aiSuggestionEnabled else { summary.note = "AI 建议子开关关 → 不烘焙"; log(summary.note); return (index, summary) }
        guard config.contentPrereadEnabled else { summary.note = "内容预读关 → 无摘要素材,不烘焙"; log(summary.note); return (index, summary) }
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            summary.note = "端上模型不可用 → 不烘焙"; log(summary.note); return (index, summary)
        }
        #else
        summary.note = "本进程无 FoundationModels → 不烘焙"; log(summary.note); return (index, summary)
        #endif

        let lang = config.languageName
        let now = Date()
        // 后台 agent 按**时间锁(deadline)**跑,**不套用前台「每轮 N 个候选」的上限** —— 选全部合格(高价值在前),
        // 循环到 deadline 为止;没跑完的下次 launchd 拉起接着烘(已烘的 shortSummary 非空,select 自动跳过 → 渐进覆盖)。
        let all = max(1, index.records.count)

        // —— Pass ①:文件一句话摘要 + 动作建议(fileSuggestion)。候选已有内容预读摘要素材、缺模型摘要。——
        // 高价值(近阈值)在前,其后接阈值下的(空闲长尾);合起来 = 全部可总结文件,按 deadline 逐个烘。
        var fileCandidates = AIPrereadSelection.selectForModelSuggestion(records: index.records, budget: all, now: now)
        fileCandidates += AIPrereadSelection.selectForIdleSummary(records: index.records, budget: all, now: now)
        log("烘焙 fileSuggestion:候选 \(fileCandidates.count)(按时间锁逐个烘,非每轮上限)")
        for rec in fileCandidates {
            if Date() >= deadline { log("到时,停在 fileSuggestion"); summary.note = "超时(部分完成)"; return (index, summary) }
            guard let path = rec.path, let cs = rec.contentSummary,
                  FileManager.default.fileExists(atPath: path) else { log("  跳过 \(rec.fileName)(无摘要素材 / 文件不在)"); continue }
            let url = URL(fileURLWithPath: path)
            guard let excerpt = AIIndexerScan.redactedExcerpt(url: url, fileName: rec.fileName) else {
                log("  跳过 \(rec.fileName)(重读脱敏头部为空 —— 二进制 / 无权限 / 红线)"); continue
            }
            let kind = rec.type == .archive ? "archive" : "file"
            let input = FileSuggestionInput(
                fileName: rec.fileName, kind: kind, roleTags: rec.roleTags,
                languageHint: cs.languageHint, headings: cs.headings, fieldNames: cs.fieldNames,
                excerpt: excerpt, candidateOpenApps: [], discouragedTokens: [])
            log("  烘焙摘要 → \(rec.fileName) …")
            let out: AIPassFileSuggestionOutput
            do { out = try await runPass(.fileSuggestion, input, AIPassFileSuggestionOutput.self, lang) }
            catch { log("  跳过 \(rec.fileName)(引擎失败:\(error))"); continue }
            let actions = AIFileSuggestionMapping.actions(
                actionTokens: out.actions, openWithAppNumber: out.openWithAppNumber, kind: kind, candidateOpenApps: [])
            let clean = out.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty || !actions.isEmpty else { log("  跳过 \(rec.fileName)(模型空产出)"); continue }
            let updated = cs.withModelSuggestion(summary: clean.isEmpty ? nil : clean, actions: actions)
            index = index.updatingRecord(id: rec.id) { $0.withContentSummary(updated) }
            summary.fileSummaries += 1
            log("  摘要 ✓ \(rec.fileName):\(clean.isEmpty ? "(仅动作)" : clean)")
        }

        // —— Pass ②:文本内真实 URL「打开网页」(urlOpenSuggestion)。agent 自己读头 + 正则抽 URL,模型只选序号。——
        let urlCandidates = AIPrereadSelection.selectForURLSuggestion(records: index.records, budget: all, now: now)
        log("烘焙 urlOpenSuggestion:候选 \(urlCandidates.count)(按时间锁逐个烘)")
        for rec in urlCandidates {
            if Date() >= deadline { log("到时,停在 urlOpenSuggestion"); summary.note = "超时(部分完成)"; return (index, summary) }
            guard let path = rec.path, FileManager.default.fileExists(atPath: path) else { continue }
            let excerpt = AIIndexerScan.redactedExcerpt(url: URL(fileURLWithPath: path), fileName: rec.fileName)
            guard let excerpt else { continue }
            let urls = AIURLCandidateExtractor.extract(from: excerpt, limit: 12)
            guard !urls.isEmpty else { continue }
            // 确定性高价值域名 fast-path:命中直接写,跳过模型。
            if let fast = urls.first(where: AIURLCandidateExtractor.isHighValueURL) {
                index = applyURL(index, recordID: rec.id, url: fast)
                summary.urlSuggestions += 1
                continue
            }
            guard let pick = try? await runPass(
                .urlOpenSuggestion, URLOpenSuggestionInput(fileName: rec.fileName, roleTags: rec.roleTags, urls: urls),
                AIPassIntOutput.self, lang), urls.indices.contains(pick.number) else { continue }
            index = applyURL(index, recordID: rec.id, url: urls[pick.number])
            summary.urlSuggestions += 1
        }

        summary.note = "OK · 摘要 \(summary.fileSummaries) · 网页 \(summary.urlSuggestions)"
        return (index, summary)
    }

    /// URL 建议回填(与 store.applyURLOpenSuggestion 同语义:singleton urlOpen 动作,合并进现有 / 新建 url-open 摘要)。
    private static func applyURL(_ index: AIFileMemoryIndex, recordID: String, url: String) -> AIFileMemoryIndex {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return index }
        let label = AIURLCandidateExtractor.webPageLabel(for: clean)
        let action = AIFileSuggestedAction(token: "urlOpen", payload: clean, label: label.isEmpty ? nil : label)
        return index.updatingRecord(id: recordID) { rec in
            let base = rec.contentSummary ?? AIFileContentSummary(mode: "url-open")
            return rec.withContentSummary(base.mergingSingletonAction(action, replacingToken: "urlOpen"))
        }
    }

    @available(macOS 26.0, *)
    private static func runPass<I: Encodable, O: Decodable>(
        _ kind: AIPassKind, _ input: I, _ output: O.Type, _ languageName: String) async throws -> O {
        let data = try await AIPassEngine.run(
            kind: kind.rawValue, inputJSON: JSONEncoder().encode(input), languageName: languageName)
        return try JSONDecoder().decode(O.self, from: data)
    }
}

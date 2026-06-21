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
//  归档清单读共享 `ArchiveListingCacheStore`(经 `appDomainDefaults` 读对域),候选选取走 Core `AIPrereadSelection`,
//  引擎在进程内。校验/转换与 App 前台共用 Core 的 `AIFileSuggestionMapping`。
//
//  **时间锁,非前台每轮上限**:后台一次性时间预算(deadline)切成每 pass 一片(防某个 pass 独占让别的饿死);
//  每 pass 选**全部**合格候选(高价值在前)、循环到自己那片到时为止,没烘完的下次 launchd 拉起接着烘
//  (已烘的 select 自动跳 → 渐进覆盖)。
//
//  红线:只产出受约束字段(摘要文本 / 词表内动作 token / URL·条目序号回查),绝不删除 / 放行 / 修复;
//  口令 / 密钥 / 加密内容从不进 prompt(脱敏 + 红线门控在 `AIIndexerScan` / 引擎里)。
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AIAgentBaker {
    nonisolated struct Summary: Sendable {
        var fileSummaries = 0
        var urlSuggestions = 0
        var archiveEntries = 0
        var archiveKinds = 0
        var note = ""
        var produced: Int { fileSummaries + urlSuggestions + archiveEntries + archiveKinds }
    }

    /// 每 pass 的最小时间片下限(秒)——避免 pass 数多时每片太短连一次生成都跑不完。
    private static let minPassSeconds: TimeInterval = 20
    /// 当前烘焙的 pass 数(切时间片用;加 pass 时同步 +1)。
    private static let plannedPassCount = 4

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
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            summary.note = "端上模型不可用 → 不烘焙"; log(summary.note); return (index, summary)
        }
        #else
        summary.note = "本进程无 FoundationModels → 不烘焙"; log(summary.note); return (index, summary)
        #endif

        let lang = config.languageName
        // 把整段时间预算切成每 pass 一片(提前做完的片,时间自然顺延给下一 pass —— 下一 pass 的片从当下算)。
        let window = max(1, deadline.timeIntervalSince(Date()))
        let perPass = max(minPassSeconds, window / Double(plannedPassCount))
        func slice() -> Date { min(deadline, Date().addingTimeInterval(perPass)) }

        if config.contentPrereadEnabled {
            let r1 = await bakeFileSuggestions(index, lang: lang, passDeadline: slice(), log: log)
            index = r1.index; summary.fileSummaries = r1.count
            let r2 = await bakeURLSuggestions(index, lang: lang, passDeadline: slice(), log: log)
            index = r2.index; summary.urlSuggestions = r2.count
        } else {
            log("内容预读关 → 跳过文件摘要 / 网页烘焙")
        }

        // 归档类:读共享归档清单缓存(App 开归档时填),据清单烘「包内可选条目 / 这是什么包」。
        let listings = ArchiveListingCacheStore(defaults: AIAgentConfiguration.appDomainDefaults()).loadAll()
        let listingByPath = Dictionary(listings.map { ($0.archivePath, $0) }, uniquingKeysWith: { first, _ in first })
        if listingByPath.isEmpty {
            log("无归档清单缓存 → 跳过包内 / 包定性烘焙")
        } else {
            let r3 = await bakeArchiveEntryPicks(index, listingByPath: listingByPath, lang: lang, passDeadline: slice(), log: log)
            index = r3.index; summary.archiveEntries = r3.count
            let r4 = await bakeArchiveKindGuesses(index, listingByPath: listingByPath, lang: lang, passDeadline: slice(), log: log)
            index = r4.index; summary.archiveKinds = r4.count
        }

        summary.note = "OK · 摘要 \(summary.fileSummaries) · 网页 \(summary.urlSuggestions) · 包内 \(summary.archiveEntries) · 包定性 \(summary.archiveKinds)"
        return (index, summary)
    }

    // MARK: - Pass ①:文件一句话摘要 + 动作建议(fileSuggestion)

    @available(macOS 26.0, *)
    private static func bakeFileSuggestions(_ index: AIFileMemoryIndex, lang: String, passDeadline: Date,
                                            log: (String) -> Void) async -> (index: AIFileMemoryIndex, count: Int) {
        var index = index
        var count = 0
        let now = Date()
        let all = max(1, index.records.count)
        // 高价值(近阈值)在前,其后接阈值下的(空闲长尾);合起来 = 全部可总结文件。
        var candidates = AIPrereadSelection.selectForModelSuggestion(records: index.records, budget: all, now: now)
        candidates += AIPrereadSelection.selectForIdleSummary(records: index.records, budget: all, now: now)
        log("烘焙 fileSuggestion:候选 \(candidates.count)(按时间锁逐个烘)")
        for rec in candidates {
            if Date() >= passDeadline { log("  fileSuggestion 本片到时,停"); break }
            guard let path = rec.path, let cs = rec.contentSummary,
                  FileManager.default.fileExists(atPath: path) else { continue }
            guard let excerpt = AIIndexerScan.redactedExcerpt(url: URL(fileURLWithPath: path), fileName: rec.fileName) else { continue }
            let kind = rec.type == .archive ? "archive" : "file"
            let input = FileSuggestionInput(
                fileName: rec.fileName, kind: kind, roleTags: rec.roleTags,
                languageHint: cs.languageHint, headings: cs.headings, fieldNames: cs.fieldNames,
                excerpt: excerpt, candidateOpenApps: [], discouragedTokens: [])
            guard let out = try? await runPass(.fileSuggestion, input, AIPassFileSuggestionOutput.self, lang) else { continue }
            let actions = AIFileSuggestionMapping.actions(
                actionTokens: out.actions, openWithAppNumber: out.openWithAppNumber, kind: kind, candidateOpenApps: [])
            let clean = out.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty || !actions.isEmpty else { continue }
            index = index.updatingRecord(id: rec.id) { $0.withContentSummary(cs.withModelSuggestion(summary: clean.isEmpty ? nil : clean, actions: actions)) }
            count += 1
            log("  摘要 ✓ \(rec.fileName):\(clean.isEmpty ? "(仅动作)" : clean)")
        }
        return (index, count)
    }

    // MARK: - Pass ②:文本内真实 URL「打开网页」(urlOpenSuggestion)

    @available(macOS 26.0, *)
    private static func bakeURLSuggestions(_ index: AIFileMemoryIndex, lang: String, passDeadline: Date,
                                           log: (String) -> Void) async -> (index: AIFileMemoryIndex, count: Int) {
        var index = index
        var count = 0
        let candidates = AIPrereadSelection.selectForURLSuggestion(records: index.records, budget: max(1, index.records.count), now: Date())
        log("烘焙 urlOpenSuggestion:候选 \(candidates.count)")
        for rec in candidates {
            if Date() >= passDeadline { break }
            guard let path = rec.path, FileManager.default.fileExists(atPath: path),
                  let excerpt = AIIndexerScan.redactedExcerpt(url: URL(fileURLWithPath: path), fileName: rec.fileName) else { continue }
            let urls = AIURLCandidateExtractor.extract(from: excerpt, limit: 12)
            guard !urls.isEmpty else { continue }
            if let fast = urls.first(where: AIURLCandidateExtractor.isHighValueURL) {
                index = applyURL(index, recordID: rec.id, url: fast); count += 1; continue
            }
            guard let pick = try? await runPass(
                .urlOpenSuggestion, URLOpenSuggestionInput(fileName: rec.fileName, roleTags: rec.roleTags, urls: urls),
                AIPassIntOutput.self, lang), urls.indices.contains(pick.number) else { continue }
            index = applyURL(index, recordID: rec.id, url: urls[pick.number]); count += 1
        }
        return (index, count)
    }

    // MARK: - Pass ③:包内可选条目(archiveEntryPicks,据已缓存清单)

    @available(macOS 26.0, *)
    private static func bakeArchiveEntryPicks(_ index: AIFileMemoryIndex,
                                              listingByPath: [String: ArchiveListingCacheEntry],
                                              lang: String, passDeadline: Date,
                                              log: (String) -> Void) async -> (index: AIFileMemoryIndex, count: Int) {
        var index = index
        var count = 0
        let picks = index.records.filter { rec in
            rec.type == .archive && rec.contentSummary?.mode != "archive-entries" && rec.path != nil
        }
        log("烘焙 archiveEntryPicks:归档 \(picks.count)")
        for rec in picks {
            if Date() >= passDeadline { break }
            guard let path = rec.path,
                  let entry = listingByPath[ArchiveListingCacheStore.canonicalPath(for: URL(fileURLWithPath: path))],
                  entry.fileEntryCount > 0 else { continue }
            let paths = entry.filePaths(limit: 50)
            guard !paths.isEmpty else {
                index = applyArchiveEntries(index, recordID: rec.id, actions: []); continue   // 空 = 标记已评估
            }
            guard let out = try? await runPass(
                .archiveEntryPicks, ArchiveEntryPicksInput(archiveName: rec.fileName, entryPaths: paths),
                AIPassIntListOutput.self, lang) else { continue }
            let actions = out.numbers.compactMap { idx -> AIFileSuggestedAction? in
                guard paths.indices.contains(idx - 1) else { return nil }
                let p = paths[idx - 1]
                return AIFileSuggestedAction(token: "revealArchiveEntry", payload: p, label: (p as NSString).lastPathComponent)
            }
            index = applyArchiveEntries(index, recordID: rec.id, actions: actions)
            count += 1
            log("  包内 ✓ \(rec.fileName):\(actions.count) 条")
        }
        return (index, count)
    }

    // MARK: - Pass ④:归档定性「这是什么包」(archiveKindGuess,据已缓存清单)

    @available(macOS 26.0, *)
    private static func bakeArchiveKindGuesses(_ index: AIFileMemoryIndex,
                                               listingByPath: [String: ArchiveListingCacheEntry],
                                               lang: String, passDeadline: Date,
                                               log: (String) -> Void) async -> (index: AIFileMemoryIndex, count: Int) {
        var index = index
        var count = 0
        let picks = index.records.filter { rec in
            rec.type == .archive && rec.contentSummary?.action(forToken: "archiveKind") == nil && rec.path != nil
        }
        log("烘焙 archiveKindGuess:归档 \(picks.count)")
        for rec in picks {
            if Date() >= passDeadline { break }
            guard let path = rec.path,
                  let entry = listingByPath[ArchiveListingCacheStore.canonicalPath(for: URL(fileURLWithPath: path))],
                  !entry.entries.isEmpty else { continue }
            let entries = entry.entries.compactMap { cached -> ArchiveKindGuessInput.Entry? in
                let name = cached.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return name.isEmpty ? nil : ArchiveKindGuessInput.Entry(name: name, isDirectory: cached.isDirectory)
            }
            guard !entries.isEmpty else {
                index = applyArchiveKind(index, recordID: rec.id, summary: nil, toolTokens: []); continue
            }
            guard let guess = try? await runPass(
                .archiveKindGuess, ArchiveKindGuessInput(archiveName: rec.fileName, entries: entries),
                AIPassArchiveKindOutput.self, lang) else { continue }
            index = applyArchiveKind(index, recordID: rec.id, summary: guess.summary, toolTokens: guess.toolTokens)
            count += 1
            log("  包定性 ✓ \(rec.fileName):\(guess.summary)")
        }
        return (index, count)
    }

    // MARK: - 缓存写(与 AIBackgroundIndexStore 的 apply* 同语义,纯 Core 值类型 op)

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

    private static func applyArchiveEntries(_ index: AIFileMemoryIndex, recordID: String,
                                            actions: [AIFileSuggestedAction]) -> AIFileMemoryIndex {
        index.updatingRecord(id: recordID) { rec in
            let base = rec.contentSummary ?? AIFileContentSummary(mode: "archive-entries")
            return rec.withContentSummary(base.mergingArchiveEntryActions(actions))
        }
    }

    private static func applyArchiveKind(_ index: AIFileMemoryIndex, recordID: String,
                                         summary: String?, toolTokens: [String]) -> AIFileMemoryIndex {
        let clean = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSummary = clean?.isEmpty == false
        let allowed: Set<String> = ["inspect", "test", "hash", "convert", "security"]
        var seen = Set<String>()
        let toolActions = toolTokens.filter { allowed.contains($0) && seen.insert($0).inserted }.map { AIFileSuggestedAction(token: $0) }
        let marker = AIFileSuggestedAction(token: "archiveKind")
        return index.updatingRecord(id: recordID) { rec in
            let base = rec.contentSummary ?? AIFileContentSummary(mode: "archive-kind")
            let withTools = base.withModelSuggestion(summary: hasSummary ? clean : nil, actions: toolActions)
            return rec.withContentSummary(withTools.mergingSingletonAction(marker, replacingToken: "archiveKind", shortSummaryIfEmpty: nil))
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

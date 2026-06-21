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

import CryptoKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AIAgentBaker {
    nonisolated struct Summary: Sendable {
        var fileSummaries = 0
        var urlSuggestions = 0
        var diskImages = 0
        var archiveEntries = 0
        var archiveKinds = 0
        var inlineChecks = 0
        var toolbarRankings = 0
        var folderGroups = 0
        var organizes = 0
        var workbench = 0
        var note = ""
        var produced: Int { fileSummaries + urlSuggestions + diskImages + archiveEntries + archiveKinds + inlineChecks + toolbarRankings + folderGroups + organizes + workbench }
    }

    /// 每 pass 的最小时间片下限(秒)——避免 pass 数多时每片太短连一次生成都跑不完。
    private static let minPassSeconds: TimeInterval = 20
    /// 当前烘焙的 pass 数(切时间片用;加 pass 时同步 +1)。
    private static let plannedPassCount = 11

    /// 跑一轮后台模型烘焙。返回更新后的索引 + 摘要。门控:AI 建议子开关 + 内容预读 + 端上模型可用。
    /// `derived`:派生数据存储(工具栏排序缓存等不在 index 里的派生数据写它)。
    @available(macOS 26.0, *)
    static func bake(index: AIFileMemoryIndex,
                     config: AIAgentConfiguration,
                     budget: AIArchivePrefetchBudget,
                     deadline: Date,
                     derived: AIDerivedDataStore,
                     log: (String) -> Void) async -> (index: AIFileMemoryIndex, summary: Summary) {
        var index = index
        var summary = Summary()

        guard config.aiSuggestionEnabled else { summary.note = "AI 建议子开关关 → 不烘焙"; log(summary.note); return (index, summary) }

        let lang = config.languageName
        // 把整段时间预算切成每 pass 一片(提前做完的片,时间自然顺延给下一 pass —— 下一 pass 的片从当下算)。
        let window = max(1, deadline.timeIntervalSince(Date()))
        let perPass = max(minPassSeconds, window / Double(plannedPassCount))
        func slice() -> Date { min(deadline, Date().addingTimeInterval(perPass)) }

        // pending 只读自动检查(hash / test)是**确定性**的(不调模型)→ 先跑,模型不可用也照做。
        let rc = await bakePendingChecks(index, passDeadline: slice(), log: log)
        index = rc.index; summary.inlineChecks = rc.count

        // 模型可用性门控:只挡下面的**模型** pass(确定性检查已在上面跑过)。
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            summary.note = "端上模型不可用 → 只跑确定性检查(\(summary.inlineChecks))"; log(summary.note); return (index, summary)
        }
        #else
        summary.note = "本进程无 FoundationModels → 只跑确定性检查(\(summary.inlineChecks))"; log(summary.note); return (index, summary)
        #endif

        if config.contentPrereadEnabled {
            let r1 = await bakeFileSuggestions(index, lang: lang, passDeadline: slice(), log: log)
            index = r1.index; summary.fileSummaries = r1.count
            let r2 = await bakeURLSuggestions(index, lang: lang, passDeadline: slice(), log: log)
            index = r2.index; summary.urlSuggestions = r2.count
            let r5 = await bakeDiskImageSuggestions(index, lang: lang, passDeadline: slice(), log: log)
            index = r5.index; summary.diskImages = r5.count
        } else {
            log("内容预读关 → 跳过文件摘要 / 网页 / 装App 烘焙")
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

        // 工具栏动作排序(建议七 Phase2):文件级(AI 建议 list 重要文件)+ 类型级(按后缀)→ 派生缓存(不进 index)。
        summary.toolbarRankings = await bakeToolbarRanking(index, derived: derived, lang: lang, passDeadline: slice(), log: log)
        // 文件夹「成组建议」/「整理进新文件夹」:据同文件夹的多文件让模型成组 / 圈一簇进新文件夹 → 派生缓存。
        summary.folderGroups = await bakeFolderGroups(index, derived: derived, lang: lang, passDeadline: slice(), log: log)
        summary.organizes = await bakeOrganize(index, derived: derived, lang: lang, passDeadline: slice(), log: log)
        // pending 安全 / 发布包检测(确定性分析 + 仅异常时模型润色一句话;只读红线)。
        let rsi = await bakePendingSecurityInspect(index, lang: lang, passDeadline: slice(), log: log)
        index = rsi.index; summary.inlineChecks += rsi.count
        // 活动中心工作台:读 App 投影的任务记录,烘 chip 排序 / 真建议命名 / 需处理解读 / 失败解释。
        summary.workbench = await bakeWorkbench(derived: derived, lang: lang, passDeadline: slice(), log: log)

        summary.note = "OK · 摘要 \(summary.fileSummaries) · 网页 \(summary.urlSuggestions) · 装App \(summary.diskImages) · 包内 \(summary.archiveEntries) · 包定性 \(summary.archiveKinds) · 检查 \(summary.inlineChecks) · 工具栏序 \(summary.toolbarRankings) · 文件组 \(summary.folderGroups) · 整理 \(summary.organizes) · 工作台 \(summary.workbench)"
        return (index, summary)
    }

    // MARK: - Pass ⑤:磁盘镜像「拖到应用程序」(diskImageInstallSuggestion;7zz 只读 peek 不挂载)

    @available(macOS 26.0, *)
    private static func bakeDiskImageSuggestions(_ index: AIFileMemoryIndex, lang: String, passDeadline: Date,
                                                 log: (String) -> Void) async -> (index: AIFileMemoryIndex, count: Int) {
        var index = index
        var count = 0
        let candidates = AIPrereadSelection.selectDiskImagesForSuggestion(records: index.records, budget: max(1, index.records.count), now: Date())
        log("烘焙 diskImageInstallSuggestion:候选 \(candidates.count)")
        for rec in candidates {
            if Date() >= passDeadline { break }
            guard let path = rec.path, FileManager.default.fileExists(atPath: path) else { continue }
            // 7zz 只读 peek(空口令;加密 / 不可读 dmg 抛错 → 当作无 App 标记已评估,绝不挂载、绝不弹密码)。
            let listed = try? await SevenZipBackend.list(URL(fileURLWithPath: path))
            let appNames = listed.map { AIPrereadSelection.topAppBundleNames(in: $0) } ?? []
            log("  peek \(rec.fileName):\(listed == nil ? "7zz 失败/加密/不可读" : "7zz 列出 \(listed!.count) 条 · \(appNames.count) app")")
            guard !appNames.isEmpty else {
                index = applyDiskImage(index, recordID: rec.id, summary: nil, appName: nil); continue   // 无 .app → 标记已评估
            }
            guard let out = try? await runPass(
                .diskImageInstallSuggestion, DiskImageSuggestionInput(dmgName: rec.fileName, appNames: appNames),
                AIPassDiskImageOutput.self, lang) else { continue }
            index = applyDiskImage(index, recordID: rec.id,
                                   summary: out.summary.isEmpty ? nil : out.summary,
                                   appName: out.suggest ? appNames.first : nil)
            count += 1
            log("  装App ✓ \(rec.fileName):\(out.suggest ? (appNames.first ?? "") : "(不建议)")")
        }
        return (index, count)
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

    // MARK: - Pass ⑥:pending 只读自动检查(hash / test;确定性,不调模型)

    /// 执行 App 排好的 pending 队列里的 hash / test(security / inspect 留给前台 / 后续)。读共享队列、逐个执行
    /// (sha256 用 CryptoKit 流式;test 用 ArchiveService.test 空口令)、写内联结果到索引、mark done/failed、回存队列。
    private static func bakePendingChecks(_ index: AIFileMemoryIndex, passDeadline: Date,
                                          log: (String) -> Void) async -> (index: AIFileMemoryIndex, count: Int) {
        var index = index
        var count = 0
        let defaults = AIAgentConfiguration.appDomainDefaults()
        guard let data = defaults.data(forKey: AppPreferences.Key.aiPendingChecksData),
              var queue = try? JSONDecoder().decode(AIPendingCheckQueue.self, from: data) else {
            return (index, 0)
        }
        let pending = queue.checks
            .filter { $0.status == .pending && ($0.behavior == .hash || $0.behavior == .test) }
            .sorted { $0.queuedAt < $1.queuedAt }
        guard !pending.isEmpty else { return (index, 0) }
        log("烘焙 pendingChecks(hash/test):待执行 \(pending.count)")
        for check in pending {
            if Date() >= passDeadline { break }
            guard FileManager.default.fileExists(atPath: check.path),
                  let rec = index.records.first(where: { $0.path == check.path }) else {
                queue.mark(id: check.id, status: .failed, executedAt: Date()); continue
            }
            let url = URL(fileURLWithPath: check.path)
            do {
                let text: String
                switch check.behavior {
                case .hash: text = try sha256(for: url)
                case .test: try await ArchiveService.test(url, password: ""); text = L10n.text("aiWorkspace.inlineTest.passed")
                default: continue
                }
                let base = rec.contentSummary ?? AIFileContentSummary(mode: "inline-result")
                if base.inlineResults[check.behavior.rawValue] != text {
                    index = index.updatingRecord(id: rec.id) { $0.withContentSummary(base.withInlineResult(token: check.behavior.rawValue, text: text)) }
                }
                queue.mark(id: check.id, status: .done, executedAt: Date())
                count += 1
                log("  检查 ✓ \(check.behavior.rawValue) · \(rec.fileName)")
            } catch {
                // 加密 / 损坏 / 需口令 → 记失败(同指纹不再重排,文件改了才重试),不写假结果。
                queue.mark(id: check.id, status: .failed, executedAt: Date())
            }
        }
        if let out = try? JSONEncoder().encode(queue) { defaults.set(out, forKey: AppPreferences.Key.aiPendingChecksData) }
        return (index, count)
    }

    /// 文件 SHA-256(CryptoKit 流式,与 App HashService.sha256 输出一致:小写 hex)。agent 内复刻避免依赖 App target 的 HashService。
    private static func sha256(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Pass ⑦:工具栏动作排序(建议七 Phase2;文件级 + 类型级 → AIToolbarRanking 派生缓存)

    @available(macOS 26.0, *)
    private static func bakeToolbarRanking(_ index: AIFileMemoryIndex, derived: AIDerivedDataStore,
                                           lang: String, passDeadline: Date,
                                           log: (String) -> Void) async -> Int {
        var ranking: AIToolbarRanking = {
            guard let data = derived.data(forKey: AIToolbarRanking.derivedKey),
                  let r = try? JSONDecoder().decode(AIToolbarRanking.self, from: data) else { return AIToolbarRanking() }
            return r
        }()
        var count = 0
        var changed = false

        // 文件级:AI 建议 list 里的「重要」文件(= 已有模型一句话摘要),尚未烘焙工具栏序的。
        let attentionFiles = index.records.filter {
            $0.type != .folder && $0.path != nil && ($0.contentSummary?.shortSummary?.isEmpty == false)
        }
        log("烘焙 toolbarActionRanking:文件级候选 \(attentionFiles.count)")
        for rec in attentionFiles {
            if Date() >= passDeadline { break }
            guard let path = rec.path, ranking.byFile[path] == nil else { continue }
            let ids = FileActionCatalog.defaultActions(for: singleFileSnapshot(rec)).map { $0.id.rawValue }
            guard ids.count >= 2 else { ranking.byFile[path] = ids; changed = true; continue }
            guard let ordered = try? await rankActions(
                fileName: rec.fileName, kind: rec.type == .archive ? "archive" : "file",
                roleTags: rec.roleTags, summary: rec.contentSummary?.shortSummary, ids: ids, lang: lang) else { continue }
            ranking.byFile[path] = ordered; changed = true; count += 1
            log("  工具栏序(文件)✓ \(rec.fileName):\(ordered.prefix(3).joined(separator: " > "))")
        }

        // 类型级:每个还没烘焙的扩展名取一个代表文件,烘一份按后缀的序。
        var repByExt: [String: AIFileMemoryRecord] = [:]
        for rec in index.records where rec.type != .folder {
            let ext = URL(fileURLWithPath: rec.path ?? rec.fileName).pathExtension.lowercased()
            guard !ext.isEmpty, ranking.byType[ext] == nil, repByExt[ext] == nil else { continue }
            repByExt[ext] = rec
        }
        if !repByExt.isEmpty { log("  类型级候选 \(repByExt.count) 种后缀") }
        for (ext, rec) in repByExt {
            if Date() >= passDeadline { break }
            let ids = FileActionCatalog.defaultActions(for: singleFileSnapshot(rec)).map { $0.id.rawValue }
            guard ids.count >= 2 else { ranking.byType[ext] = ids; changed = true; continue }
            guard let ordered = try? await rankActions(
                fileName: "example.\(ext)", kind: rec.type == .archive ? "archive" : "file",
                roleTags: [], summary: nil, ids: ids, lang: lang) else { continue }
            ranking.byType[ext] = ordered; changed = true; count += 1
            log("  工具栏序(类型 .\(ext))✓:\(ordered.prefix(3).joined(separator: " > "))")
        }

        if changed, let data = try? JSONEncoder().encode(ranking) {
            derived.set(data, forKey: AIToolbarRanking.derivedKey)
        }
        return count
    }

    /// 调引擎排序一份候选动作 id,回有序 id(序号回查 + 池内校验)。
    @available(macOS 26.0, *)
    private static func rankActions(fileName: String, kind: String, roleTags: [String],
                                    summary: String?, ids: [String], lang: String) async throws -> [String] {
        let out = try await runPass(
            .toolbarActionRanking,
            ToolbarActionRankingInput(fileName: fileName, kind: kind, roleTags: roleTags, summary: summary, actions: ids),
            AIPassIntListOutput.self, lang)
        return out.numbers.compactMap { ids.indices.contains($0 - 1) ? ids[$0 - 1] : nil }
    }

    /// 单文件的工具栏上下文快照(从索引记录构造,cheap;烘焙文件级 / 类型级序用)。
    private static func singleFileSnapshot(_ rec: AIFileMemoryRecord) -> ContextualToolbarSnapshot {
        let url = URL(fileURLWithPath: rec.path ?? rec.fileName)
        let isDir = rec.type == .folder
        let isArchive = !isDir && ArchiveService.isSupportedArchive(url)
        let sf = ContextualToolbarSnapshot.SelectedFile(
            name: rec.fileName, pathExtension: url.pathExtension.lowercased(), isDirectory: isDir,
            isSupportedArchive: isArchive,
            isToolableArchive: isArchive,   // agent 无 SignedContainerService(App target);单文件下 supported≈toolable,.siz 细微差忽略
            isPackage: false,
            isFirstVolume: !isDir && FileSplitCombine.isFirstVolume(url),
            isChecksumFile: !isDir && ChecksumFile.isChecksumFileName(rec.fileName))
        return ContextualToolbarSnapshot(mode: .folder, selectedFiles: [sf],
                                         gpgUIAvailable: false, canConvertSelectedArchives: isArchive)
    }

    // MARK: - Pass ⑧⑨:文件夹成组建议 / 整理进新文件夹(workspaceFolderGroups / workspaceOrganize)

    /// 按文件夹分组**非目录**记录(标准化文件夹路径),`skip(folder)` 命中(已评估)的不收。返回 (有序文件夹, 分组)。
    private static func recordsByFolder(_ index: AIFileMemoryIndex, skip: (String) -> Bool) -> (order: [String], byFolder: [String: [AIFileMemoryRecord]]) {
        var order: [String] = []
        var byFolder: [String: [AIFileMemoryRecord]] = [:]
        for rec in index.records where rec.type != .folder {
            guard let path = rec.path else { continue }
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
            if skip(folder) { continue }
            if byFolder[folder] == nil { order.append(folder) }
            byFolder[folder, default: []].append(rec)
        }
        return (order, byFolder)
    }

    /// 一个文件夹的记录 → prompt 候选(+ candidateID→path 映射)。
    private static func folderCandidates(_ records: [AIFileMemoryRecord]) -> (items: [AIVirtualNodePromptCandidate], pathByID: [String: String]) {
        var pathByID: [String: String] = [:]
        let items = records.compactMap { rec -> AIVirtualNodePromptCandidate? in
            guard let p = rec.path else { return nil }
            let c = AIWorkspaceDiscovery.candidate(from: rec)
            pathByID[c.id] = p
            return AIVirtualNodePromptCandidate(candidate: c)
        }
        return (items, pathByID)
    }

    @available(macOS 26.0, *)
    private static func bakeFolderGroups(_ index: AIFileMemoryIndex, derived: AIDerivedDataStore,
                                         lang: String, passDeadline: Date, log: (String) -> Void) async -> Int {
        var dict: [String: [CachedFolderGroup]] = decodeDerived(derived, AppPreferences.Key.aiFolderGroupsData) ?? [:]
        let (order, byFolder) = recordsByFolder(index) { dict[$0] != nil }
        let picks = order.filter { (byFolder[$0]?.count ?? 0) >= 2 }
        log("烘焙 folderGroups:候选文件夹 \(picks.count)")
        var count = 0; var changed = false
        for folder in picks {
            if Date() >= passDeadline { break }
            let (items, pathByID) = folderCandidates(byFolder[folder] ?? [])
            guard items.count >= 2 else { dict[folder] = []; changed = true; continue }
            guard let out = try? await runPass(.workspaceFolderGroups, items, WorkspaceFolderGroupOutput.self, lang) else { continue }
            let groups = out.groups.compactMap { g -> CachedFolderGroup? in
                var seen = Set<String>()
                let paths = g.memberIDs.compactMap { pathByID[$0] }.filter { seen.insert($0).inserted }
                guard paths.count >= 2 else { return nil }
                return CachedFolderGroup(title: nil, memberPaths: paths, actionToken: g.actionToken)
            }
            dict[folder] = groups; changed = true; count += 1
            if !groups.isEmpty { log("  文件组 ✓ \((folder as NSString).lastPathComponent):\(groups.count) 组") }
        }
        if changed, let data = try? JSONEncoder().encode(dict) { derived.set(data, forKey: AppPreferences.Key.aiFolderGroupsData) }
        return count
    }

    @available(macOS 26.0, *)
    private static func bakeOrganize(_ index: AIFileMemoryIndex, derived: AIDerivedDataStore,
                                     lang: String, passDeadline: Date, log: (String) -> Void) async -> Int {
        var dict: [String: CachedFolderGroup] = decodeDerived(derived, AppPreferences.Key.aiOrganizeSuggestionsData) ?? [:]
        // 整理需要一簇(≥3 文件)。已评估 = 键存在(含「评估过无建议」空哨兵)。
        let (order, byFolder) = recordsByFolder(index) { dict[$0] != nil }
        let picks = order.filter { (byFolder[$0]?.count ?? 0) >= 3 }
        log("烘焙 organize:候选文件夹 \(picks.count)")
        let emptySentinel = CachedFolderGroup(title: nil, memberPaths: [], actionToken: "organize")
        var count = 0; var changed = false
        for folder in picks {
            if Date() >= passDeadline { break }
            let (items, pathByID) = folderCandidates(byFolder[folder] ?? [])
            guard items.count >= 3 else { dict[folder] = emptySentinel; changed = true; continue }
            // do/catch:区分「引擎失败(抛错 → 不落哨兵,下轮重试)」与「模型说不值得(回 null → 落空哨兵)」。
            let result: WorkspaceOrganizeOutput?
            do { result = try await runPass(.workspaceOrganize, items, WorkspaceOrganizeOutput?.self, lang) }
            catch { continue }
            guard let out = result else { dict[folder] = emptySentinel; changed = true; count += 1; continue }   // 模型说不值得
            var seen = Set<String>()
            let paths = out.memberIDs.compactMap { pathByID[$0] }.filter { seen.insert($0).inserted }
            dict[folder] = paths.count >= 3 ? CachedFolderGroup(title: out.folderName, memberPaths: paths, actionToken: "organize") : emptySentinel
            changed = true; count += 1
            if paths.count >= 3 { log("  整理 ✓ \((folder as NSString).lastPathComponent) → 「\(out.folderName)」\(paths.count) 个") }
        }
        if changed, let data = try? JSONEncoder().encode(dict) { derived.set(data, forKey: AppPreferences.Key.aiOrganizeSuggestionsData) }
        return count
    }

    private static func decodeDerived<T: Decodable>(_ derived: AIDerivedDataStore, _ key: String) -> T? {
        guard let data = derived.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Pass ⑩:pending 安全 / 发布包检测(确定性分析 + 仅异常时模型润色一句话)

    @available(macOS 26.0, *)
    private static func bakePendingSecurityInspect(_ index: AIFileMemoryIndex, lang: String, passDeadline: Date,
                                                   log: (String) -> Void) async -> (index: AIFileMemoryIndex, count: Int) {
        var index = index
        let defaults = AIAgentConfiguration.appDomainDefaults()
        guard let data = defaults.data(forKey: AppPreferences.Key.aiPendingChecksData),
              var queue = try? JSONDecoder().decode(AIPendingCheckQueue.self, from: data) else { return (index, 0) }
        let pending = queue.checks
            .filter { $0.status == .pending && ($0.behavior == .security || $0.behavior == .inspect) }
            .sorted { $0.queuedAt < $1.queuedAt }
        guard !pending.isEmpty else { return (index, 0) }
        log("烘焙 pendingChecks(security/inspect):待执行 \(pending.count)")
        var count = 0
        for check in pending {
            if Date() >= passDeadline { break }
            guard FileManager.default.fileExists(atPath: check.path),
                  let rec = index.records.first(where: { $0.path == check.path }) else {
                queue.mark(id: check.id, status: .failed, executedAt: Date()); continue
            }
            let url = URL(fileURLWithPath: check.path)
            do {
                switch check.behavior {
                case .security:
                    let items = try await ArchiveService.list(url)
                    let findings = ArchiveSecurityReport.analyze(items)
                    let assessment = ArchiveRiskScore.assess(
                        findings: findings, encryptedCount: items.filter(\.isEncrypted).count,
                        junkCount: ArchiveJunkFiles.junkEntries(in: items).count)
                    if AIPendingCheckJudge.securityWorthSurfacing(findings: findings, assessment: assessment) {
                        let p = AIInlineReportPrompt.pathSafety(assessment: assessment, findings: findings, listable: true)
                        let text = (try await runPass(.reportText, ReportTextInput(instructions: p.instructions, prompt: p.prompt), AIPassTextOutput.self, lang))
                            .text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { index = applyInline(index, recordID: rec.id, token: "security", text: text); log("  安全 ✓ \(rec.fileName)") }
                    }
                    queue.mark(id: check.id, status: .done, executedAt: Date()); count += 1
                case .inspect:
                    let items = try await ArchiveService.list(url)
                    var report = ReleaseInspectionReport(archiveURL: url)
                    report.listable = true
                    report.stats = ReleaseInspection.stats(for: items)
                    report.securityFindings = ArchiveSecurityReport.analyze(items)
                    report.structuralFingerprint = ArchiveStructuralFingerprint.compute(for: items)
                    report.hasComment = !ArchiveService.headerComment(for: url).isEmpty
                    do { try await ArchiveService.test(url, password: ""); report.testPassed = true }
                    catch { report.testPassed = false; report.testFailureMessage = String(error.localizedDescription.prefix(160)) }
                    if AIPendingCheckJudge.inspectWorthSurfacing(report: report) {
                        let p = AIInlineReportPrompt.releaseInspection(for: report)
                        let text = (try await runPass(.reportText, ReportTextInput(instructions: p.instructions, prompt: p.prompt), AIPassTextOutput.self, lang))
                            .text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { index = applyInline(index, recordID: rec.id, token: "inspect", text: text); log("  发布检测 ✓ \(rec.fileName)") }
                    }
                    queue.mark(id: check.id, status: .done, executedAt: Date()); count += 1
                default: continue
                }
            } catch {
                queue.mark(id: check.id, status: .failed, executedAt: Date())
            }
        }
        if let out = try? JSONEncoder().encode(queue) { defaults.set(out, forKey: AppPreferences.Key.aiPendingChecksData) }
        return (index, count)
    }

    // MARK: - Pass ⑪:活动中心工作台(读 App 投影的任务记录 → chip 排序 / 真建议命名 / 需处理解读 / 失败解释)

    @available(macOS 26.0, *)
    private static func bakeWorkbench(derived: AIDerivedDataStore, lang: String, passDeadline: Date,
                                      log: (String) -> Void) async -> Int {
        guard let data = derived.data(forKey: AppPreferences.Key.aiTaskRecordProjection),
              let records = try? JSONDecoder().decode([AITaskRecord].self, from: data), !records.isEmpty else { return 0 }
        log("烘焙 workbench:任务记录 \(records.count)")
        let categories = ["archive", "fileOperation", "undoRedo"]
        var count = 0

        // ① 筛选 chip 排序(每分类一条,指纹幂等)
        var chipDict: [String: CachedChipRanking] = decodeDerived(derived, AppPreferences.Key.aiWorkbenchChipRankingData) ?? [:]
        var chipChanged = false
        for category in categories {
            if Date() >= passDeadline { break }
            let chips = ActivityAIWorkbenchBuilder.snapshot(records: records.filter { $0.category == category }).filterChips
            guard chips.count >= 2 else { continue }
            let fp = ActivityAIWorkbenchKeys.chipPoolFingerprint(chips)
            guard chipDict[category]?.fingerprint != fp else { continue }
            let cands = chips.map { WorkbenchChipRankingInput.Candidate(label: ActivityAIWorkbenchKeys.chipPromptLabel($0), matches: ActivityAIWorkbenchKeys.chipMatchCount($0)) }
            guard let out = try? await runPass(.rankWorkbenchFilterChips, WorkbenchChipRankingInput(candidates: cands), AIPassIntListOutput.self, lang), !out.numbers.isEmpty else { continue }
            let ids = out.numbers.compactMap { (1...chips.count).contains($0) ? chips[$0 - 1].id : nil }
            guard !ids.isEmpty else { continue }
            chipDict[category] = CachedChipRanking(fingerprint: fp, orderedIDs: ids); chipChanged = true; count += 1
            log("  筛选排序 ✓ \(category)")
        }
        if chipChanged, let d = try? JSONEncoder().encode(chipDict) { derived.set(d, forKey: AppPreferences.Key.aiWorkbenchChipRankingData) }

        // ② 真建议聚类命名(每分类一条)
        var clusterDict: [String: CachedClusterChips] = decodeDerived(derived, AppPreferences.Key.aiWorkbenchClusterChipsData) ?? [:]
        var clusterChanged = false
        for category in categories {
            if Date() >= passDeadline { break }
            let clusters = ActivityAIWorkbenchBuilder.discoverClusters(records: records.filter { $0.category == category })
            guard !clusters.isEmpty else { continue }
            let fp = ActivityAIWorkbenchKeys.clusterFingerprint(clusters)
            guard clusterDict[category]?.fingerprint != fp else { continue }
            let cands = clusters.map { WorkbenchClusterNamingInput.Candidate(facts: $0.dimensionFacts, matches: $0.matchCount) }
            guard let out = try? await runPass(.nameWorkbenchClusters, WorkbenchClusterNamingInput(candidates: cands), AIPassClusterNamingOutput.self, lang), !out.entries.isEmpty else { continue }
            let chips: [CachedClusterChip] = out.entries.compactMap { item in
                guard (1...clusters.count).contains(item.index) else { return nil }
                let c = clusters[item.index - 1]
                return CachedClusterChip(id: ActivityAIWorkbenchKeys.clusterChipID(c.filter), displayName: item.name, filter: c.filter, matchCount: c.matchCount)
            }
            guard !chips.isEmpty else { continue }
            clusterDict[category] = CachedClusterChips(fingerprint: fp, chips: chips); clusterChanged = true; count += 1
            log("  真建议 ✓ \(category):\(chips.count)")
        }
        if clusterChanged, let d = try? JSONEncoder().encode(clusterDict) { derived.set(d, forKey: AppPreferences.Key.aiWorkbenchClusterChipsData) }

        // ③ 需处理解读(每分类一条,仅有未读失败时)
        var needsDict: [String: CachedExplanation] = decodeDerived(derived, AppPreferences.Key.aiWorkbenchNeedsAttentionData) ?? [:]
        var needsChanged = false
        for category in categories {
            if Date() >= passDeadline { break }
            let recs = records.filter { $0.category == category }
            let fp = ActivityAIWorkbenchKeys.needsAttentionFingerprint(recs)
            guard !fp.isEmpty, needsDict[category]?.fingerprint != fp else { continue }
            let unseenFailed = recs.filter { $0.status == "failed" && !$0.failureSeen }
            guard !unseenFailed.isEmpty else { continue }
            let s = ActivityAIWorkbenchSummary(records: recs)
            let summaryFacts = ["total \(s.total)", "running \(s.running)", "unseen-failed \(s.failedUnseen)", "failed \(s.failedSeen)", "succeeded \(s.succeeded)"]
            let failedFacts = unseenFailed.prefix(8).map { rec -> String in
                let tags = rec.diagnostics.tags.isEmpty ? "no-tags" : rec.diagnostics.tags.joined(separator: "+")
                return "\(rec.kind) / \(rec.source) / \(tags)"
            }
            guard let out = try? await runPass(.activityWorkbenchExplanation, ActivityWorkbenchExplanationInput(summaryFacts: summaryFacts, failedFacts: Array(failedFacts)), AIPassTextOutput.self, lang), !out.text.isEmpty else { continue }
            needsDict[category] = CachedExplanation(fingerprint: fp, text: out.text); needsChanged = true; count += 1
            log("  需处理 ✓ \(category)")
        }
        if needsChanged, let d = try? JSONEncoder().encode(needsDict) { derived.set(d, forKey: AppPreferences.Key.aiWorkbenchNeedsAttentionData) }

        // ④ 失败解释(逐失败任务,修剪到活失败任务集)
        let failed = records.filter { $0.status == "failed" }
        let liveTaskIDs = Set(failed.map(\.id))
        var failDict: [String: CachedExplanation] = decodeDerived(derived, AppPreferences.Key.aiWorkbenchFailureExplanationData) ?? [:]
        var failChanged = false
        for rec in failed {
            if Date() >= passDeadline { break }
            let fp = ActivityAIWorkbenchKeys.failureExplanationFingerprint(rec)
            guard failDict[rec.id]?.fingerprint != fp else { continue }
            let diag = rec.diagnostics
            guard let out = try? await runPass(.taskFailureShortExplanation, TaskFailureExplanationInput(
                kind: rec.kind, source: rec.source, tags: diag.tags, failureMessage: diag.failureMessage, errorLines: diag.errorLines),
                AIPassTextOutput.self, lang), !out.text.isEmpty else { continue }
            failDict[rec.id] = CachedExplanation(fingerprint: fp, text: out.text); failChanged = true; count += 1
            log("  失败解释 ✓ \(rec.kind)")
        }
        let prunedFail = failDict.filter { liveTaskIDs.contains($0.key) }   // 历史不累积:修剪到当前活失败任务
        if failChanged || prunedFail.count != failDict.count, let d = try? JSONEncoder().encode(prunedFail) {
            derived.set(d, forKey: AppPreferences.Key.aiWorkbenchFailureExplanationData)
        }

        return count
    }

    private static func applyInline(_ index: AIFileMemoryIndex, recordID: String, token: String, text: String) -> AIFileMemoryIndex {
        guard let rec = index.records.first(where: { $0.id == recordID }) else { return index }
        let base = rec.contentSummary ?? AIFileContentSummary(mode: "inline-result")
        guard base.inlineResults[token] != text else { return index }
        return index.updatingRecord(id: recordID) { $0.withContentSummary(base.withInlineResult(token: token, text: text)) }
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

    private static func applyDiskImage(_ index: AIFileMemoryIndex, recordID: String,
                                       summary: String?, appName: String?) -> AIFileMemoryIndex {
        let clean = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        var actions: [AIFileSuggestedAction] = []
        if let appName, !appName.isEmpty {
            actions.append(AIFileSuggestedAction(token: "dragToApplications", payload: appName, label: appName))
        }
        let content = AIFileContentSummary(mode: "disk-image",
                                           shortSummary: (clean?.isEmpty == false) ? clean : nil,
                                           suggestedActions: actions)
        return index.updatingRecord(id: recordID) { $0.withContentSummary(content) }
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

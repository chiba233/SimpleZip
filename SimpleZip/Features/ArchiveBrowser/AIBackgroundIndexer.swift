//
//  AIBackgroundIndexer.swift
//  SimpleZip
//
//  0.4.5 #80 #89:后台 AI 文件预索引扫描器(白皮书工程补充六)。**security-sensitive。**
//
//  硬约束(全部满足才跑,且实现层层兜底):
//  - **opt-in 门控**:`AIBackgroundIndexStore.folderPreindexEnabled`(AI 主开关 + 活跃度≠off + 子开关 + 有白名单)。
//  - **白名单**:只走 `AIArchivePrefetchScope` 列出的目录。
//  - **只读 + 仅元数据**:只取文件名 / 大小 / mtime / 是否目录;**绝不读内容**(内容门控另在 readability policy)。
//  - **排除**:`AIPrefetchExclusions`(系统 / 密钥 / 缓存 / 开发依赖 / 临时目录)+ 跳过隐藏文件(避开 .ssh/.env)。
//  - **不跟符号链接**(防逃逸白名单 / 环);外置 / 网络卷默认不进(scope 未显式允许)。
//  - **预算化**:每轮 scope 数 + 每 scope 文件 / 目录上限,按活跃度档位;**可取消**;**全程 off-main**(A18)。
//  - 文件名经 `AIFileMemoryRecord.make` 脱敏(疑似密钥名抹除)。
//

import AppKit
import Foundation

@MainActor
final class AIBackgroundIndexer {
    static let shared = AIBackgroundIndexer()

    private var running = false
    private var task: Task<Void, Never>?
    private var archiveRunning = false
    private var archiveTask: Task<Void, Never>?
    private var suggestionRunning = false
    private var suggestionTask: Task<Void, Never>?

    /// 跑一轮预索引(门控未过则直接返回 —— 默认 opt-in 关闭即什么都不做)。完成后通知发现编排者刷新。
    func runIfEnabled() {
        let store = AIBackgroundIndexStore.shared
        guard !running, store.indexingEnabled, let budget = store.budget else { return }
        running = true

        let scopes = Array(store.scopes.prefix(max(1, budget.maxDirectoriesPerRound)))
        let home = NSHomeDirectory()
        let fileBudget = min(budget.maxEntriesPerArchive, 3_000)
        // 内容预读是**更高隐私等级的独立开关**:只元数据预索引时 allowContent=false(绝不读内容);开了「预读内容」
        // 才对「定主题」文档读头部产脱敏摘要(归档内容预读是另一条路,见 archivePrefetchEnabled)。
        let allowContent = store.contentPrereadEnabled
        // 渐进覆盖:把上一轮已有摘要的记录带进去,指纹没变的直接沿用、不重读 → 预算轮到没读过/变了的文件。
        let existingSummarized = allowContent ? store.summarizedRecordsByID() : [:]

        task = Task.detached(priority: .background) {
            var results: [(UUID, [AIFileMemoryRecord])] = []
            for scope in scopes {
                if Task.isCancelled { break }
                let records = AIBackgroundIndexer.scanScope(scope, home: home, fileBudget: fileBudget,
                                                            allowContent: allowContent,
                                                            existingSummarized: existingSummarized)
                results.append((scope.id, records))
            }
            let scanned = results   // 不可变快照后再跨 actor 边界(Swift 6:别捕获可变 var)
            await MainActor.run {
                // M7:回主线程后再核一遍门控 —— 扫描期间用户可能关了开关 / 清了白名单,关了就不落盘。
                if store.indexingEnabled {
                    let now = Date()
                    for (id, records) in scanned {
                        store.ingest(records: records, folders: [], scopeID: id, at: now)
                        store.markScanned(id, at: now)
                    }
                    // (AI 文件夹自动发现已下线 → 不再 index 完回调 discovery.refresh();索引 / 预读照常给 AI suggestion 用。)
                    AIBackgroundIndexer.shared.prereadArchivesIfEnabled()   // 元数据落盘后预读归档内容(门控未过则空跑)
                    AIBackgroundIndexer.shared.generateFileSuggestionsIfEnabled()   // 预读摘要落盘后,对近阈值文件出模型建议(门控未过则空跑)
                }
                AIBackgroundIndexer.shared.running = false
            }
        }
    }

    func cancel() {
        task?.cancel(); task = nil; running = false
        archiveTask?.cancel(); archiveTask = nil; archiveRunning = false
        suggestionTask?.cancel(); suggestionTask = nil; suggestionRunning = false
    }

    // MARK: - 内容预读 · 归档半边(MainActor:ArchiveService 在 app target 下 MainActor 隔离,A18)

    /// 开了「预读内容」时,挑白名单里**还没列过清单**的少量归档,只读列出内部条目 → 写归档清单缓存(它顺带进
    /// Spotlight,和打开归档时同一条路 #35/#72)→ `ArchiveMemoryIndex` 据此派生候选进 AI 文件夹池。加密(空口令列
    /// 不动)/ 损坏 / 临时包 → 跳过。预算化(每轮 ≤ maxArchivesPerRound,封 6)、可取消、串行不抢主线程重活。
    func prereadArchivesIfEnabled() {
        let store = AIBackgroundIndexStore.shared
        guard !archiveRunning, store.contentPrereadEnabled, AppPreferences.archiveListingCacheEnabled,
              let budget = store.budget else { return }
        // 缓存指纹:canonicalPath → (大小, 修改时间)。指纹没变 = 已列过且没变 → 跳过;变了(如重新下载)→ 重列。
        // 这和文件预读同款渐进覆盖:预算只花在「没列过 / 变了」的包上,高权重列完慢慢轮到其余。
        let cachedFingerprint = Dictionary(
            ArchiveListingCacheStore().loadAll().map { ($0.archivePath, ($0.archiveByteSize, $0.archiveModified)) },
            uniquingKeysWith: { first, _ in first })
        let tempPrefix = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let staleRecords = store.recentFileRecords(limit: 2_000).filter { rec in
            guard rec.type == .archive, let path = rec.path else { return false }
            let url = URL(fileURLWithPath: path)
            let p = url.resolvingSymlinksInPath().path
            guard !p.hasPrefix(tempPrefix) else { return false }                    // 临时解压壳层不预读
            guard FileManager.default.fileExists(atPath: path) else { return false }
            let canonical = ArchiveListingCacheStore.canonicalPath(for: url)
            if let fp = cachedFingerprint[canonical], fp.0 == rec.byteSize, fp.1 == rec.modifiedAt {
                return false   // 指纹没变 → 已列过、跳过
            }
            return true        // 新 / 变了 → 候选
        }
        // AI 排序挑前 N(近期碰过 / 改过的包先列)。
        let pick = AIPrereadSelection
            .selectArchivesForListing(records: staleRecords, budget: min(budget.maxArchivesPerRound, 6), now: Date())
            .compactMap { $0.path.map { URL(fileURLWithPath: $0) } }
        guard !pick.isEmpty else { return }
        archiveRunning = true
        archiveTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.archiveRunning = false }
            var listedAny = false
            for url in pick {
                if Task.isCancelled { break }
                guard AIBackgroundIndexStore.shared.contentPrereadEnabled else { break }   // 期间被关
                // 空口令只读列举:加密头 / 损坏 → 抛错跳过(绝不弹密码、绝不解压)。
                guard let items = try? await ArchiveService.list(url) else { continue }
                if ArchiveListingCacheStore().record(archiveURL: url, items: items) {
                    CachedArchiveSpotlightIndexer.indexArchive(at: url)   // 归档级 + 逐条进 Spotlight(双门控在 indexer 里)
                    ArchiveFileSpotlightIndexer.indexArchive(at: url)
                    listedAny = true
                }
            }
            // (AI 文件夹自动发现已下线 → 预读完不再回调 discovery.refresh();归档清单缓存照常给 AI suggestion / Spotlight 用。)
        }
    }

    // MARK: - ②b/②c 模型驱动建议(MainActor:模型调用 async + 串行闸;每轮少量近阈值文件)

    /// 对**已预读、AI 建议评分近阈值、还没出模型建议**的少量文件,端上模型出 {一句话摘要 + 建议动作 token},
    /// 写回预索引(`applyModelSuggestion`)。**拒绝假AI**:文件浏览器只读这个缓存,没有就空抽屉。门控:内容预读开关 +
    /// 模型就绪。预算 = **AI 活跃度档位**对应的 `maxModelSuggestionsPerRound`(不再是脱离设置的孤儿常量)。
    /// 重读头部 + 脱敏在后台线程(只重读这极少量近阈值文件,不影响阶段一扫描)。可取消、串行不重叠。
    func generateFileSuggestionsIfEnabled() {
        guard #available(macOS 26.0, *) else { return }
        let store = AIBackgroundIndexStore.shared
        // AI 建议子开关关 → 自动总结模块停跑(用户:关了 AI 建议把自动总结一起关)。
        guard !suggestionRunning, AppPreferences.aiSuggestionEnabled,
              store.contentPrereadEnabled, AIReportAssistant.isReady,
              let budget = store.budget else { return }
        let now = Date()
        let candidates = AIPrereadSelection.selectForModelSuggestion(
            records: store.recentFileRecords(limit: 2_000),
            budget: budget.maxModelSuggestionsPerRound, now: now)
        guard !candidates.isEmpty else { return }
        suggestionRunning = true
        suggestionTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.suggestionRunning = false }
            for rec in candidates {
                if Task.isCancelled { break }
                guard AIBackgroundIndexStore.shared.contentPrereadEnabled, AIReportAssistant.isReady else { break }
                guard let path = rec.path, let summary = rec.contentSummary,
                      FileManager.default.fileExists(atPath: path) else { continue }
                let fileName = (path as NSString).lastPathComponent
                // 重读头部 + 脱敏在后台线程(不阻塞主线程);拿不到内容(无权限 / 二进制 / 被红线拦)→ 跳过。
                let excerptTask = Task.detached(priority: .background) {
                    (excerpt: AIBackgroundIndexer.redactedExcerpt(url: URL(fileURLWithPath: path), fileName: fileName),
                     apps: AIBackgroundIndexer.nonDefaultOpenApps(forPath: path))   // 推荐打开方式:非默认候选 App(纯元数据)
                }
                let probed = await excerptTask.value
                guard let excerpt = probed.excerpt else { continue }
                let kind = rec.type == .archive ? "archive" : "file"
                guard let result = try? await AIVirtualFolderModelPlanner.fileSuggestion(
                    fileName: rec.fileName, kind: kind, roleTags: rec.roleTags,
                    languageHint: summary.languageHint, headings: summary.headings,
                    fieldNames: summary.fieldNames, excerpt: excerpt,
                    candidateOpenApps: probed.apps),
                    !result.summary.isEmpty || !result.actions.isEmpty else { continue }
                AIBackgroundIndexStore.shared.applyModelSuggestion(
                    recordID: rec.id, summary: result.summary, actions: result.actions)
            }
        }
    }

    /// 读一个文件头部 → 脱敏(给模型出一句话摘要的素材)。红线门控同 `summarizeContent`(敏感目录 / 临时解密 /
    /// 疑似密钥名一律不读);无读权限 / 空 / 非 UTF-8 → nil。**脱敏后**的文本才会进 prompt(白皮书隐私口径)。
    nonisolated static func redactedExcerpt(url: URL, fileName: String) -> String? {
        if AIFileReadabilityPolicy.blockReason(absolutePath: url.path, fileName: fileName,
                                               currentUserCanRead: true, isExcludedByUser: false) != nil {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxContentReadBytes)) ?? Data()
        guard !data.isEmpty, let raw = String(data: data, encoding: .utf8) else { return nil }
        let redacted = AISensitiveRedactor.redact(raw)
        let trimmed = redacted.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// **推荐打开方式**:查一个文件的「**非默认**」候选打开 App(LaunchServices 元数据,**不读内容**)。默认双击就能
    /// 开 → 不进建议;只把非默认候选喂给模型挑(用户:非默认才进 suggestion,「不然脱裤子放屁」)。返回
    /// `(bundleID, 显示名)`,去掉默认 App、去重、封顶 8 个。文件不存在 / 无候选 → 空数组。off-main 安全。
    nonisolated static func nonDefaultOpenApps(forPath path: String) -> [(bundleID: String, name: String)] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let ws = NSWorkspace.shared
        let defaultBundleID = ws.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
        var seen = Set<String>()
        var out: [(bundleID: String, name: String)] = []
        for appURL in ws.urlsForApplications(toOpen: url) {
            guard let bundleID = Bundle(url: appURL)?.bundleIdentifier else { continue }
            if let def = defaultBundleID, bundleID == def { continue }           // 去掉默认 App
            guard seen.insert(bundleID).inserted else { continue }
            let raw = FileManager.default.displayName(atPath: appURL.path)
            let name = raw.hasSuffix(".app") ? String(raw.dropLast(4)) : raw
            out.append((bundleID, name))
            if out.count >= 8 { break }
        }
        return out
    }

    // MARK: - 只读元数据扫描(off-main;纯静态,不碰 UI 状态)

    /// 每 scope 最多访问的目录数(防超大递归目录把一轮拖垮 —— 白皮书禁「超出预算的大型递归目录」)。
    private nonisolated static let maxDirectoriesPerScope = 600

    /// 走一个白名单 scope,深度受限、层层排除、只取元数据、不跟符号链接。返回文件记录(疑似密钥文件整条不索引)。
    /// `allowContent` 开时**两阶段**:① BFS 出元数据;② **AI 排序挑前 N 个补内容摘要**(渐进覆盖,见 AIPrereadSelection)。
    /// `existingSummarized` = 上一轮已有摘要的记录(id → 记录),**指纹(大小+修改时间)没变就直接沿用旧摘要、不重读**
    /// → 预算只花在「新文件 / 变了的文件」上,高权重读完慢慢轮到低权重,时间够长全覆盖。
    nonisolated static func scanScope(_ scope: AIArchivePrefetchScope, home: String,
                                      fileBudget: Int, allowContent: Bool = false,
                                      existingSummarized: [String: AIFileMemoryRecord] = [:]) -> [AIFileMemoryRecord] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                         .contentModificationDateKey, .volumeIsLocalKey]
        var records: [AIFileMemoryRecord] = []
        var visitedDirs = 0
        // 游标 BFS(避免 Array.removeFirst 的 O(n²));seed 标准化(消 `..`,防被篡改的持久 scope 逃逸)。
        var queue: [(url: URL, depth: Int)] = [(URL(fileURLWithPath: scope.directoryPath).standardizedFileURL, 0)]
        var head = 0

        while head < queue.count, records.count < fileBudget, visitedDirs < maxDirectoriesPerScope {
            let (dir, depth) = queue[head]; head += 1
            // 目录级层层兜底(对 seed 和每个子目录一致):符号链接 / 敏感目录 / 系统排除 / 外置·网络卷。
            guard shouldWalkDirectory(dir, scope: scope, home: home) else { continue }
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { continue }
            visitedDirs += 1

            let loc = AILocationClassifier.classify(directoryPath: dir.path, home: home)
            var dirHasFile = false   // 这个目录是否「有内容」(直接含文件)→ 决定要不要把它本身记成 folder 候选
            var roleCounts: [String: Int] = [:]
            for entry in entries {
                if records.count >= fileBudget { break }
                // M5:取不到属性 = 类型未知 → 整条跳过(不再 fail-open 当普通文件 / 漏判符号链接)。
                guard let vals = try? entry.resourceValues(forKeys: keys) else { continue }
                if vals.isSymbolicLink == true { continue }   // 不跟符号链接(防逃逸 / 环)
                if !scope.includeExternalVolumes, entry.path.hasPrefix("/Volumes/") { continue }
                if vals.isDirectory == true {
                    // 子目录入队;敏感 / 排除 / 符号链接 / 卷 的判定在出队时由 shouldWalkDirectory 统一兜。
                    if scope.recursive, depth + 1 < scope.maxDepth { queue.append((entry, depth + 1)) }
                } else {
                    // C1:疑似密钥 / 凭据文件名(id_rsa / *.pem / .env / *.p12 / *.gpg …)→ 整条不索引。
                    if AIFileReadabilityPolicy.looksLikeSecret(fileName: entry.lastPathComponent) { continue }
                    dirHasFile = true
                    let roleTags = AIFileType.roleTags(fileName: entry.lastPathComponent, isDirectory: false)
                    guard AIFileRoleSamplingPolicy.reserve(roleTags, counts: &roleCounts) else { continue }
                    // 阶段一:只建**元数据**记录(不读内容)。内容摘要在 BFS 结束后由 AI 排序挑出前 N 个再补(见下)。
                    records.append(AIFileMemoryRecord.make(
                        fileName: entry.lastPathComponent, isDirectory: false,
                        byteSize: vals.fileSize.map(Int64.init), modifiedAt: vals.contentModificationDate,
                        location: loc,
                        path: entry.path))   // 存全路径(非加密路径不是风险,AI 有权知道)
                }
            }
            // **把任何有内容(直接含文件)的目录本身也记成 folder 候选** —— AI 文件夹可把一个文件夹整体收纳
            // (项目目录 / 数据目录…),不必把里面的文件拆散塞(用户:任何有内容的文件夹都该能整体收进来)。
            // depth>0:不收白名单 seed 根本身(那是授权的扫描范围,不是「一个文件夹」)。
            if dirHasFile, depth > 0, records.count < fileBudget {
                let parentLoc = AILocationClassifier.classify(
                    directoryPath: dir.deletingLastPathComponent().path, home: home)
                let dirMtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                records.append(AIFileMemoryRecord.make(
                    fileName: dir.lastPathComponent, isDirectory: true,
                    byteSize: nil, modifiedAt: dirMtime, location: parentLoc, path: dir.path))
            }
        }

        // 阶段二:**AI 驱动 + 渐进覆盖的预读**。`allowContent` 关(只元数据档)时整段跳过。
        guard allowContent else { return records }
        // 指纹(大小+修改时间)没变的已摘要文件 → 直接沿用旧摘要、不重读;其余(新/变了)才进候选。
        // 这样预算只花在没读过/变了的文件上 → 高权重吃完慢慢轮到低权重 → 最终全覆盖(用户:别让低权重没机会)。
        var carried: [String: AIFileContentSummary] = [:]
        var staleCandidates: [AIFileMemoryRecord] = []
        for rec in records {
            if let old = existingSummarized[rec.id], let summary = old.contentSummary,
               old.byteSize == rec.byteSize, old.modifiedAt == rec.modifiedAt {
                carried[rec.id] = summary          // 没变 → 沿用,省一次读
            } else {
                staleCandidates.append(rec)         // 新 / 变了 → 候选(AIPrereadSelection 内部再筛文本可读类)
            }
        }
        let selected = AIPrereadSelection.selectForSummary(
            records: staleCandidates, budget: maxContentSummariesPerScope, now: Date())
        var fresh: [String: AIFileContentSummary] = [:]
        for rec in selected {
            guard let path = rec.path else { continue }
            if let summary = summarizeContent(url: URL(fileURLWithPath: path),
                                              fileName: (path as NSString).lastPathComponent) {
                fresh[rec.id] = summary
            }
        }
        guard !carried.isEmpty || !fresh.isEmpty else { return records }
        return records.map { rec in
            if let summary = fresh[rec.id] { return rec.withContentSummary(summary) }       // 新算的
            if let summary = carried[rec.id] { return rec.withContentSummary(summary) }      // 沿用旧的
            return rec
        }
    }

    /// 一个目录是否允许被列举(seed 和每个子目录都过这关)。任一命中即拒:
    /// 符号链接(防逃逸白名单)/ 网络卷(scope 未显式允许)/ 系统排除目录 / 敏感目录(含非隐藏的 keys/secrets/
    /// credentials/password-store …)/ 外置卷(scope 未显式允许)。
    private nonisolated static func shouldWalkDirectory(_ dir: URL, scope: AIArchivePrefetchScope,
                                                        home: String) -> Bool {
        if let vals = try? dir.resourceValues(forKeys: [.isSymbolicLinkKey, .volumeIsLocalKey]) {
            if vals.isSymbolicLink == true { return false }                       // H3/H5:不跟符号链接(含 seed)
            if !scope.includeNetworkVolumes, vals.volumeIsLocal == false { return false }  // H4:网络卷默认不进
        }
        if AIPrefetchExclusions.shouldExclude(directoryPath: dir.path, home: home) { return false }
        if AIFileReadabilityPolicy.isSensitiveDirectory(dir.path) { return false } // H2/H3:敏感目录(含非隐藏)
        // H2 纵深:明显的凭据目录名(非 dot 变体)也不进 —— `isSensitiveDirectory` 只盖 .password-store 等带点的。
        if credentialDirNames.contains(dir.lastPathComponent.lowercased()) { return false }
        if !scope.includeExternalVolumes, dir.path.hasPrefix("/Volumes/") { return false }
        return true
    }

    /// 明显的凭据目录名(纵深防御;不含太常见 / 歧义的 `keys`)。
    private nonisolated static let credentialDirNames: Set<String> = [
        "secrets", "credentials", "password-store", "passwords", "vault", ".vault"
    ]

    // MARK: - 文档内容预读(off-main;确定性结构抽取,绝不进 prompt 前不脱敏)

    /// 每 scope 最多深读多少篇文档(预算:内容读盘比列元数据贵,只读少量「定主题」文档)。
    private nonisolated static let maxContentSummariesPerScope = 60
    /// 单篇文档读取的头部上限(64KB:头部足够拿到标题 / 顶层字段定主题,避免对大文件全量读)。
    private nonisolated static let maxContentReadBytes = 64 * 1024

    /// 读一个文件头部 → 脱敏 → 内容摘要(标题 / 字段名 / 语言提示,已脱敏)。**挑哪些读、读多少由调用方
    /// (AIPrereadSelection + 预算)决定**,这里不再自带「只 md 才读」死规则。红线门控仍在:敏感目录 / 临时解密 /
    /// 疑似密钥名(`blockReason`)一律不读;无读权限静默跳过。端上模型短摘要(shortSummary)由 ②b 接(此刻仍 nil)。
    private nonisolated static func summarizeContent(url: URL, fileName: String) -> AIFileContentSummary? {
        if AIFileReadabilityPolicy.blockReason(absolutePath: url.path, fileName: fileName,
                                               currentUserCanRead: true, isExcludedByUser: false) != nil {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }   // 无读权限 → 跳过
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxContentReadBytes)) ?? Data()
        let type = AIFileType.classify(fileName: fileName, isDirectory: false)
        guard !data.isEmpty, let raw = String(data: data, encoding: .utf8) else {
            return AIFileContentSummary(mode: "metadata-only")   // 空 / 二进制 / 非 UTF-8 → 只记元数据
        }
        // **脱敏后再抽信号 + 入索引**(白皮书:深度文本摘要由 App 侧先过 AISensitiveRedactor 再塞 contentSummary)。
        let redacted = AISensitiveRedactor.redact(raw)
        let redactionCount = redacted.components(separatedBy: AISensitiveRedactor.placeholder).count - 1
        return AIFileContentSummary(
            mode: "text-summary",
            languageHint: languageHint(type: type, fileName: fileName),
            headings: extractHeadings(redacted, type: type),
            fieldNames: extractFieldNames(redacted, type: type),
            shortSummary: nil,   // 短摘要(端上模型润色)留后续;结构信号已足够喂聚类
            redactionCount: redactionCount)
    }

    /// markdown / 文本标题:`#`…`######` 行的标题文字(去 #、trim、去重),封顶 8 条、每条 ≤ 60 字符。
    private nonisolated static func extractHeadings(_ text: String, type: AIFileType) -> [String] {
        guard type == .markdown || type == .text else { return [] }
        var out: [String] = []; var seen = Set<String>()
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#") else { continue }
            let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            let capped = String(title.prefix(60))
            if seen.insert(capped.lowercased()).inserted { out.append(capped) }
            if out.count >= 8 { break }
        }
        return out
    }

    /// 配置 / json / yaml / toml 顶层字段名:行首 `key:` / `key =` 的 key(去重),封顶 12 条。值不取(可能含敏感)。
    private nonisolated static func extractFieldNames(_ text: String, type: AIFileType) -> [String] {
        guard type == .config || type == .checksum else { return [] }
        var out: [String] = []; var seen = Set<String>()
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else { continue }
            // key 分隔符取首个 `:` 或 `=`(json 的 `"key":` 也覆盖到,引号在下面剥掉)。
            guard let sepIdx = line.firstIndex(where: { $0 == ":" || $0 == "=" }) else { continue }
            var key = String(line[line.startIndex..<sepIdx]).trimmingCharacters(in: .whitespaces)
            key = key.trimmingCharacters(in: CharacterSet(charactersIn: "\"',-"))
            guard key.count >= 2, key.count <= 40,
                  key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) else { continue }
            if seen.insert(key.lowercased()).inserted { out.append(key) }
            if out.count >= 12 { break }
        }
        return out
    }

    /// 语言 / 格式提示(稳定 token):markdown → "markdown";配置 → 扩展名(yaml/json/toml…);否则 nil。
    private nonisolated static func languageHint(type: AIFileType, fileName: String) -> String? {
        switch type {
        case .markdown: return "markdown"
        case .config:
            let ext = (fileName as NSString).pathExtension.lowercased()
            return ext.isEmpty ? "config" : ext
        case .checksum: return "checksum"
        default: return nil
        }
    }
}

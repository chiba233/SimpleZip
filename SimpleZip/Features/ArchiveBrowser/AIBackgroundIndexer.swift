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

import Foundation

@MainActor
final class AIBackgroundIndexer {
    static let shared = AIBackgroundIndexer()

    private var running = false
    private var task: Task<Void, Never>?
    private var archiveRunning = false
    private var archiveTask: Task<Void, Never>?

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

        task = Task.detached(priority: .background) {
            var results: [(UUID, [AIFileMemoryRecord])] = []
            for scope in scopes {
                if Task.isCancelled { break }
                let records = AIBackgroundIndexer.scanScope(scope, home: home, fileBudget: fileBudget,
                                                            allowContent: allowContent)
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
                    AIWorkspaceDiscoveryCoordinator.shared.refresh()
                    AIBackgroundIndexer.shared.prereadArchivesIfEnabled()   // 元数据落盘后预读归档内容(门控未过则空跑)
                }
                AIBackgroundIndexer.shared.running = false
            }
        }
    }

    func cancel() {
        task?.cancel(); task = nil; running = false
        archiveTask?.cancel(); archiveTask = nil; archiveRunning = false
    }

    // MARK: - 内容预读 · 归档半边(MainActor:ArchiveService 在 app target 下 MainActor 隔离,A18)

    /// 开了「预读内容」时,挑白名单里**还没列过清单**的少量归档,只读列出内部条目 → 写归档清单缓存(它顺带进
    /// Spotlight,和打开归档时同一条路 #35/#72)→ `ArchiveMemoryIndex` 据此派生候选进 AI 文件夹池。加密(空口令列
    /// 不动)/ 损坏 / 临时包 → 跳过。预算化(每轮 ≤ maxArchivesPerRound,封 6)、可取消、串行不抢主线程重活。
    func prereadArchivesIfEnabled() {
        let store = AIBackgroundIndexStore.shared
        guard !archiveRunning, store.contentPrereadEnabled, AppPreferences.archiveListingCacheEnabled,
              let budget = store.budget else { return }
        // 已列过清单的归档不重复列(canonical path 去重)。
        let cached = Set(ArchiveListingCacheStore().loadAll().map(\.archivePath))
        let tempPrefix = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let targets: [URL] = store.recentFileRecords(limit: 2_000)
            .filter { $0.type == .archive }
            .compactMap { $0.path }
            .map { URL(fileURLWithPath: $0) }
            .filter { url in
                let p = url.resolvingSymlinksInPath().path
                guard !p.hasPrefix(tempPrefix) else { return false }                 // 临时解压壳层不预读
                guard FileManager.default.fileExists(atPath: url.path) else { return false }
                return !cached.contains(ArchiveListingCacheStore.canonicalPath(for: url))
            }
        let pick = Array(dedupByPath(targets).prefix(min(budget.maxArchivesPerRound, 6)))
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
            if listedAny { AIWorkspaceDiscoveryCoordinator.shared.refresh() }   // 新归档记忆 → 纳入候选池
        }
    }

    /// 按解析后的路径去重(保序)。
    private func dedupByPath(_ urls: [URL]) -> [URL] {
        var seen = Set<String>(); var out: [URL] = []
        for u in urls where seen.insert(u.resolvingSymlinksInPath().path).inserted { out.append(u) }
        return out
    }

    // MARK: - 只读元数据扫描(off-main;纯静态,不碰 UI 状态)

    /// 每 scope 最多访问的目录数(防超大递归目录把一轮拖垮 —— 白皮书禁「超出预算的大型递归目录」)。
    private nonisolated static let maxDirectoriesPerScope = 600

    /// 走一个白名单 scope,深度受限、层层排除、只取元数据、不跟符号链接。返回文件记录(疑似密钥文件整条不索引)。
    /// `allowContent`(= 用户开了「预读内容」更高隐私档)时,额外对「定主题」文档读头部产脱敏内容摘要。
    nonisolated static func scanScope(_ scope: AIArchivePrefetchScope, home: String,
                                      fileBudget: Int, allowContent: Bool = false) -> [AIFileMemoryRecord] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                         .contentModificationDateKey, .volumeIsLocalKey]
        var records: [AIFileMemoryRecord] = []
        var visitedDirs = 0
        var summariesProduced = 0   // 本轮已深读多少篇文档(预算化:只对少量「定主题」文档读内容,见 summarizeIfWorthwhile)
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
                    // **预读文件内容(独立高隐私开关「预读内容」)**:对「定主题」的文档(README / LICENSE / 配置 /
                    // 校验 / markdown)读头部 → 安全摘要(标题 / 字段名,已脱敏),挂到 `contentSummary`。候选映射器把摘要
                    // 标题 / 字段名折进语义 token → 跨位置聚类更准。`allowContent` 关(只元数据档)时一律不读;预算化 +
                    // 红线门控在 summarizeIfWorthwhile 内,普通文件 / 不可读 / 无预算 → 返回 nil(只记元数据)。
                    let summary = allowContent
                        ? summarizeIfWorthwhile(url: entry, fileName: entry.lastPathComponent,
                                                produced: &summariesProduced)
                        : nil
                    records.append(AIFileMemoryRecord.make(
                        fileName: entry.lastPathComponent, isDirectory: false,
                        byteSize: vals.fileSize.map(Int64.init), modifiedAt: vals.contentModificationDate,
                        location: loc, contentSummary: summary,
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
        return records
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

    /// 值得深读 → 读头部产 `AIFileContentSummary`(标题 / 字段名 / 语言提示,已脱敏);否则 nil(只记元数据)。
    /// 廉价重要性:只读 marker 文档(README/LICENSE/manifest)、配置、校验、markdown —— 普通无名 `.txt` 不读(省 IO)。
    /// 红线:敏感目录 / 临时解密 / 疑似密钥名(`blockReason`)一律不读;读不到(无权限)静默跳过、不计预算。
    private nonisolated static func summarizeIfWorthwhile(url: URL, fileName: String,
                                                          produced: inout Int) -> AIFileContentSummary? {
        guard produced < maxContentSummariesPerScope else { return nil }
        let type = AIFileType.classify(fileName: fileName, isDirectory: false)
        let hasMarker = !AIFolderProfile.markerTags(forFileName: fileName).isEmpty
        let worth: Bool
        switch type {
        case .markdown, .config, .checksum: worth = true
        case .text, .sourceCode: worth = hasMarker
        default: worth = false   // 二进制 / 图片 / 归档 / 应用包:不读内容
        }
        guard worth else { return nil }
        // 红线门控(内容可读性策略):敏感目录 / 临时解密 / 疑似密钥名 → 不读。currentUserCanRead 先乐观给 true,
        // 真没权限时下面的 FileHandle 打不开 → 跳过。
        if AIFileReadabilityPolicy.blockReason(absolutePath: url.path, fileName: fileName,
                                               currentUserCanRead: true, isExcludedByUser: false) != nil {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }   // 无读权限 → 跳过,不计预算
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxContentReadBytes)) ?? Data()
        produced += 1
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

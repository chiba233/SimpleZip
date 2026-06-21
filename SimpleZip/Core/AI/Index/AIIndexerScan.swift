//
//  AIIndexerScan.swift
//  SimpleZipCore
//
//  独立 AI 进程改造 · 阶段0b/阶段1 · 从 `AIBackgroundIndexer` god-object 抽出的「只读元数据扫描 + 文档内容预读」。
//
//  文档 02 明确这块「白名单扫描和内容预读」应迁出到 agent。全是 `nonisolated static`、纯函数(只依赖入参 +
//  SimpleZipCore 类型 + 簇内互调)、不碰任何 indexer 实例 / UI 状态 —— 故放进 `SimpleZipCore`(而非 app target):
//  App 仍直接编译 `SimpleZip/Core`,**agent 进程之后 link SimpleZipCore 即可零拷贝复用**(文档:复用 Core 不复制),
//  且现在能被 SwiftPM 单测覆盖。App 侧唯一调用点是 `AIIndexerScan.scanScope`(在 AIBackgroundIndexer 的预索引 pass)。
//
//  红线照旧:符号链接 / 敏感目录 / 疑似密钥名 / 网络·外置卷 层层排除;内容预读前一律过 `AISensitiveRedactor` 脱敏。
//

import Foundation

enum AIIndexerScan {

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
        guard let raw = decodeTextHead(data) else { return nil }
        let redacted = AISensitiveRedactor.redact(raw)
        let trimmed = redacted.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 把(可能截断在多字节字符中间的)头部字节解成文本:直接 UTF-8 失败时退最多 3 字节找合法边界
    /// (一个 UTF-8 字符 ≤4 字节)—— 修 64KB 头部恰好切在 CJK 字符中间导致整篇解码失败 → 摘要素材为空的 bug。
    /// 仍失败 = 非 UTF-8 文本(二进制等)→ nil。
    nonisolated static func decodeTextHead(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        var d = data
        for _ in 0..<3 {
            d = d.dropLast()
            if d.isEmpty { return nil }
            if let s = String(data: d, encoding: .utf8) { return s }
        }
        return nil
    }

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
        guard let raw = decodeTextHead(data) else {
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

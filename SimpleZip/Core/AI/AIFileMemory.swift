//
//  AIFileMemory.swift
//  SimpleZip
//
//  0.4.5 #80:后台文件夹 / 内容预索引的**纯值模型 + 确定性派生**(白皮书工程补充七)。让 AI 不只懂压缩包,
//  也懂主窗口普通文件夹:这个目录像项目 / 发布 / 下载 / 备份 / 测试,哪些文件是关键文件,该用什么 Lens。
//
//  这里只放纯值类型 + 确定性分类 / 画像(文件类型、角色标签、marker、文件夹角色、推荐视角)。真正的目录枚举、
//  内容摘要、白名单、预算、调度在 App 层(后台调度器);本层不读文件系统。
//
//  **红线**:文件名经 `AISensitiveRedactor.redactFileNameSecrets` 脱敏;深度文本摘要由 App 侧先过
//  `AISensitiveRedactor` 再塞 `contentSummary`,命中过多则整体标 blocked。绝不索引加密 / 密钥 / 密文 /
//  解密明文。纯函数,SwiftPM 可断言。
//

import Foundation

/// 文件类型(稳定英文 token)。按扩展名 / 名称确定性分类。
nonisolated enum AIFileType: String, Codable, Equatable, CaseIterable, Sendable {
    case folder
    case archive
    case text
    case markdown
    case sourceCode = "source-code"
    case config
    case checksum
    case signature
    case image
    case video
    case audio
    case appBundle = "app-bundle"
    case diskImage = "disk-image"
    case package
    case binary
    case unknown

    /// 按文件名 + 是否目录确定性分类。名称优先(SHA256SUMS / signature.asc),再按扩展。
    static func classify(fileName: String, isDirectory: Bool) -> AIFileType {
        if isDirectory {
            let lowerDir = fileName.lowercased()
            if lowerDir.hasSuffix(".app") { return .appBundle }
            if packageBundleSuffixes.contains(where: { lowerDir.hasSuffix($0) }) { return .package }
            return .folder
        }
        let lower = fileName.lowercased()
        let base = (lower as NSString).lastPathComponent
        let ext = effectiveExtension(base: base)

        if checksumNames.contains(base) || checksumExtensions.contains(ext) { return .checksum }
        if signatureExtensions.contains(ext) { return .signature }
        if ext == "md" || ext == "markdown" { return .markdown }
        if sourceExtensions.contains(ext) { return .sourceCode }
        if configExtensions.contains(ext) { return .config }
        if archiveExtensions.contains(ext) { return .archive }
        if ext == "dmg" { return .diskImage }
        if ext == "pkg" || ext == "app" { return .package }
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if ext == "txt" || ext == "text" || ext == "rtf" { return .text }
        if binaryExtensions.contains(ext) { return .binary }
        return .unknown
    }

    /// 有效扩展名(小写)。普通文件取 `pathExtension`;**纯 dotfile**(`.gitignore` / `.editorconfig` / `.env`)的
    /// `pathExtension` 为空(前导点被当成隐藏标记而非扩展名),改取点后整段当伪扩展名 —— 这类配置文件才能被
    /// `configExtensions` 命中。带二段扩展的 dotfile(`.eslintrc.json`)`pathExtension` 非空,走常规路径。
    private static func effectiveExtension(base: String) -> String {
        let ext = (base as NSString).pathExtension
        if ext.isEmpty, base.hasPrefix("."), !base.dropFirst().contains(".") {
            return String(base.dropFirst())
        }
        return ext
    }

    /// 文件名 + 类型 → 角色标签。类型保持粗粒度兼容;roleTags 承载更适合主题聚类的语义。
    static func roleTags(fileName: String, isDirectory: Bool) -> [String] {
        roleTags(fileName: fileName, isDirectory: isDirectory,
                 type: classify(fileName: fileName, isDirectory: isDirectory))
    }

    static func roleTags(fileName: String, isDirectory: Bool, type: AIFileType) -> [String] {
        guard !isDirectory else { return type.roleTag.map { [$0] } ?? [] }

        let lower = ((fileName as NSString).lastPathComponent).lowercased()
        let ext = (lower as NSString).pathExtension
        let nameWithoutExtension = (lower as NSString).deletingPathExtension
        let tokens = Set(nameWithoutExtension
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })

        if checksumNames.contains(lower) || checksumExtensions.contains(ext)
            || tokens.contains("checksum") || tokens.contains("checksums") || tokens.contains("sha256")
            || tokens.contains("sha1") || tokens.contains("md5") {
            return ["integrity-data", "checksum"]
        }
        if signatureExtensions.contains(ext) || tokens.contains("signature") || tokens.contains("verify") {
            return ["integrity-data", "signature"]
        }
        if lower.hasPrefix("changelog") || lower.hasPrefix("release_notes") || lower.hasPrefix("release-notes")
            || lower.hasPrefix("news") || lower.hasPrefix("changes")
            || (tokens.contains("changelog") && tokens.contains { $0.range(of: #"v?\d+(\.\d+)+"#,
                                                                            options: .regularExpression) != nil }) {
            return ["release-notes"]
        }
        if lower.hasPrefix("readme") || lower.hasPrefix("security") || lower.hasPrefix("contributing")
            || lower.hasPrefix("code_of_conduct") || lower.hasPrefix("code-of-conduct") || lower.hasPrefix("agents")
            || (["md", "markdown", "rst", "txt"].contains(ext)
                && !tokens.isDisjoint(with: ["readme", "guide", "policy", "security"])) {
            return ["project-doc"]
        }
        if ["txt", "text", "csv", "tsv", "dat", "log"].contains(ext) {
            return ["reference-data"]
        }

        return type.roleTag.map { [$0] } ?? []
    }

    /// 类型 → 兜底角色标签(source / document / checksum / signature / installer / archive / media / config)。
    var roleTag: String? {
        switch self {
        case .sourceCode: return "source"
        case .markdown, .text: return "document"
        case .checksum: return "checksum"
        case .signature: return "signature"
        case .archive: return "archive"
        case .diskImage, .package, .appBundle: return "installer"
        case .config: return "config"
        case .image, .video, .audio: return "media"
        case .folder, .binary, .unknown: return nil
        }
    }

    static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst",
        "siz", "szs", "xip",
        // 长尾压缩 / 容器(常见但之前漏 → 落 unknown,污染泛化桶)
        "lz", "tlz", "lz4", "lzma", "lzo", "br", "z", "cpio", "ar", "cab", "arj", "lha", "lzh", "zipx"
    ]
    static let sourceExtensions: Set<String> = [
        "swift", "py", "js", "ts", "go", "rs", "c", "cpp", "h", "hpp",
        "java", "kt", "rb", "cs", "m", "mm", "php", "scala", "sh",
        // web / 现代前端
        "jsx", "tsx", "mjs", "cjs", "vue", "svelte", "astro", "html", "htm", "css",
        "sass", "scss", "less", "styl", "coffee",
        // 现代 / 系统 / 函数式 / JVM / 脚本语言
        "dart", "lua", "r", "jl", "ex", "exs", "erl", "hrl", "clj", "cljs", "cljc", "edn",
        "hs", "lhs", "elm", "ml", "mli", "fs", "fsx", "fsi", "nim", "zig", "v", "d", "pas",
        "f90", "f95", "asm", "s", "vala", "groovy", "gradle", "kts", "rake",
        "pl", "pm", "tcl", "vb", "vbs", "applescript",
        "bash", "zsh", "fish", "ps1", "psm1", "bat", "cmd",
        // 数据 / 接口 / 模板语言
        "sql", "proto", "graphql", "gql", "sol", "hx", "jsonnet", "ipynb", "tex",
        "gemspec", "podspec"
    ]
    static let configExtensions: Set<String> = [
        "yaml", "yml", "json", "toml", "ini", "conf", "cfg", "plist", "xml", "env", "properties",
        // 锁文件 / 包清单 / dotfile 配置 / 构建与基础设施配置
        "lock", "sum", "mod", "editorconfig", "gitignore", "gitattributes", "dockerignore",
        "npmrc", "nvmrc", "yarnrc", "babelrc", "eslintrc", "prettierrc", "stylelintrc", "browserslistrc",
        "xcconfig", "entitlements", "pbxproj", "resolved",
        "cmake", "mk", "ninja", "bazel", "bzl", "tf", "tfvars", "hcl", "nix",
        "service", "desktop", "htaccess", "settings", "prefs"
    ]
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp",
        "svg", "ico", "icns", "psd", "ai", "eps", "raw", "cr2", "cr3", "nef", "arw", "dng",
        "avif", "jfif", "jp2", "jpe", "tga", "exr", "hdr", "pict"
    ]
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm",
        "mpg", "mpeg", "wmv", "flv", "3gp", "3g2", "mts", "m2ts", "ogv", "vob", "f4v",
        "rm", "rmvb", "divx", "asf", "mxf"
    ]
    static let audioExtensions: Set<String> = [
        "mp3", "wav", "flac", "aac", "m4a",
        "ogg", "oga", "opus", "wma", "aiff", "aif", "alac", "mid", "midi", "ape",
        "dsf", "dff", "ac3", "amr", "m4b", "caf", "wv"
    ]
    static let signatureExtensions: Set<String> = ["asc", "sig"]
    static let checksumExtensions: Set<String> = ["sha256", "sha1", "md5", "sums"]
    static let binaryExtensions: Set<String> = [
        "o", "a", "so", "dylib", "bin", "exe", "dll", "wasm",
        // 编译产物 / 字节码 / 调试符号
        "class", "pyc", "pyo", "pyd", "lib", "obj", "node", "ko", "elf", "out",
        "swiftmodule", "bc", "pdb", "rlib",
        // 安装包 / 语言包(二进制制品,非用户日常浏览的归档)
        "deb", "rpm", "msi", "appimage", "snap", "flatpak", "nupkg", "whl", "egg"
    ]
    static let checksumNames: Set<String> = ["sha256sums", "sha256sums.txt", "sha1sums", "md5sums", "checksums.txt"]
    /// 目录型 bundle 后缀(macOS 包/工程目录)。命中 → `.package`(不当普通文件夹聚类)。
    static let packageBundleSuffixes: [String] = [
        ".bundle", ".framework", ".pkg", ".xcodeproj", ".xcworkspace", ".playground",
        ".docset", ".photoslibrary", ".rtfd", ".scptd", ".kext", ".plugin", ".prefpane",
        ".qlgenerator", ".appex", ".xpc", ".mdimporter"
    ]
}

/// 端上模型给一个文件挑的一条**结构化建议动作**(②c)。`token` = 动作种类(`allowedSuggestionDescriptors.id` 子集
/// + openWith / openActivity / revealArchiveEntry / dragToApplications…);`payload` = App 安全回查的负载
/// (openWith→app bundleId、activity→taskId、包内文件→entryPath、dmg→.app 路径);`label` = 给人看的补充
/// (openWith 的 app 名「Preview」)。**模型不拼路径** —— payload 由 App 按模型的选择安全合成。
nonisolated struct AIFileSuggestedAction: Codable, Equatable, Sendable {
    let token: String
    let payload: String?
    let label: String?

    init(token: String, payload: String? = nil, label: String? = nil) {
        self.token = token
        self.payload = payload
        self.label = label
    }
}

/// 安全文本文件的短摘要(仅深度本地上下文)。内容由 App 侧先 redaction 再填这里。
///
/// 两个阶段填充:① 后台预读时确定性抽 `headings` / `fieldNames` / `languageHint`(结构信号,聚类用);
/// ② **②b/②c 模型驱动建议** —— 只对「AI 建议评分近显示阈值」的文件,端上本地模型再产出 `shortSummary`
/// (给人看的一句话)+ `suggestedActions`(模型挑的结构化建议动作)。没过阈值 / 模型没产出 = 两者皆空,
/// 文件浏览器据此**空抽屉**(拒绝假AI:界面只显示模型说的,任何代码不凌驾于模型)。
nonisolated struct AIFileContentSummary: Codable, Equatable, Sendable {
    /// `metadata-only` / `text-summary` / `blocked-due-to-sensitive-content`。
    let mode: String
    let languageHint: String?
    let headings: [String]
    let fieldNames: [String]
    /// 端上模型产出的一句话摘要(②b)。仅近阈值文件由后台模型回填;nil = 还没产出 / 没过门控。
    let shortSummary: String?
    /// 端上模型给这个文件挑的**结构化建议动作**(②c)。空 = 模型没建议动作。
    let suggestedActions: [AIFileSuggestedAction]
    /// 用户点击建议动作后的按需只读结果。key = 建议 token(`hash` / 以后复用的 `test` / `inspect`),
    /// value = 抽屉内联显示文本。模型仍只决定是否出现原始 token;结果只是该 token 的本地执行回填。
    let inlineResults: [String: String]
    let redactionCount: Int

    init(mode: String, languageHint: String? = nil, headings: [String] = [], fieldNames: [String] = [],
         shortSummary: String? = nil, suggestedActions: [AIFileSuggestedAction] = [],
         inlineResults: [String: String] = [:], redactionCount: Int = 0) {
        self.mode = mode
        self.languageHint = languageHint
        self.headings = headings
        self.fieldNames = fieldNames
        self.shortSummary = shortSummary
        self.suggestedActions = suggestedActions
        self.inlineResults = inlineResults
        self.redactionCount = redactionCount
    }

    private enum CodingKeys: String, CodingKey {
        case mode, languageHint, headings, fieldNames, shortSummary
        case suggestedActions, suggestedActionTokens   // 后者:旧缓存的 [String] token,迁移用
        case inlineResults
        case redactionCount
    }

    /// 旧缓存兼容:有 `suggestedActions`(结构化)就用它;否则把旧 `suggestedActionTokens`([String])升级成
    /// 无 payload 的结构化动作;都没有 → []。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try c.decode(String.self, forKey: .mode)
        self.languageHint = try c.decodeIfPresent(String.self, forKey: .languageHint)
        self.headings = try c.decodeIfPresent([String].self, forKey: .headings) ?? []
        self.fieldNames = try c.decodeIfPresent([String].self, forKey: .fieldNames) ?? []
        self.shortSummary = try c.decodeIfPresent(String.self, forKey: .shortSummary)
        if let actions = try c.decodeIfPresent([AIFileSuggestedAction].self, forKey: .suggestedActions) {
            self.suggestedActions = actions
        } else {
            let legacy = try c.decodeIfPresent([String].self, forKey: .suggestedActionTokens) ?? []
            self.suggestedActions = legacy.map { AIFileSuggestedAction(token: $0) }
        }
        self.inlineResults = try c.decodeIfPresent([String: String].self, forKey: .inlineResults) ?? [:]
        self.redactionCount = try c.decodeIfPresent(Int.self, forKey: .redactionCount) ?? 0
    }

    /// 只编码新字段(旧 `suggestedActionTokens` 不再写出,只在解码侧兼容)。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(languageHint, forKey: .languageHint)
        try c.encode(headings, forKey: .headings)
        try c.encode(fieldNames, forKey: .fieldNames)
        try c.encodeIfPresent(shortSummary, forKey: .shortSummary)
        try c.encode(suggestedActions, forKey: .suggestedActions)
        try c.encode(inlineResults, forKey: .inlineResults)
        try c.encode(redactionCount, forKey: .redactionCount)
    }

    /// 单文件总结 pass 负责的动作 token(内容类 + openWith);别的 pass(活动 openTask、磁盘镜像 dragToApplications)
    /// 写的动作不在此列,合并时要保留 —— 否则总结 pass 重写会把它们清掉。
    static let summaryOwnedActionTokens: Set<String> = ["hash", "compress", "test", "inspect", "convert", "openWith"]
    /// 只用于内部去重 / 计数,不会渲染成抽屉动作的 marker。
    static let hiddenActionTokens: Set<String> = ["archiveKind"]

    /// 回填模型短摘要 + 结构化建议动作(②b/②c:近阈值文件由后台模型产出后写回,结构信号 / 元数据不变)。
    /// **只替换本 pass 负责的动作**(`summaryOwnedActionTokens`),别的 pass 写的(openTask 活动 / dragToApplications)原样保留。
    func withModelSuggestion(summary: String?, actions: [AIFileSuggestedAction]) -> AIFileContentSummary {
        let preserved = suggestedActions.filter { !AIFileContentSummary.summaryOwnedActionTokens.contains($0.token) }
        return AIFileContentSummary(mode: mode, languageHint: languageHint, headings: headings, fieldNames: fieldNames,
                                    shortSummary: summary, suggestedActions: actions + preserved,
                                    inlineResults: inlineResults, redactionCount: redactionCount)
    }

    /// 合并一条带 payload 的单例动作(活动 openTask、磁盘镜像 dragToApplications…):按 token 去掉旧的、加上新的
    /// (`action` 为 nil = 清掉),其它 pass 写的动作 + 摘要不动。给「活动链接」「磁盘镜像」等独立 pass 回填用。
    func mergingSingletonAction(_ action: AIFileSuggestedAction?, replacingToken token: String,
                                shortSummaryIfEmpty newSummary: String? = nil) -> AIFileContentSummary {
        var actions = suggestedActions.filter { $0.token != token }
        if let action { actions.append(action) }
        let summary = (shortSummary?.isEmpty == false) ? shortSummary : newSummary
        return AIFileContentSummary(mode: mode, languageHint: languageHint, headings: headings, fieldNames: fieldNames,
                                    shortSummary: summary, suggestedActions: actions,
                                    inlineResults: inlineResults, redactionCount: redactionCount)
    }

    /// 归档清单类 pass 的合并:包内文件建议可产出多条 `revealArchiveEntry`;归档定性只产一条摘要 + `archiveKind`
    /// marker。两者都来自归档清单缓存,但互不覆盖。
    func mergingArchiveEntryActions(_ actions: [AIFileSuggestedAction]) -> AIFileContentSummary {
        let preserved = suggestedActions.filter { $0.token != "revealArchiveEntry" }
        return AIFileContentSummary(mode: "archive-entries", languageHint: languageHint, headings: headings,
                                    fieldNames: fieldNames, shortSummary: shortSummary,
                                    suggestedActions: preserved + actions,
                                    inlineResults: inlineResults, redactionCount: redactionCount)
    }

    /// 回填某个建议 token 的按需执行结果(例如 `hash` → SHA-256 文本),不改动模型摘要或其它动作。
    func withInlineResult(token: String, text: String) -> AIFileContentSummary {
        var results = inlineResults
        results[token] = text
        return AIFileContentSummary(mode: mode, languageHint: languageHint, headings: headings,
                                    fieldNames: fieldNames, shortSummary: shortSummary,
                                    suggestedActions: suggestedActions, inlineResults: results,
                                    redactionCount: redactionCount)
    }

    /// 是否已有模型产出(摘要或建议动作)→ 文件浏览器据此决定是否展示 AI 抽屉(都没有 = 空抽屉、不展开)。
    var hasModelSuggestion: Bool {
        (shortSummary?.isEmpty == false)
            || suggestedActions.contains { !AIFileContentSummary.hiddenActionTokens.contains($0.token) }
            || !inlineResults.isEmpty
    }

    /// 取某 token 的建议动作(给「已有 openTask 指向同一任务就跳过」这类去重判断用)。
    func action(forToken token: String) -> AIFileSuggestedAction? {
        suggestedActions.first { $0.token == token }
    }
}

/// 后台文件索引的每目录角色采样策略。防止 document/reference 这类高频角色占满候选池,同时给 installer/source 等
/// 角色保留稳定曝光空间。调用方为每个被列举目录维护一份 `counts`。
nonisolated enum AIFileRoleSamplingPolicy {
    static let perDirectoryCaps: [String: Int] = [
        "document": 10,
        "reference-data": 30,
        "release-notes": 5,
        "integrity-data": 5,
        "project-doc": 5,
        "installer": 20,
        "source": 50,
    ]

    static func reserve(_ roleTags: [String], counts: inout [String: Int]) -> Bool {
        guard let cappedRole = roleTags.first(where: { perDirectoryCaps[$0] != nil }),
              let cap = perDirectoryCaps[cappedRole] else {
            return true
        }
        let current = counts[cappedRole, default: 0]
        guard current < cap else { return false }
        counts[cappedRole] = current + 1
        return true
    }
}

/// 单个文件 / 子目录的 AI 记忆记录。**不含完整路径** —— 用稳定 id + 文件名 + 低敏位置上下文。
nonisolated struct AIFileMemoryRecord: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let fileName: String
    /// 文件的完整路径(**非加密路径不是安全风险**——AI 本就能读非加密内容,知道路径没问题;给「显示来源目录 +
    /// 在 Finder 显示 / 哈希 / 测试」用)。可选:旧记录 / 无路径来源解码为 nil。
    let path: String?
    let fileExtension: String?
    let type: AIFileType
    let byteSize: Int64?
    let modifiedAt: Date?
    let location: AILocationContext
    let roleTags: [String]
    let markerTags: [String]
    let relatedSourceRefs: [AIContextSourceRef]
    let contentSummary: AIFileContentSummary?
    let omissions: [AIContextOmission]

    /// 从文件名 + 元数据确定性派生一条记录。`location` 是文件所在目录的低敏上下文。
    static func make(fileName: String, isDirectory: Bool, byteSize: Int64?, modifiedAt: Date?,
                     location: AILocationContext, relatedSourceRefs: [AIContextSourceRef] = [],
                     contentSummary: AIFileContentSummary? = nil, path: String? = nil) -> AIFileMemoryRecord {
        let safeName = AISensitiveRedactor.redactFileNameSecrets((fileName as NSString).lastPathComponent)
        let type = AIFileType.classify(fileName: fileName, isDirectory: isDirectory)
        let ext = isDirectory ? nil : {
            let e = (fileName as NSString).pathExtension.lowercased()
            return e.isEmpty ? nil : e
        }()
        let markers = AIFolderProfile.markerTags(forFileName: fileName)
        return AIFileMemoryRecord(
            id: "file-" + AIStableHash.fnv1a32Hex(location.pathHash + "/" + safeName),
            fileName: safeName,
            path: path,
            fileExtension: ext,
            type: type,
            byteSize: byteSize,
            modifiedAt: modifiedAt,
            location: location,
            roleTags: AIFileType.roleTags(fileName: fileName, isDirectory: isDirectory, type: type),
            markerTags: markers,
            relatedSourceRefs: relatedSourceRefs,
            contentSummary: contentSummary,
            omissions: [])
    }

    /// 这条记录对应的 source ref(候选 / 路径回查共用同一份,保证 key 一致)。
    var contextSourceRef: AIContextSourceRef {
        let kind: AIContextSourceRef.Kind = type == .folder ? .folder : (type == .archive ? .archive : .file)
        return AIContextSourceRef(kind: kind, id: id)
    }

    /// 不可变拷贝,挂上内容摘要(后台「先全量轻索引、再对 AI 选中集补摘要」两阶段用 —— 元数据记录先建,
    /// 选中后再回填 `contentSummary`,id / 其余字段不变)。
    func withContentSummary(_ summary: AIFileContentSummary) -> AIFileMemoryRecord {
        AIFileMemoryRecord(
            id: id, fileName: fileName, path: path, fileExtension: fileExtension, type: type,
            byteSize: byteSize, modifiedAt: modifiedAt, location: location, roleTags: roleTags,
            markerTags: markerTags, relatedSourceRefs: relatedSourceRefs,
            contentSummary: summary, omissions: omissions)
    }
}

/// 一个目录的画像。从其(已索引的)子文件记录确定性派生角色 + 推荐视角。
nonisolated struct AIFolderProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let location: AILocationContext
    let directChildCount: Int
    let totalIndexedDescendants: Int
    /// 主导文件类型(rawValue,count 降序)。
    let dominantFileTypes: [String]
    let markerFiles: [String]
    /// 文件夹角色(release / source / test / backup / signed / config)。
    let roleTags: [String]
    let relatedArchives: [AIContextSourceRef]
    let relatedTasks: [AIContextSourceRef]
    /// 推荐 Lens(AILens rawValue)。
    let suggestedLenses: [String]
    let omissions: [AIContextOmission]

    /// 从子文件记录派生目录画像。`displayName` 经脱敏;角色由 marker / 类型 / 目录名 token 规则判定。
    static func derive(displayName: String, location: AILocationContext,
                       files: [AIFileMemoryRecord], totalIndexedDescendants: Int? = nil,
                       relatedArchives: [AIContextSourceRef] = [],
                       relatedTasks: [AIContextSourceRef] = []) -> AIFolderProfile {
        // 主导类型分布。
        var typeCounts: [AIFileType: Int] = [:]
        for f in files { typeCounts[f.type, default: 0] += 1 }
        let dominant = typeCounts
            .map { (type: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.type.rawValue < $1.type.rawValue }
            .prefix(6)
            .map { $0.type.rawValue }

        // marker 文件(原始脱敏名,去重升序)。
        let markerFiles = Array(Set(files.flatMap { f in
            markerTags(forFileName: f.fileName).isEmpty ? [] : [f.fileName]
        })).sorted()

        // 角色判定(固定规则顺序 → 确定性)。
        let typesPresent = Set(files.map(\.type))
        let markerTokens = Set(files.flatMap { markerTags(forFileName: $0.fileName) })
        let folderTokens = Set(location.folderNameTokens)
        var roles: [String] = []
        func add(_ r: String) { if !roles.contains(r) { roles.append(r) } }

        let hasChecksum = typesPresent.contains(.checksum)
        let hasSignature = typesPresent.contains(.signature)
        let hasReleaseLike = typesPresent.contains(.diskImage) || typesPresent.contains(.appBundle)
            || markerTokens.contains("sha256sums")
        if (hasChecksum && (hasSignature || hasReleaseLike)) || (hasReleaseLike && hasChecksum) {
            add("release")
        }
        if markerTokens.contains("package.swift") || markerTokens.contains("package.json")
            || markerTokens.contains("pyproject.toml") || typesPresent.contains(.sourceCode) {
            add("source")
        }
        if hasSignature || markerTokens.contains("signature.asc")
            || files.contains(where: { ["siz", "szs"].contains($0.fileExtension) }) {
            add("signed")
        }
        if folderTokens.contains("test") || folderTokens.contains("tests") || folderTokens.contains("fixture") {
            add("test")
        }
        if folderTokens.contains("backup") || folderTokens.contains("backups") {
            add("backup")
        }
        let configCount = typeCounts[.config] ?? 0
        if !files.isEmpty, Double(configCount) / Double(files.count) >= 0.4, !roles.contains("source") {
            add("config")
        }

        // 角色 → 推荐 Lens。
        var lenses: [String] = []
        func addLens(_ l: AILens) { if !lenses.contains(l.rawValue) { lenses.append(l.rawValue) } }
        for role in roles {
            switch role {
            case "release": addLens(.release); addLens(.signing)
            case "source": addLens(.source)
            case "signed": addLens(.signing)
            case "backup": addLens(.cleanup)
            default: break
            }
        }

        return AIFolderProfile(
            id: "folder-" + location.pathHash,
            displayName: AISensitiveRedactor.redactFileNameSecrets(displayName),
            location: location,
            directChildCount: files.count,
            totalIndexedDescendants: totalIndexedDescendants ?? files.count,
            dominantFileTypes: Array(dominant),
            markerFiles: markerFiles,
            roleTags: roles,
            relatedArchives: relatedArchives,
            relatedTasks: relatedTasks,
            suggestedLenses: lenses,
            omissions: [])
    }

    /// 一个文件名命中的 marker token(小写 basename)。
    static func markerTags(forFileName fileName: String) -> [String] {
        let base = ((fileName as NSString).lastPathComponent).lowercased()
        return markerBasenames.contains(base) ? [base] : []
    }

    private static let markerBasenames: Set<String> = [
        "readme.md", "readme", "readme.txt", "license", "license.md", "license.txt",
        "package.swift", "package.json", "pyproject.toml", "cargo.toml", "go.mod",
        "sha256sums", "sha256sums.txt", "verify.md", "signature.asc", "public_key.asc",
        "changelog.md", "makefile", "dockerfile"
    ]
}

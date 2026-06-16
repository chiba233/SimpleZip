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
            if lowerDir.hasSuffix(".bundle") || lowerDir.hasSuffix(".framework") || lowerDir.hasSuffix(".pkg") {
                return .package
            }
            return .folder
        }
        let lower = fileName.lowercased()
        let base = (lower as NSString).lastPathComponent
        let ext = (lower as NSString).pathExtension

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
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "zst", "tzst", "siz", "szs", "xip"
    ]
    static let sourceExtensions: Set<String> = [
        "swift", "py", "js", "ts", "go", "rs", "c", "cpp", "h", "hpp",
        "java", "kt", "rb", "cs", "m", "mm", "php", "scala", "sh"
    ]
    static let configExtensions: Set<String> = [
        "yaml", "yml", "json", "toml", "ini", "conf", "cfg", "plist", "xml", "env", "properties"
    ]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm"]
    static let audioExtensions: Set<String> = ["mp3", "wav", "flac", "aac", "m4a"]
    static let signatureExtensions: Set<String> = ["asc", "sig"]
    static let checksumExtensions: Set<String> = ["sha256", "sha1", "md5", "sums"]
    static let binaryExtensions: Set<String> = ["o", "a", "so", "dylib", "bin", "exe", "dll", "wasm"]
    static let checksumNames: Set<String> = ["sha256sums", "sha256sums.txt", "sha1sums", "md5sums", "checksums.txt"]
}

/// 安全文本文件的短摘要(仅深度本地上下文)。内容由 App 侧先 redaction 再填这里。
nonisolated struct AIFileContentSummary: Codable, Equatable, Sendable {
    /// `metadata-only` / `text-summary` / `blocked-due-to-sensitive-content`。
    let mode: String
    let languageHint: String?
    let headings: [String]
    let fieldNames: [String]
    let shortSummary: String?
    let redactionCount: Int

    init(mode: String, languageHint: String? = nil, headings: [String] = [], fieldNames: [String] = [],
         shortSummary: String? = nil, redactionCount: Int = 0) {
        self.mode = mode
        self.languageHint = languageHint
        self.headings = headings
        self.fieldNames = fieldNames
        self.shortSummary = shortSummary
        self.redactionCount = redactionCount
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

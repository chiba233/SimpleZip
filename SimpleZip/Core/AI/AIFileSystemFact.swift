//
//  AIFileSystemFact.swift
//  SimpleZip
//
//  0.4.5 #80:统一文件系统事实(白皮书「红线和数据权限」 581-627)。供 AI 工作区、活动中心、归档查找、
//  创建/解压建议和后台索引**复用同一份富文件事实** —— 不再每个场景各自拼一套字段。
//
//  和 `AIFileMemoryRecord` 的分工:`AIFileMemoryRecord` 是**轻量、可持久、不含完整路径**的索引记录(后台
//  预索引派生);`AIFileSystemFact` 是**当前上下文的富事实** —— 允许完整路径(白皮书:本机模型,当前上下文
//  路径不是禁区),并带权限(POSIX mode / owner / group / 当前用户可读写执行)、UTType、是否包/应用/符号链、
//  默认打开方式、候选打开 App,以及最关键的**可读性门控** `contentReadableByAI` / `contentEnrichmentAllowed`。
//
//  白皮书把「权限 / owner / 默认打开方式」明确列为本地文件管理事实而非隐私红线;红线只有口令 / 密钥材料 /
//  加密条目名 / 密文 / 解密明文 / **没有读取权限的文件内容**。本层只组装确定性事实 + 应用可读性策略,**不读
//  文件系统**(真实 stat / LaunchServices 查询由 App 侧 `FileBrowserService` / `FilePermissionsEditor` /
//  `ArchiveAssociationService` 提供)。纯值类型 + 确定性,SwiftPM 可断言。
//

import Foundation

/// 文件内容可读性的**确定性策略**。决定 AI 能不能读取一个文件的内容(深度 marker 摘要),以及为什么不能。
///
/// 即使 `contentReadableByAI == false`,低敏统计仍可用(路径、父目录、权限、UTType、默认打开方式、失败原因)——
/// 支持「同目录下文件都失败」「这个文件没有读取权限所以无法索引」「这批文件默认走 VS Code」这类工作区判断。
nonisolated enum AIFileReadabilityPolicy {
    /// 内容不可读的原因(稳定英文 token,写进 omission.policy)。
    nonisolated enum BlockReason: String, Codable, Equatable, Sendable {
        case noReadPermission = "no_read_permission"
        case sensitiveDirectory = "sensitive_directory"
        case decryptTempDirectory = "decrypt_temp_directory"
        case sensitiveFilename = "sensitive_filename"
        case excludedByUser = "excluded_by_user"
    }

    /// 判定一个文件内容是否可被 AI 读取(深度 marker 摘要)。返回 nil = 可读;返回原因 = 被挡。
    /// 顺序固定 → 确定性。先看权限,再看敏感目录 / 临时解密目录 / 用户排除,最后看疑似密钥文件名。
    static func blockReason(absolutePath: String, fileName: String,
                            currentUserCanRead: Bool, isExcludedByUser: Bool) -> BlockReason? {
        if !currentUserCanRead { return .noReadPermission }
        if isExcludedByUser { return .excludedByUser }
        if isSensitiveDirectory(absolutePath) { return .sensitiveDirectory }
        if isDecryptOrTempPath(absolutePath) { return .decryptTempDirectory }
        if looksLikeSecret(fileName: fileName) { return .sensitiveFilename }
        return nil
    }

    /// 路径落在密钥 / 凭据 / 密码库目录:`.ssh`、`.gnupg`、`.aws`、`.kube`、Keychain、password-store 等。
    static func isSensitiveDirectory(_ path: String) -> Bool {
        let lower = path.lowercased()
        return sensitiveDirectoryFragments.contains { lower.contains($0) }
    }

    /// 系统临时目录 / 解密暂存目录 —— 内容绝不进入 AI(解密明文可能落在这里)。
    static func isDecryptOrTempPath(_ path: String) -> Bool {
        path.contains("/SimpleZip-")
            || path.hasPrefix("/private/var/folders/")
            || path.hasPrefix("/var/folders/")
            || path.hasPrefix("/private/tmp/")
            || path.hasPrefix("/tmp/")
    }

    /// 文件名疑似密钥 / 证书私钥 / token / 密码库 / 密文(扩展名或名字 token 命中)。
    static func looksLikeSecret(fileName: String) -> Bool {
        let base = ((fileName as NSString).lastPathComponent).lowercased()
        let ext = (base as NSString).pathExtension
        if secretExtensions.contains(ext) { return true }
        return secretNameNeedles.contains { base.contains($0) }
    }

    /// 一个文件是否适合做内容增强(深度文本 marker 摘要)。要求内容可读 + 类型是文本类(README / manifest /
    /// 配置 / 源码 / 校验文件)。二进制 / 图片 / 视频 / 归档 / 应用包默认只索引元数据,不读内容。
    static func enrichable(type: AIFileType, contentReadable: Bool) -> Bool {
        guard contentReadable else { return false }
        switch type {
        case .text, .markdown, .sourceCode, .config, .checksum:
            return true
        case .folder, .archive, .signature, .image, .video, .audio,
             .appBundle, .diskImage, .package, .binary, .unknown:
            return false
        }
    }

    /// 密钥 / 证书 / 密文 / 密码库扩展名。注意 `gpg` / `asc` 内容(密文 / 密钥材料)绝不读,但文件名 / 类型可用。
    static let secretExtensions: Set<String> = [
        "key", "pem", "p12", "pfx", "keychain", "keychain-db",
        "gpg", "asc", "kdbx", "agilekeychain", "ppk", "jks", "ovpn"
    ]
    /// 文件名子串命中即视为疑似密钥 / 凭据。
    static let secretNameNeedles: [String] = [
        "password", "passwd", "secret", "token", "credential", "private_key", "privatekey",
        "id_rsa", "id_ed25519", "id_dsa", "id_ecdsa", ".env", "apikey", "api_key", "vault"
    ]

    private static let sensitiveDirectoryFragments: [String] = [
        "/.ssh/", "/.gnupg/", "/.aws/", "/.kube/", "/.docker/", "/.password-store/",
        "/library/keychains/", "/.config/gh/", "/.netrc"
    ]
}

/// 一个文件 / 文件夹的统一 AI 事实(当前上下文)。完整路径用于 App 侧动作回查(打开 / 定位);进 prompt 的
/// 子集由各 builder 决定。`displayName` 已脱敏;`contentReadableByAI == false` 时 `omissions` 说明原因。
nonisolated struct AIFileSystemFact: Codable, Equatable, Sendable {
    /// 可回查的来源引用(目录用 `.folder`,文件用 `.file`)。
    let sourceRef: AIContextSourceRef
    /// 完整绝对路径 —— 当前上下文允许(本机模型);长期学习改用 `AIFileMemoryRecord`(只存 location/hash)。
    let absolutePath: String
    /// 路径稳定哈希(非加密、低暴露,同路径逐次一致)。
    let pathHash: String
    /// 父目录稳定哈希 —— 判断「同目录」关系(同目录连续失败 / 同项目根)。
    let parentPathHash: String
    /// 所在目录的低敏位置上下文。
    let location: AILocationContext
    /// 脱敏后的显示名(疑似口令的文件名被抹)。
    let displayName: String
    /// 小写扩展名(目录为空串)。
    let fileExtension: String
    let utTypeIdentifier: String?
    let kindDescription: String?
    let byteSize: Int64?
    let modifiedAt: Date?
    let createdAt: Date?
    let lastOpenedAt: Date?
    let lastIndexedAt: Date?
    // 权限事实(白皮书:不是隐私红线,是本地文件管理事实)。
    let ownerName: String?
    let groupName: String?
    /// POSIX mode 字符串,如 `rw-r--r--` 或 `0644`(由 App 侧格式化后传入)。
    let posixMode: String
    let currentUserCanRead: Bool
    let currentUserCanWrite: Bool
    let currentUserCanExecute: Bool
    let isDirectory: Bool
    let isPackage: Bool
    let isApplicationBundle: Bool
    let isSymlink: Bool
    let isHardlinkCandidate: Bool
    // 默认 / 候选打开方式(LaunchServices,由 App 侧查询后传入)。
    let defaultOpenAppBundleID: String?
    let defaultOpenAppName: String?
    let availableOpenAppBundleIDs: [String]
    /// 工作区限定打开 App(例如这组源码默认用 VS Code / Xcode)。
    let preferredWorkspaceOpenAppBundleID: String?
    /// 角色标签(由文件类型确定性派生:source / document / checksum / signature / archive / installer / config / media)。
    let roleTags: [String]
    /// 同目录失败分组 id —— 把「同一目录下都失败」的文件归一组(由上层失败聚合传入)。
    let sameDirectoryFailureGroupID: String?
    /// 项目根提示(由上层 marker 判定传入)。
    let projectRootHint: String?
    /// AI 是否可读取此文件内容。无读权限 / 敏感目录 / 临时解密目录 / 疑似密钥 / 用户排除时为 false。
    let contentReadableByAI: Bool
    /// 是否允许做内容增强(深度 marker 摘要)。要求可读 + 文本类。
    let contentEnrichmentAllowed: Bool
    let omissions: [AIContextOmission]

    /// 从 App 侧提供的真实文件系统值确定性组装一条事实。**本工厂不读文件系统** —— 所有 stat / LaunchServices /
    /// owner 值由调用点(`FileBrowserService` / `FilePermissionsEditor` / `ArchiveAssociationService`)传入。
    ///
    /// 自动完成:显示名脱敏、扩展名归一、类型→角色标签、路径哈希、可读性门控 + 对应 omission。
    static func make(
        absolutePath: String,
        location: AILocationContext,
        byteSize: Int64? = nil,
        modifiedAt: Date? = nil,
        createdAt: Date? = nil,
        lastOpenedAt: Date? = nil,
        lastIndexedAt: Date? = nil,
        utTypeIdentifier: String? = nil,
        kindDescription: String? = nil,
        ownerName: String? = nil,
        groupName: String? = nil,
        posixMode: String,
        currentUserCanRead: Bool,
        currentUserCanWrite: Bool,
        currentUserCanExecute: Bool,
        isDirectory: Bool,
        isPackage: Bool = false,
        isApplicationBundle: Bool = false,
        isSymlink: Bool = false,
        isHardlinkCandidate: Bool = false,
        defaultOpenAppBundleID: String? = nil,
        defaultOpenAppName: String? = nil,
        availableOpenAppBundleIDs: [String] = [],
        preferredWorkspaceOpenAppBundleID: String? = nil,
        sameDirectoryFailureGroupID: String? = nil,
        projectRootHint: String? = nil,
        isExcludedFromAI: Bool = false
    ) -> AIFileSystemFact {
        let canonical = standardize(absolutePath)
        let rawName = (canonical as NSString).lastPathComponent
        let parentDir = (canonical as NSString).deletingLastPathComponent
        let safeName = AISensitiveRedactor.redactFileNameSecrets(rawName)
        let ext = isDirectory ? "" : (rawName as NSString).pathExtension.lowercased()
        let type = AIFileType.classify(fileName: rawName, isDirectory: isDirectory)

        let block = AIFileReadabilityPolicy.blockReason(
            absolutePath: canonical, fileName: rawName,
            currentUserCanRead: currentUserCanRead, isExcludedByUser: isExcludedFromAI)
        let readable = (block == nil)
        let enrichable = AIFileReadabilityPolicy.enrichable(type: type, contentReadable: readable)

        var omissions: [AIContextOmission] = []
        if let block {
            omissions.append(AIContextOmission(type: "file_content", policy: block.rawValue))
        }

        return AIFileSystemFact(
            sourceRef: AIContextSourceRef(kind: isDirectory ? .folder : .file,
                                          id: "fs-" + AIStableHash.fnv1a32Hex(canonical)),
            absolutePath: canonical,
            pathHash: "fp-" + AIStableHash.fnv1a32Hex(canonical),
            parentPathHash: "fp-" + AIStableHash.fnv1a32Hex(parentDir),
            location: location,
            displayName: safeName,
            fileExtension: ext,
            utTypeIdentifier: utTypeIdentifier,
            kindDescription: kindDescription,
            byteSize: byteSize,
            modifiedAt: modifiedAt,
            createdAt: createdAt,
            lastOpenedAt: lastOpenedAt,
            lastIndexedAt: lastIndexedAt,
            ownerName: ownerName,
            groupName: groupName,
            posixMode: posixMode,
            currentUserCanRead: currentUserCanRead,
            currentUserCanWrite: currentUserCanWrite,
            currentUserCanExecute: currentUserCanExecute,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isApplicationBundle: isApplicationBundle,
            isSymlink: isSymlink,
            isHardlinkCandidate: isHardlinkCandidate,
            defaultOpenAppBundleID: defaultOpenAppBundleID,
            defaultOpenAppName: defaultOpenAppName,
            availableOpenAppBundleIDs: availableOpenAppBundleIDs,
            preferredWorkspaceOpenAppBundleID: preferredWorkspaceOpenAppBundleID,
            roleTags: type.roleTag.map { [$0] } ?? [],
            sameDirectoryFailureGroupID: sameDirectoryFailureGroupID,
            projectRootHint: projectRootHint,
            contentReadableByAI: readable,
            contentEnrichmentAllowed: enrichable,
            omissions: omissions)
    }

    /// 标准化路径(展开 ~,去尾随 /)。空 / 纯空白短路返回 ""(避免 URL 解析成 CWD,沿用 AILocationClassifier 口径)。
    private static func standardize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}

//
//  IntentsExtensionSupport.swift
//  SimpleZipIntentsExtension
//
//  扩展进程里所有 intent 的共享支撑:错误类型、**沙箱安全作用域**文件访问、签名容器直通、极小解压、
//  7zz 定位、Shortcuts 暴露的枚举。扩展是沙箱进程(macOS 强制 App Intents 扩展沙箱化才注册),所以:
//  ① 访问 IntentFile 给的用户文件**必须** `startAccessingSecurityScopedResource`(否则读不到);
//  ② 子进程 7zz 用扩展**自带**的那份(打进 .appex/Contents/Resources,见 ensureBundled7zzPathForExtension),
//     不依赖「沙箱能否读宿主 app 的 7zz」这个不确定项;
//  ③ 不碰 app target 的 TaskCenter / 活动中心 / ProgressCoalescer / SecureScratchVolume / 冲突对话框 ——
//     Shortcuts 是无人值守上下文,极小 Core-only 实现即可。
//

import AppIntents
import Foundation

/// Intent 执行错误:消息原样展示给 Shortcuts 用户(已本地化)。
struct SimpleZipExtensionIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

// MARK: - 沙箱安全作用域文件访问

/// IntentFile → 磁盘 URL(纯解析,不开作用域)。无落盘位置(纯内存数据)明确拒绝 —— 归档操作全部按路径工作。
func extensionIntentFileURL(_ file: IntentFile) throws -> URL {
    guard let url = file.fileURL else {
        throw SimpleZipExtensionIntentError(message: L10n.format("intent.error.noFileURL", file.filename))
    }
    return url
}

/// 取一个 IntentFile 的安全作用域 URL,**在闭包期间持有访问权**(沙箱里读用户文件的刚需),结束自动释放。
/// 文件不存在明确报错。子进程 7zz 在闭包内被拉起 —— 父进程持着该文件的 sandbox 访问扩展,子进程读得到。
func withIntentFileAccess<T>(_ file: IntentFile, _ body: (URL) async throws -> T) async throws -> T {
    ensureBundled7zzPathForExtension()
    let url = try extensionIntentFileURL(file)
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw SimpleZipExtensionIntentError(message: L10n.format("intent.error.missingFile", url.path))
    }
    return try await body(url)
}

/// 一次性为多个 IntentFile 开作用域并在闭包期间持有(多归档批处理用),把解析好的 URL 列表交给闭包。
func withIntentFilesAccess<T>(_ files: [IntentFile], _ body: ([URL]) async throws -> T) async throws -> T {
    ensureBundled7zzPathForExtension()
    var scoped: [URL] = []
    defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
    var urls: [URL] = []
    for file in files {
        let url = try extensionIntentFileURL(file)
        if url.startAccessingSecurityScopedResource() { scoped.append(url) }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SimpleZipExtensionIntentError(message: L10n.format("intent.error.missingFile", url.path))
        }
        urls.append(url)
    }
    return try await body(urls)
}

// MARK: - 加密归档:按需弹口令

/// 本次**没给口令**且后端报「需要口令」→ 该提示用户补口令(intent 里据此 `throw $password.needsValueError(...)`,
/// Shortcuts 会弹输入框、补完自动重跑 perform)。给了口令还失败 = 口令错,不再提示、原样抛错。
/// Shortcuts 常是有人运行的脚本,故支持交互补口令;但绝不去碰(也读不到)app 的预设密码。
func shouldPromptForPassword(_ error: Error, providedPassword: String?) -> Bool {
    (providedPassword?.isEmpty ?? true) && ArchiveService.errorSuggestsPasswordRequirement(error)
}

// MARK: - 签名容器直通(扩展不支持 .siz/.szs)

/// 扩展版「工具可读归档」适配:`.siz` / `.szs` 需 GPG 验签 + 交互式同意 UI,沙箱无人值守扩展里**不支持** ——
/// 明确报错引导去 app 打开。其余普通归档直接把 URL 交给闭包(.xip/.xar 由 ArchiveService 直接处理)。
func withToolAdaptedArchiveExtension<T>(_ url: URL, _ body: (URL) async throws -> T) async throws -> T {
    let ext = url.pathExtension.lowercased()
    if ext == "siz" || ext == "szs" {
        throw SimpleZipExtensionIntentError(message: L10n.text("intent.error.signedContainerUnsupported"))
    }
    return try await body(url)
}

// MARK: - 极小解压(无冲突对话框 / 无 SecureScratch)

/// Shortcuts 用的极小解压:把归档解进 `destinationDir`(没给则解到归档旁)里一个**唯一命名**的文件夹,返回该
/// 文件夹。唯一命名天然避开冲突 → 无需 app 那套冲突对话框;`safetyPolicy: .validate` 仍做路径穿越校验。
/// 口令由调用 intent 的可选参数传入(用户在快捷指令里填,或被 needsValueError 弹窗补);空 = 不加密 / 待提示。
func extractArchiveInExtension(archiveURL: URL, destinationDir: URL?, password: String) async throws -> URL {
    let parent = destinationDir ?? archiveURL.deletingLastPathComponent()
    // 去掉一层扩展名当文件夹名(`foo.zip` → `foo`;`foo.tar.gz` → `foo.tar`,与 app 解压命名一致)。
    let baseName = archiveURL.deletingPathExtension().lastPathComponent
    let preferred = parent.appendingPathComponent(baseName.isEmpty ? "Extracted" : baseName, isDirectory: true)
    let target = UniqueFileName.suffixed(for: preferred, suffix: "") {
        FileManager.default.fileExists(atPath: $0.path)
    }
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    do {
        try await ArchiveService.extract(archiveURL, to: target, password: password, safetyPolicy: .validate)
    } catch {
        try? FileManager.default.removeItem(at: target)
        throw error
    }
    return target
}

// MARK: - 7zz 定位(扩展自带份优先)

/// 扩展进程的 `Bundle.main` 是扩展自己(`…/Contents/Extensions/SimpleZipIntentsExtension.appex`),其 Resources 里
/// **没有** 7zz。沙箱化的 App 扩展可读其**宿主 app bundle** 内的文件(Apple 文档),宿主 7zz 在
/// `…/SimpleZip.app/Contents/Resources/7zz`,已随 app 一起 Developer ID 签名 —— 直接用它,不必把 6MB 二进制
/// 再塞进 .appex(那还得给扩展内 7zz 单独签名+加固,易弄坏公证)。定位后 `setenv SIMPLEZIP_7ZZ_PATH`,
/// `SevenZipBackend.bundledCandidates` 该环境变量优先于一切。幂等;失败静默(退回 SevenZipBackend 的系统 7zz 候选)。
func ensureBundled7zzPathForExtension() {
    guard ProcessInfo.processInfo.environment["SIMPLEZIP_7ZZ_PATH"]?.isEmpty != false else { return }
    var candidates: [URL] = []
    // ① 万一以后把 7zz 打进扩展自己的 Resources,优先用自带份。
    if let res = Bundle.main.resourceURL {
        candidates += [res.appendingPathComponent("Tools/7zz"), res.appendingPathComponent("7zz")]
    }
    // ② 宿主 app 的 Resources:appex → Contents/Extensions → Contents → Resources/7zz(发布版实际位置)。
    let appContents = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    candidates += [
        appContents.appendingPathComponent("Resources/7zz"),
        appContents.appendingPathComponent("Resources/Tools/7zz"),
    ]
    for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
        setenv("SIMPLEZIP_7ZZ_PATH", url.path, 1)
        return
    }
}

// MARK: - Shortcuts 暴露的枚举(映射到 Core,不让 AppIntents 依赖渗进 Core)

/// Shortcuts 暴露的创建格式(创建路径的常用子集;DMG/RAR 依赖外部条件,不进)。
enum IntentArchiveFormat: String, AppEnum {
    case zip, sevenZip, tar, tarGzip

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Archive Format")
    static let caseDisplayRepresentations: [IntentArchiveFormat: DisplayRepresentation] = [
        .zip: "ZIP", .sevenZip: "7-Zip", .tar: "tar", .tarGzip: "tar.gz"
    ]

    var createFormat: ArchiveCreateFormat {
        switch self {
        case .zip: return .zip
        case .sevenZip: return .sevenZip
        case .tar: return .tar
        case .tarGzip: return .tarGzip
        }
    }
}

/// Shortcuts 暴露的哈希算法(映射到 Core 的 `HashAlgorithm`)。
enum IntentHashAlgorithm: String, AppEnum {
    case crc32, md5, sha1, sha256, sha512

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Hash Algorithm")
    static let caseDisplayRepresentations: [IntentHashAlgorithm: DisplayRepresentation] = [
        .crc32: "CRC32", .md5: "MD5", .sha1: "SHA-1", .sha256: "SHA-256", .sha512: "SHA-512"
    ]

    var hashAlgorithm: HashAlgorithm {
        switch self {
        case .crc32: return .crc32
        case .md5: return .md5
        case .sha1: return .sha1
        case .sha256: return .sha256
        case .sha512: return .sha512
        }
    }
}

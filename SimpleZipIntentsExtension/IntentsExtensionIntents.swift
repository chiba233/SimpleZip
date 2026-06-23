//
//  IntentsExtensionIntents.swift
//  SimpleZipIntentsExtension
//
//  在 App Intents 扩展进程里声明的 intent —— 跑在轻量扩展里,**不拉起完整 app**(根治 4101 超时)。
//  只用 SimpleZip/Core(ArchiveService / ArchiveSpaceAnalysis…),不碰 app target 的 UI / TaskCenter。
//  v1 先搬「分析归档空间」一个(Core-only、最干净,且你刚好测的就是它)验证整条链:
//  扩展进程起得快 → 接得上 App Intents 连接窗口 → 非沙箱能 exec 7zz → perform 成功回包。
//  通了再把 Extract / Create / Test 等批量搬进来(那几个的 ExternalExtractRunner / TaskCenter 依赖要在扩展里重写)。
//

import AppIntents
import Foundation

/// Intent 执行错误:消息原样展示给 Shortcuts 用户(已本地化)。
struct SimpleZipExtensionIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// IntentFile → 磁盘 URL。无落盘位置(纯内存数据)明确拒绝 —— 归档操作全部按路径工作。
private func extensionIntentFileURL(_ file: IntentFile) throws -> URL {
    guard let url = file.fileURL else {
        throw SimpleZipExtensionIntentError(message: L10n.format("intent.error.noFileURL", file.filename))
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw SimpleZipExtensionIntentError(message: L10n.format("intent.error.missingFile", url.path))
    }
    return url
}

/// 扩展进程的 `Bundle.main` 是扩展自己(`…/Contents/Extensions/SimpleZipIntentsExtension.appex`),
/// 找不到母 app 内置的 7zz(在 `…/Contents/Resources/Tools/7zz`)。像 CLI 那样(A19)定位母 app 的 7zz
/// 并 `setenv SIMPLEZIP_7ZZ_PATH` —— `SevenZipBackend.bundledCandidates` 该环境变量优先于一切。幂等,失败静默
/// (resolve() 再退回系统 7zz)。
private func ensureBundled7zzPathForExtension() {
    guard ProcessInfo.processInfo.environment["SIMPLEZIP_7ZZ_PATH"]?.isEmpty != false else { return }
    // appex → Contents/Extensions → Contents → Resources/Tools/7zz
    let appContents = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    let sevenZip = appContents.appendingPathComponent("Resources/Tools/7zz")
    if FileManager.default.isExecutableFile(atPath: sevenZip.path) {
        setenv("SIMPLEZIP_7ZZ_PATH", sevenZip.path, 1)
    }
}

// MARK: - 分析归档空间(Core-only)

struct AnalyzeArchiveSpaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Analyze Archive Space"
    static let description = IntentDescription(
        "Returns a disk-usage summary for an archive: original vs packed size, compression ratio, macOS junk and the largest file.")

    @Parameter(title: "Archive")
    var archive: IntentFile

    static var parameterSummary: some ParameterSummary { Summary("Analyze the space used by \(\.$archive)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        ensureBundled7zzPathForExtension()
        let url = try extensionIntentFileURL(archive)
        do {
            // 扩展里直接走 Core 的 ArchiveService.list(不经 app target 的 SignedContainerService;
            // `.siz` 这类容器适配 v1 暂不在扩展支持,普通归档全覆盖)。
            let items = try await ArchiveService.list(url)
            let a = ArchiveSpaceAnalysis.analyze(items)
            func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
            var parts = ["\(a.fileCount) files", "original \(bytes(a.totalBytes))", "packed \(bytes(a.packedBytes))"]
            if let ratio = a.compressionRatio { parts.append(String(format: "ratio %.0f%%", ratio * 100)) }
            if a.junkCount > 0 { parts.append("junk \(bytes(a.junkBytes))") }
            if let largest = a.largestFiles.first { parts.append("largest \(largest.name) (\(bytes(largest.bytes)))") }
            return .result(value: parts.joined(separator: ", "))
        } catch {
            throw SimpleZipExtensionIntentError(message: error.localizedDescription)
        }
    }
}

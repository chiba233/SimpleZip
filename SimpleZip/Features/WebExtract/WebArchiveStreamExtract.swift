//
//  WebArchiveStreamExtract.swift
//  SimpleZip
//
//  从网页地址「边下边解」:HTTP 响应体字节流直接喂给 bsdtar 的 stdin,整包**绝不落盘**(勾「保留压缩包」才额外
//  tee 一份文件)。只适配流式格式(zip + tar 家族,见 ArchiveService.streamingExtractionSuffixes)—— 这正是本
//  feature 依赖「流式解压」的原因:bsdtar 能从 stdin 顺序解压,所以下载流可以直接管进去,不必先存整包。
//

import Foundation

/// 探测结果:解析出的文件名 + 字节数(可空)+ 是否可流式解压 + 不可时的原因。
struct WebArchiveProbeResult: Sendable, Equatable {
    let filename: String
    let byteCount: Int64?
    /// 两道门都过(格式是流式后缀 + 服务器返回的是归档而非网页/错误)才为 true。
    let isStreamable: Bool
    /// `isStreamable == false` 时的人类可读原因(已本地化);可流式时为 nil。
    let unsupportedReason: String?
}

enum WebArchiveStreamExtract {

    /// 浏览器风格 User-Agent —— 不少服务器对空 / `CFNetwork/…` 默认 UA 会当爬虫直接不响应(用户报);
    /// 用 Safari 风格 UA 最大化兼容(探测与下载两条请求都带)。
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private static func makeSession(delegate: URLSessionDelegate) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - 探测(服务器是否真给一个可流式的归档)

    /// 对 URL 发一个**只取响应头**的请求(收到 header 即取消,不下 body;跟随重定向 —— GitHub 的
    /// `…/archive/…zip` 会 302 到 codeload),判断:
    /// - 格式门:文件名(优先 `Content-Disposition`,否则 URL 路径)以流式后缀结尾;
    /// - 服务器门:`2xx` + `Content-Type` 不是网页/文本(text/* 或 html)+ **不是显式 `Accept-Ranges: none`**
    ///   (多数静态文件服务器/CDN 要么声明 `bytes`、要么干脆省略此头;省略不代表不能顺序流式,故按乐观放行,
    ///   只有显式声明 `none`(明确拒绝范围请求)才如实门控,避免误判真能下的 URL)。
    /// 任一不过 → `isStreamable = false` + 原因,UI 据此门控、如实提示「不支持」而非假装。
    static func probe(_ url: URL) async -> WebArchiveProbeResult {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return WebArchiveProbeResult(filename: url.lastPathComponent, byteCount: nil, isStreamable: false,
                                         unsupportedReason: L10n.text("webExtract.unsupported.scheme"))
        }
        let urlName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        guard let header = await fetchResponseHeader(url) else {
            return WebArchiveProbeResult(filename: urlName, byteCount: nil, isStreamable: false,
                                         unsupportedReason: L10n.text("webExtract.unsupported.unreachable"))
        }
        // 安全:文件名来自 URL 末段或服务器 Content-Disposition(均不可信),`%2E%2E%2F` 会解出 `../`、也可能含 `/`。
        // 收敛成单段安全名,既用于 UI 显示也用于落盘(uniqueDestinationURL 还会再收敛一次,双保险)。
        let filename = ArchiveExtractionCoordinator.sanitizedSingleComponentName(header.suggestedFilename ?? urlName)
        let byteCount = header.expectedContentLength > 0 ? header.expectedContentLength : nil

        // 格式门:文件名是流式支持的归档后缀。
        guard ArchiveService.isStreamingExtractionSupported(URL(fileURLWithPath: filename)) else {
            return WebArchiveProbeResult(filename: filename, byteCount: byteCount, isStreamable: false,
                                         unsupportedReason: L10n.text("webExtract.unsupported.format"))
        }
        // 服务器门:状态 2xx + 不是网页/文本(text/html 说明拿到的是页面而非归档)。
        guard (200..<300).contains(header.statusCode) else {
            return WebArchiveProbeResult(filename: filename, byteCount: byteCount, isStreamable: false,
                                         unsupportedReason: L10n.format("webExtract.unsupported.httpStatus", "\(header.statusCode)"))
        }
        let contentType = header.contentType.lowercased()
        if contentType.hasPrefix("text/") || contentType.contains("html") {
            return WebArchiveProbeResult(filename: filename, byteCount: byteCount, isStreamable: false,
                                         unsupportedReason: L10n.text("webExtract.unsupported.notArchive"))
        }
        // 服务器流式门:只在服务器**显式**声明 `Accept-Ranges: none`(明确拒绝范围请求)时才拦;
        // 省略此头(不少动态服务器/CDN 会省略)按乐观可流式放行 —— 顺序流式下载本不依赖范围请求,
        // 这样避免误判真能下的 URL,只有明确说「不支持」才如实门控。
        let acceptRanges = header.acceptRanges.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if acceptRanges == "none" {
            return WebArchiveProbeResult(filename: filename, byteCount: byteCount, isStreamable: false,
                                         unsupportedReason: L10n.text("webExtract.unsupported.serverNoStreaming"))
        }
        return WebArchiveProbeResult(filename: filename, byteCount: byteCount, isStreamable: true, unsupportedReason: nil)
    }

    private struct ResponseHeader {
        let statusCode: Int
        let contentType: String
        let suggestedFilename: String?
        let expectedContentLength: Int64
        /// `Accept-Ranges` 头(支持范围请求 = 服务器支持流式 / 可 seek 传输)。
        let acceptRanges: String
    }

    /// 用 GET 但**收到响应头即取消**(`completionHandler(.cancel)`),拿 header 不下 body —— 比 HEAD 稳
    /// (有些服务器对 HEAD 返回 405),且自动跟随重定向。
    private static func fetchResponseHeader(_ url: URL) async -> ResponseHeader? {
        await withCheckedContinuation { continuation in
            let probe = HeaderProbe(continuation: continuation)
            let session = makeSession(delegate: probe)
            probe.session = session
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            session.dataTask(with: request).resume()
        }
    }

    private final class HeaderProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let continuation: CheckedContinuation<ResponseHeader?, Never>
        private let lock = NSLock()
        private var finished = false
        weak var session: URLSession?

        init(continuation: CheckedContinuation<ResponseHeader?, Never>) {
            self.continuation = continuation
        }

        private func finish(_ header: ResponseHeader?) {
            lock.lock(); let already = finished; finished = true; lock.unlock()
            guard !already else { return }
            session?.invalidateAndCancel()
            continuation.resume(returning: header)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let http = response as? HTTPURLResponse
            finish(ResponseHeader(
                statusCode: http?.statusCode ?? 0,
                contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? "",
                suggestedFilename: response.suggestedFilename,
                expectedContentLength: response.expectedContentLength,
                acceptRanges: http?.value(forHTTPHeaderField: "Accept-Ranges") ?? ""
            ))
            completionHandler(.cancel)   // 只要 header,不下 body
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            finish(nil)   // 没拿到 header(网络错误 / 立即失败)
        }
    }

    // MARK: - 边下边解(网络字节流 → bsdtar stdin)

    /// 网络归档流式下载并解压到 `destination` 下一个以归档名命名的子文件夹(整包不落盘)。
    /// - `keepArchive`:额外把下载流 tee 一份归档文件存进 `destination`。
    /// - `onProgress`:(已收字节, 总字节 -1=未知)。
    /// 流程:staging 起 `tar -x -f - -C staging` → URLSession 字节块边到边写进它 stdin(+可选 tee)→ 关 stdin
    /// 等 bsdtar → 现有安全闸 + 合并到子文件夹。失败 / 取消:杀 bsdtar、清 staging/tee,不留半成品。
    @MainActor
    static func run(
        url: URL,
        filename: String,
        destination: URL,
        keepArchive: Bool,
        coordinator: ArchiveExtractionCoordinator,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        let staging = try coordinator.makeExtractionStagingDirectory()

        // bsdtar 从 stdin 顺序解压(libarchive 按 magic 自动识别 zip / gz / xz / zst…)。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-x", "-f", "-", "-C", staging.path]
        let stdinPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        // 勾「保留压缩包」→ 同时把字节 tee 进 staging 旁的临时文件,成功后按真实文件名移进 destination。
        var teeHandle: FileHandle?
        var teeURL: URL?
        if keepArchive {
            let tee = staging.deletingLastPathComponent().appendingPathComponent("SimpleZip-webdl-\(UUID().uuidString)")
            if FileManager.default.createFile(atPath: tee.path, contents: nil),
               let handle = try? FileHandle(forWritingTo: tee) {
                teeHandle = handle
                teeURL = tee
            }
        }

        func cleanup() {
            try? stdinPipe.fileHandleForWriting.close()
            try? teeHandle?.close()
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: staging)
            if let teeURL { try? FileManager.default.removeItem(at: teeURL) }
        }

        do {
            try process.run()
            // 下载流 → stdin(+tee)。URLSession 自有队列,同步写 pipe 即天然背压;取消经 holder 连到 task。
            try await streamDownload(url: url, into: stdinPipe.fileHandleForWriting, tee: teeHandle, onProgress: onProgress)
            try? stdinPipe.fileHandleForWriting.close()   // EOF → bsdtar 收尾
            try? teeHandle?.close()

            await Task.detached(priority: .userInitiated) { process.waitUntilExit() }.value
            guard process.terminationStatus == 0 else {
                let err = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw WebExtractError.streamingFailed(err.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            // 解到 staging 的产物过现有 untrusted 安全闸(符号链接逃逸 / 路径穿越)+ 冲突合并到「destination/<归档名>」。
            let baseName = archiveBaseName(filename)
            let target = coordinator.uniqueDestinationURL(for: baseName, in: destination)
            try await coordinator.mergeExtractedItems(
                from: staging, to: target,
                defaultOverwriteBehavior: .overwrite,
                updateStatus: { _ in }, updateProgress: { _ in })

            if let teeURL {   // 保留压缩包:按真实文件名移进 destination(唯一化,绝不覆盖)。
                let archiveTarget = coordinator.uniqueDestinationURL(for: filename, in: destination)
                try? FileManager.default.moveItem(at: teeURL, to: archiveTarget)
            }
            try? FileManager.default.removeItem(at: staging)
            return target
        } catch {
            cleanup()
            throw error
        }
    }

    /// 从归档文件名剥掉流式后缀得到落地子文件夹名("foo.tar.gz" → "foo"、"x.zip" → "x");无法识别则去最后一段扩展名。
    private static func archiveBaseName(_ filename: String) -> String {
        let lower = filename.lowercased()
        for suffix in ArchiveService.streamingExtractionSuffixes.sorted(by: { $0.count > $1.count }) where lower.hasSuffix(suffix) {
            let base = String(filename.dropLast(suffix.count))
            return base.isEmpty ? "download" : base
        }
        let stem = (filename as NSString).deletingPathExtension
        return stem.isEmpty ? "download" : stem
    }

    /// URLSession 字节流 → FileHandle(bsdtar stdin)。Task 取消时经 holder cancel 掉 URLSession task。
    private static func streamDownload(
        url: URL,
        into stdin: FileHandle,
        tee: FileHandle?,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let holder = SessionHolder()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let streamer = DownloadStreamer(stdin: stdin, tee: tee, onProgress: onProgress, continuation: continuation)
                let session = makeSession(delegate: streamer)
                streamer.session = session
                var request = URLRequest(url: url)
                request.timeoutInterval = 60
                let task = session.dataTask(with: request)
                streamer.task = task
                holder.store(session: session, task: task)
                task.resume()
            }
        } onCancel: {
            holder.cancel()
        }
    }

    private nonisolated final class SessionHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        func store(session: URLSession, task: URLSessionTask) {
            lock.lock(); self.task = task; lock.unlock()
        }
        func cancel() {
            lock.lock(); let t = task; lock.unlock()
            t?.cancel()
        }
    }

    private final class DownloadStreamer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let stdin: FileHandle
        private let tee: FileHandle?
        private let onProgress: @Sendable (Int64, Int64) -> Void
        private let continuation: CheckedContinuation<Void, Error>
        private let lock = NSLock()
        private var finished = false
        private var total: Int64 = -1
        private var received: Int64 = 0
        weak var session: URLSession?
        weak var task: URLSessionTask?

        init(stdin: FileHandle, tee: FileHandle?, onProgress: @escaping @Sendable (Int64, Int64) -> Void,
             continuation: CheckedContinuation<Void, Error>) {
            self.stdin = stdin
            self.tee = tee
            self.onProgress = onProgress
            self.continuation = continuation
        }

        private func finish(_ error: Error?) {
            lock.lock(); let already = finished; finished = true; lock.unlock()
            guard !already else { return }
            session?.invalidateAndCancel()
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                completionHandler(.cancel)
                finish(WebExtractError.httpStatus(http.statusCode))
                return
            }
            total = response.expectedContentLength
            onProgress(0, total)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try stdin.write(contentsOf: data)   // 同步写 pipe = 天然背压(bsdtar 慢则阻塞、URLSession 自动减速)
                try tee?.write(contentsOf: data)
                received += Int64(data.count)
                onProgress(received, total)
            } catch {
                dataTask.cancel()
                finish(WebExtractError.streamingFailed(error.localizedDescription))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            finish(error)
        }
    }

    enum WebExtractError: LocalizedError {
        case httpStatus(Int)
        case streamingFailed(String)

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code):
                return L10n.format("webExtract.error.httpStatus", "\(code)")
            case .streamingFailed(let detail):
                return detail.isEmpty
                    ? L10n.text("webExtract.error.streamingFailed")
                    : L10n.format("webExtract.error.streamingFailedDetail", detail)
            }
        }
    }
}

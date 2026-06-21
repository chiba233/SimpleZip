//
//  ArchiveSalvage.swift
//  SimpleZip
//
//  0.4.4 #8:损坏归档的只读数据救援(v1 务实版,用户拍板)。
//  **不写 Swift ZIP 解析器** —— 7zz 自带兜底:CRC 错误时继续解余下文件(exit 2 + 逐文件
//  `ERROR: CRC Failed : path`),中央目录损坏的 ZIP 会扫 local header。本文件只做:
//  ① 失败行解析(纯函数,可测);② 救援编排 —— 安全检查**不放松**(损坏包恰是敌意输入的
//  高发形态):能列出条目先过 validateForExtraction,落盘后必过 validateExtractedTree,
//  不安全 = 硬失败。救援目录 `<原名> (rescued)` + 唯一化,绝不覆盖;原包永不被改动。
//

import Foundation

nonisolated enum ArchiveSalvage {

    /// 一次救援的结果。
    struct Outcome: Equatable {
        /// 实际落盘的文件数(救出来的)。
        let rescuedFileCount: Int
        /// 后端逐文件报错的条目路径(CRC / 数据错误)。
        let failedEntryPaths: [String]
        /// 后端汇总行报告的错误数(`Sub items Errors: N`;没报为 nil)。
        let reportedErrorCount: Int?
        /// 救援目录。
        let destination: URL
    }

    /// 从 7zz 输出解析逐文件失败行与汇总:
    ///   `ERROR: CRC Failed : path` / `ERROR: Data Error : path` / `Sub items Errors: N`。
    /// 纯文本解析,SwiftPM 可测。
    static func parseFailures(fromBackendOutput output: String) -> (failedPaths: [String], reportedErrorCount: Int?) {
        var paths: [String] = []
        var reported: Int?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("ERROR:") {
                // `ERROR: <原因> : <path>`(7zz 的固定形态;path 自身可含 ":",取**第一个** " : " 之后整段)。
                let body = line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
                if let separator = body.range(of: " : ") {
                    let path = String(body[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !path.isEmpty, !paths.contains(path) {
                        paths.append(path)
                    }
                }
            } else if line.hasPrefix("Sub items Errors:") {
                reported = Int(line.dropFirst("Sub items Errors:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return (paths, reported)
    }

    /// 跑救援:解到 `<directory>/<原名> (rescued)`(唯一化),catch 后端非零退出**不抛**
    /// (此时部分文件已在盘上 —— 失败本身是预期),数出真正落盘的文件;
    /// 落盘树必过 symlink 安全检查,不安全直接抛(绝不把危险产物留给用户)。
    static func run(
        archive: URL,
        listedItems: [ArchiveItem]?,
        password: String,
        destinationParent: URL? = nil,
        operationID: UUID?,
        outputObserver: (@Sendable (String) -> Void)?
    ) async throws -> Outcome {
        // 列得动的损坏包:解压前照常过路径安全检查 —— 损坏 ≠ 豁免,反而更可疑。
        if let listedItems {
            try ArchiveSafety.validateForExtraction(listedItems)
        }

        // 救援目录落在 `destinationParent`(CLI `--to`)或归档所在目录(默认,GUI 行为)。
        let preferred = (destinationParent ?? archive.deletingLastPathComponent())
            .appendingPathComponent(archive.deletingPathExtension().lastPathComponent + " (rescued)")
        let destination = UniqueFileName.suffixed(for: preferred, suffix: "") {
            FileManager.default.fileExists(atPath: $0.path)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // 失败输出旁路收集:runAndCapture 在非零退出时把输出装进错误抛出,
        // 这里用 observer 同步攒一份,成功失败都有得解析。
        let collector = OutputCollector()
        let collectingObserver: @Sendable (String) -> Void = { chunk in
            collector.append(chunk)
            outputObserver?(chunk)
        }
        do {
            try await SevenZipBackend.extract(
                archive,
                entries: [],
                to: destination,
                overwriteBehavior: .overwrite,   // 全新唯一目录,无可覆盖之物
                pathMode: .preserve,
                password: password,
                progressParser: nil,
                outputObserver: collectingObserver,
                operationID: operationID
            )
        } catch is CancellationError {
            // 用户取消:清掉半成品目录(取消 ≠ 救援失败,不留垃圾)。
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        } catch {
            // 非零退出 = 预期(损坏包)。文件已在盘上,继续走统计;输出已经攒在 collector 里。
        }

        // 落盘树安全检查不放松:发现逃逸 symlink → 整个救援目录删掉 + 硬失败。
        do {
            try ArchiveSafety.validateExtractedTree(at: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        let failures = parseFailures(fromBackendOutput: collector.text)
        let rescuedCount = countFiles(under: destination)
        return Outcome(
            rescuedFileCount: rescuedCount,
            failedEntryPaths: failures.failedPaths,
            reportedErrorCount: failures.reportedErrorCount,
            destination: destination
        )
    }

    private static func countFiles(under root: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }

    /// 线程安全的输出收集器(observer 从后端读线程回调)。
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""

        func append(_ chunk: String) {
            lock.lock()
            buffer += chunk
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }
}

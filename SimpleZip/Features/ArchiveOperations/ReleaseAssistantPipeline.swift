//
//  ReleaseAssistantPipeline.swift
//  SimpleZip
//
//  0.4.4 F3:发布助手的执行管线 —— 从 runReleaseAssistant 的任务闭包抽出(纯搬代码,行为不变),
//  让将来的发布 intent(B)调同一个函数,不造平行引擎。三个引擎步骤(打包 / 检查 / 校验文件)
//  由 ReleaseStepRecorder 计时留痕;`.szs` 签名是交互式步骤,留在 refreshOnSuccess,不进这里。
//

import Foundation

enum ReleaseAssistantPipeline {

    /// 跑发布流水线:① 打包(可跳过 —— 续跑时产物还在) → ② 发布检查 → ③ SHA-256 / SHA256SUMS。
    /// 检查失败不抛(失败本身是报告内容);打包失败抛出 = 任务失败。返回填好的检查报告。
    static func run(
        request: ReleaseAssistantRequest,
        source: URL,
        destination: URL,
        outputURL: URL,
        options: ArchiveCreationOptions,
        skipCreate: Bool,
        recorder: ReleaseStepRecorder,
        operationID: UUID?,
        progress: @escaping @Sendable (ArchiveProgressState) -> Void,
        outputObserver: (@Sendable (String) -> Void)?
    ) async throws -> ArchiveBrowserModel.ReleaseInspectionReport {
        var report = ArchiveBrowserModel.ReleaseInspectionReport(archiveURL: outputURL)

        // ① 打包。创建占 0~0.6 —— createArchive 自己的 fraction 压缩到这个区间。
        // 续跑(skipCreate):产物还在,跳过重打包 —— UniqueFileName 语义下重打包=新文件名,不是续跑。
        if skipCreate {
            recorder.recordSkipped(.createArchive)
        } else {
            try await recorder.perform(.createArchive) {
                try await ArchiveService.createArchive(
                    from: [source],
                    destination: outputURL,
                    options: options,
                    operationID: operationID,
                    progress: { state in
                        var scaled = state
                        scaled.fraction = state.fraction.map { $0 * 0.6 }
                        progress(scaled)
                    },
                    outputObserver: outputObserver
                )
            }
        }

        // ② 发布检查(与 runReleaseInspection 同一套步骤,对刚生成的归档;新包无密码)。
        if request.runInspection {
            try await recorder.perform(.inspect) {
                progress(ArchiveProgressState(fraction: 0.65, statusText: nil))
                if let items = try? await ArchiveService.list(outputURL, operationID: operationID) {
                    report.listable = true
                    report.stats = ReleaseInspection.stats(for: items)
                    report.securityFindings = ArchiveSecurityReport.analyze(items)
                    report.hasComment = !ArchiveService.headerComment(for: outputURL).isEmpty
                    report.structuralFingerprint = ArchiveStructuralFingerprint.compute(for: items)
                }
                do {
                    try await ArchiveService.test(outputURL, operationID: operationID, outputObserver: outputObserver)
                    report.testPassed = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // 测试失败 ≠ 步骤失败:失败本身是报告内容,记进 report 后步骤照常算成功。
                    report.testPassed = false
                    report.testFailureMessage = error.localizedDescription
                }
            }
        }

        // ③ SHA-256:检查报告和 SHA256SUMS 共用同一次哈希。
        if request.runInspection || request.writeChecksums {
            try await recorder.perform(.checksums) {
                progress(ArchiveProgressState(fraction: 0.9, statusText: nil))
                let digest = try? await Task.detached(priority: .userInitiated) {
                    try HashService.sha256(for: outputURL)
                }.value
                report.sha256 = digest
                if request.writeChecksums, let digest {
                    let preferredSums = destination.appendingPathComponent("SHA256SUMS")
                    let sumsURL = UniqueFileName.suffixed(for: preferredSums, suffix: "") {
                        FileManager.default.fileExists(atPath: $0.path)
                    }
                    try ChecksumFile.generateSHA256SUMS([(name: outputURL.lastPathComponent, digestHex: digest)])
                        .write(to: sumsURL, atomically: true, encoding: .utf8)
                }
            }
        }
        progress(ArchiveProgressState(fraction: 1.0, statusText: nil))
        return report
    }
}

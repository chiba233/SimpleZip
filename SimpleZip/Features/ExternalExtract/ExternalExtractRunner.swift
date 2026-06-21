//
//  ExternalExtractRunner.swift
//  SimpleZip
//
//  0.3.0 架构拆分：从 ExternalExtractWindow.swift 切出，纯移动、零行为变更。
//

import AppKit
import Combine
import SwiftUI

/// 解压单个压缩包到其所在目录的同名文件夹，返回产物目录。**纯流程，无 reveal / 关窗 / 声音副作用**——
/// 单任务和批量任务共用，避免重复 staging → extract → merge 这段逻辑。
enum ExternalExtractRunner {
    @MainActor
    static func extract(
        archiveURL: URL,
        destinationDirectoryOverride: URL?,
        outputBaseNameOverride: String?,
        operationID: UUID,
        coordinator: ArchiveExtractionCoordinator,
        onStatus: @escaping @MainActor (String) -> Void,
        onProgress: @escaping @MainActor (Double?, String?) -> Void,
        outputObserver: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        let supportedURL = ArchiveService.supportedArchiveURL(archiveURL) ?? archiveURL
        // 目标父目录：默认 archive 所在目录；`.siz` 自动解压时内层 archive 在 /tmp，用 override 落到原 .siz 文件夹。
        let destinationDir = destinationDirectoryOverride ?? supportedURL.deletingLastPathComponent()
        let stagingURL = try coordinator.makeExtractionStagingDirectory()
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        let preset = AppPreferences.hasUsablePresetPassword ? AppPreferences.presetPassword : ""
        let overwriteBehavior: OverwriteBehavior = AppPreferences.overwriteBehavior == .skipExisting
            ? .skipExisting
            : .overwrite

        // 进度节流:碎文件 ZIP 的 unzip / merge 会逐文件回调几万次进度,若每条都跳主 actor 改 @Published
        // (浮窗 fraction/currentFileName + 活动中心 task.progress),会把主线程刷爆卡死(Finder 自动解压 /
        // 右键解压浮窗这条路径之前没节流)。复用主窗口同款 ProgressCoalescer 合帧——只保留最新值,最多每 ~80ms 应用一次。
        let progressCoalescer = ProgressCoalescer { state in
            onProgress(state.fraction, state.currentFile)
            if let text = state.statusText { onStatus(text) }
        }

        // 0.4.3 #6 统一密码中心:候选顺序 = 预设密码(原行为) → 会话缓存(本包记过的 → 本会话最近成功的)。
        // 「错误表明要口令」才换下一个候选静默重试,其余错误原样抛给浮窗;候选用尽抛最后的口令错误。
        // 成功口令记入会话缓存 —— Finder 批量解压同口令的一组包,后面的包静默通过。
        var passwordCandidates: [String] = [preset]
        for cached in SessionPasswordCache.shared.candidates(for: supportedURL) where !passwordCandidates.contains(cached) {
            passwordCandidates.append(cached)
        }
        for (index, candidate) in passwordCandidates.enumerated() {
            do {
                try await ArchiveService.extract(
                    supportedURL,
                    to: stagingURL,
                    overwriteBehavior: overwriteBehavior,
                    password: candidate,
                    operationID: operationID,
                    progress: { progressCoalescer.submit($0) },
                    outputObserver: outputObserver
                )
                if !candidate.isEmpty {
                    SessionPasswordCache.shared.record(candidate, for: supportedURL)
                }
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard ArchiveService.errorSuggestsPasswordRequirement(error), index < passwordCandidates.count - 1 else {
                    throw error
                }
                // 换口令重试前清掉半解压残渣,staging 目录原位重建。
                try? FileManager.default.removeItem(at: stagingURL)
                try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            }
        }

        let baseName = outputBaseNameOverride ?? supportedURL.deletingPathExtension().lastPathComponent
        let target = coordinator.uniqueDestinationURL(for: baseName, in: destinationDir)
        try await coordinator.mergeExtractedItems(
            from: stagingURL,
            to: target,
            defaultOverwriteBehavior: overwriteBehavior,
            updateStatus: { text in Task { @MainActor in onStatus(text) } },
            updateProgress: { progressCoalescer.submit($0) }
        )
        return target
    }
}

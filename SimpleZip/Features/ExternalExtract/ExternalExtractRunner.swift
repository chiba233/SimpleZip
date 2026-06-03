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

        try await ArchiveService.extract(
            supportedURL,
            to: stagingURL,
            overwriteBehavior: overwriteBehavior,
            password: preset,
            operationID: operationID,
            progress: { state in
                Task { @MainActor in
                    onProgress(state.fraction, state.currentFile)
                    if let text = state.statusText { onStatus(text) }
                }
            },
            outputObserver: outputObserver
        )

        let baseName = outputBaseNameOverride ?? supportedURL.deletingPathExtension().lastPathComponent
        let target = coordinator.uniqueDestinationURL(for: baseName, in: destinationDir)
        try await coordinator.mergeExtractedItems(
            from: stagingURL,
            to: target,
            defaultOverwriteBehavior: overwriteBehavior,
            updateStatus: { text in Task { @MainActor in onStatus(text) } },
            updateProgress: { state in Task { @MainActor in onProgress(state.fraction, state.currentFile) } }
        )
        return target
    }
}

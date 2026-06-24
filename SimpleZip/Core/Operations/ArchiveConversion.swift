//
//  ArchiveConversion.swift
//  SimpleZip
//
//  #112 批量格式转换 —— 7zz 无单步转格式命令，转换 = 解压到临时目录 → 重新压缩。
//  本引擎纯编排现有 `ArchiveService.extract` / `createArchive`：不引入新后端参数、不瞎猜 7zz 旗标。
//  安全：临时工作目录用系统 temp + UUID，转换完成 / 失败都清理（A7）。
//

import Foundation

/// 单个归档的转换请求。
struct ArchiveConversionRequest: Identifiable, Sendable {
    let id = UUID()
    /// 源归档。
    let sourceURL: URL
    /// 解压源所需密码（加密源；明文留空）。
    let sourcePassword: String
    /// 目标格式 + 压缩选项（密码 / 级别等都在里面）。
    let targetOptions: ArchiveCreationOptions
    /// 目标归档落点（含正确后缀）。
    let destinationURL: URL
}

/// 一次转换的结果（成功落点或失败原因）。供活动中心逐项展示。
struct ArchiveConversionOutcome: Sendable {
    let sourceURL: URL
    let destinationURL: URL?
    let error: String?
    var succeeded: Bool { error == nil }
}

enum ArchiveConversion {

    /// 把一个归档转换成另一种格式：解压源到临时目录 → 用目标选项重新压缩临时目录内容。
    /// - 源解压走 `.validate` 安全策略（路径穿越 / 危险链接拦截），与正常解压同口径。
    /// - 临时目录在 `defer` 里无条件清理（成功 / 失败 / 取消都清）。
    /// - 目标已存在不在此判定（调用方用 `UniqueFileName` 先避让）；这里直接写 `destinationURL`。
    static func convert(
        _ request: ArchiveConversionRequest,
        operationID: UUID? = nil,
        progress: @escaping @Sendable (ArchiveProgressState) -> Void = { _ in },
        outputObserver: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let fileManager = FileManager.default
        let workDir = fileManager.temporaryDirectory
            .appendingPathComponent("SimpleZip-Convert-\(UUID().uuidString)")
        try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDir) }

        // 0.4.3 #4:空间预检 —— 临时卷要装下解压展开(常见 1~2x 源包)+ 重压中间产物,按 3x 源包估;
        // 目标卷按 1x 源包估(输出同数量级)。「约」估算:拦下绝大多数写一半的神秘失败。
        let sourceSize = (((try? fileManager.attributesOfItem(atPath: request.sourceURL.path))?[.size] as? NSNumber)?.int64Value) ?? 0
        try DiskSpacePreflight.ensure(estimatedBytes: sourceSize * 3, at: workDir)
        try DiskSpacePreflight.ensure(estimatedBytes: sourceSize, at: request.destinationURL.deletingLastPathComponent())

        // 1) 解压源 → 临时目录（带安全校验）。
        progress(ArchiveProgressState(fraction: nil, currentFile: nil, statusText: L10n.text("convert.status.extracting")))
        try await ArchiveService.extract(
            request.sourceURL,
            to: workDir,
            overwriteBehavior: .overwrite,
            password: request.sourcePassword,
            safetyPolicy: .validate,
            operationID: operationID,
            progress: { state in
                // 解压阶段占进度前半：fraction 折半。
                progress(Self.halfProgress(state, secondHalf: false))
            },
            outputObserver: outputObserver
        )
        try Task.checkCancellation()

        // 2) 重新压缩临时目录内容 → 目标。源压缩包顶层条目就是 workDir 下的内容。
        let topLevel = try fileManager.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
        guard !topLevel.isEmpty else {
            throw ArchiveError.commandFailed(L10n.text("convert.error.empty"))
        }
        progress(ArchiveProgressState(fraction: 0.5, currentFile: nil, statusText: L10n.text("convert.status.repacking")))
        try await ArchiveService.createArchive(
            from: topLevel,
            destination: request.destinationURL,
            options: request.targetOptions,
            operationID: operationID,
            progress: { state in
                progress(Self.halfProgress(state, secondHalf: true))
            },
            outputObserver: outputObserver
        )
    }

    /// 把子阶段的 0…1 进度映射到整体的前半 [0,0.5] 或后半 [0.5,1]。
    private static func halfProgress(_ state: ArchiveProgressState, secondHalf: Bool) -> ArchiveProgressState {
        let base = secondHalf ? 0.5 : 0.0
        let mapped = state.fraction.map { base + $0 * 0.5 }
        return ArchiveProgressState(fraction: mapped, currentFile: state.currentFile, statusText: state.statusText)
    }
}

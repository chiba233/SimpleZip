//
//  DiskImageBackend.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

/// `.dmg` 文件的后端实现。
///
/// 设计动机：DMG 跟其它「压缩包」格式很不一样 —— 不是 7zz / RAR / zip 解析压缩字节，
/// 而是用 `hdiutil` 把 DMG 当一块只读卷挂起来，然后用文件系统 API 拷贝 / 列内容。
/// 流程独立、依赖独立（只用系统自带的 `/usr/bin/hdiutil`），单独抽成 backend 后
/// ArchiveService 的 case .diskImage 分支只剩两三行转发，不再混着「这是 hdiutil 卷」这种特化细节。
///
/// 状态约束：mount → 操作 → detach。调用方必须保证 detach 总会跑（用 defer / Task 都行），
/// 否则用户机器上会留下幽灵挂载点；ArchiveService.list/extract 的实现里已经这么做了。
enum DiskImageBackend {

    // MARK: - 公开操作

    /// 挂载 DMG 为只读卷，返回 mount-point URL。
    /// 用 `-readonly -nobrowse -noverify -noautoopen` 这些 flag 是为了不污染 Finder /
    /// 不弹「正在验证」/ 不自动打开内容，纯后台用。
    static func mount(_ url: URL) async throws -> URL {
        let output = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/hdiutil",
            arguments: ["attach", "-plist", "-readonly", "-nobrowse", "-noverify", "-noautoopen", url.path]
        )
        guard
            let data = output.data(using: .utf8),
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]]
        else {
            throw ArchiveError.commandFailed(output)
        }

        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String {
                return URL(fileURLWithPath: mountPoint)
            }
        }
        throw ArchiveError.commandFailed(output)
    }

    /// 卸载挂载点。`-force` 容忍占用 / 子进程未关闭，DMG 临时用就该粗暴一点。
    static func detach(at mountPoint: URL) async throws {
        _ = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/hdiutil",
            arguments: ["detach", mountPoint.path, "-force"]
        )
    }

    /// 列 DMG 内容 = 挂载 + 列顶层文件 + 卸载。
    static func list(_ archive: URL) async throws -> [ArchiveItem] {
        let mountPoint = try await mount(archive)
        do {
            let items = try archiveItems(at: mountPoint)
            try await detach(at: mountPoint)
            return items
        } catch {
            try? await detach(at: mountPoint)
            throw error
        }
    }

    /// 解压 DMG = 挂载 + 拷贝顶层文件到目标目录 + 卸载。
    /// 不支持「解压选中条目」—— DMG 是文件系统，多选条目语义模糊（你要复制几个 .app？还是连同 Applications 软链一起复制？）；
    /// 调用方需要时自己手动挂载浏览。
    static func extract(
        _ archive: URL,
        to destination: URL,
        progress: @escaping @Sendable (ArchiveProgressState) -> Void
    ) async throws {
        let mountPoint = try await mount(archive)
        do {
            try copyContents(from: mountPoint, to: destination, progress: progress)
            try await detach(at: mountPoint)
        } catch {
            try? await detach(at: mountPoint)
            throw error
        }
    }

    /// 「测试」DMG = 挂上再卸 —— 系统 hdiutil 不报错就算结构 OK。
    static func test(_ archive: URL) async throws {
        let mountPoint = try await mount(archive)
        try await detach(at: mountPoint)
    }

    /// 创建压缩 DMG。`hdiutil create -srcfolder` 只接受一个源目录，所以这里先把用户选中的
    /// 文件 / 文件夹组装到临时 staging 目录，让 DMG 顶层内容保持和其它归档格式一致：
    /// 用户选了 `App.app`，DMG 里就是 `App.app`，而不是 App.app 的内部内容。
    static func create(
        from sourceURLs: [URL],
        destination: URL,
        volumeName: String,
        progress: @escaping @Sendable (ArchiveProgressState) -> Void,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?
    ) async throws {
        let fileManager = FileManager.default
        let stagingURL = fileManager.temporaryDirectory
            .appendingPathComponent("SimpleZip-DMG-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingURL) }

        let total = max(1, sourceURLs.count)
        for (index, sourceURL) in sourceURLs.enumerated() {
            try Task.checkCancellation()
            progress(
                ArchiveProgressState(
                    fraction: Double(index) / Double(total),
                    currentFile: sourceURL.lastPathComponent,
                    statusText: nil,
                    completedUnitCount: index + 1,
                    totalUnitCount: total
                )
            )
            try fileManager.copyItem(
                at: sourceURL,
                to: stagingURL.appendingPathComponent(sourceURL.lastPathComponent)
            )
        }

        progress(ArchiveProgressState(fraction: nil, currentFile: destination.lastPathComponent))
        _ = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/hdiutil",
            arguments: [
                "create",
                "-format", "UDZO",
                "-ov",
                "-volname", volumeName.isEmpty ? "SimpleZip" : volumeName,
                "-srcfolder", stagingURL.path,
                destination.path
            ],
            outputObserver: outputObserver,
            operationID: operationID
        )
        progress(ArchiveProgressState(fraction: 1, currentFile: nil, completedUnitCount: total, totalUnitCount: total))
    }

    // MARK: - 私有实现

    /// 拷顶层目录条目到 destination；用 `Task.checkCancellation()` 让用户能取消大文件。
    private static func copyContents(
        from mountPoint: URL,
        to destination: URL,
        progress: @escaping @Sendable (ArchiveProgressState) -> Void
    ) throws {
        let fileManager = FileManager.default
        let items = try fileManager.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
        let total = max(1, items.count)
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            progress(
                ArchiveProgressState(
                    fraction: Double(index) / Double(total),
                    currentFile: item.lastPathComponent,
                    statusText: nil,
                    completedUnitCount: index + 1,
                    totalUnitCount: total
                )
            )
            let target = destination.appendingPathComponent(item.lastPathComponent)
            try fileManager.copyItem(at: item, to: target)
        }
        progress(ArchiveProgressState(fraction: 1, currentFile: nil, statusText: nil, completedUnitCount: total, totalUnitCount: total))
    }

    /// 把挂载点下的顶层项目转成 ArchiveItem 数组，用户能在 UI 里浏览。
    /// 目录优先 + 名称自然排序，跟 ArchiveService 别的 backend 一致。
    private static func archiveItems(at mountPoint: URL) throws -> [ArchiveItem] {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        return try fileManager.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: Array(resourceKeys))
            .compactMap { url in
                guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return nil }
                let isDirectory = values.isDirectory == true
                let size = Int64(values.fileSize ?? 0)
                let modified = values.contentModificationDate
                return ArchiveItem(
                    name: url.lastPathComponent + (isDirectory ? "/" : ""),
                    isDirectory: isDirectory,
                    size: isDirectory ? nil : size,
                    modified: modified,
                    sizeText: isDirectory ? "" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                    modifiedText: modified.map(dateFormatter.string(from:)) ?? "",
                    method: ""
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    /// 共用 DateFormatter（DateFormatter 实例化开销不小）。
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

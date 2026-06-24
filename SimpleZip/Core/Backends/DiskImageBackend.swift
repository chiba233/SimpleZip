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
    private struct MountSession {
        let mountPoint: URL
        let detachTargets: [String]
    }

    // MARK: - 公开操作

    /// 挂载 DMG 为只读卷，返回 mount-point URL。
    /// 用 `-readonly -nobrowse -noautoopen` 这些 flag 是为了不污染 Finder /
    /// 不弹窗 / 不自动打开内容，纯后台用。
    /// 安全（审计 P2）：`-owners off` —— DMG 是**不可信输入**,关闭属主语义后镜像内的 setuid/setgid
    /// 位、伪造属主都失效（跟 SecureScratchVolume 挂自有加密卷同口径）；否则 copyContents 会把这些属性
    /// 一并拷进用户目录。去掉了 `-noverify`：对攻击者可控的镜像保留校验和验证。
    static func mount(_ url: URL) async throws -> URL {
        try await mountSession(url).mountPoint
    }

    private nonisolated static func mountSession(_ url: URL) async throws -> MountSession {
        let output: String
        do {
            output = try await BackendProcessRunner.runAndCapture(
                "/usr/bin/hdiutil",
                arguments: ["attach", "-plist", "-readonly", "-owners", "off", "-nobrowse", "-noautoopen", url.path]
            )
        } catch {
            await detachImage(matching: url)
            throw error
        }
        guard
            let data = output.data(using: .utf8),
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]]
        else {
            throw ArchiveError.commandFailed(output)
        }

        var mountPoint: URL?
        var detachTargets: [String] = []
        for entity in entities {
            if let mount = entity["mount-point"] as? String, !mount.isEmpty {
                mountPoint = URL(fileURLWithPath: mount)
                detachTargets.append(mount)
            }
            if let devEntry = entity["dev-entry"] as? String, !devEntry.isEmpty {
                detachTargets.append(devEntry)
            }
        }
        guard let mountPoint else {
            throw ArchiveError.commandFailed(output)
        }
        return MountSession(mountPoint: mountPoint, detachTargets: uniqueDetachingTargets(detachTargets))
    }

    /// 卸载挂载点。`-force` 容忍占用 / 子进程未关闭，DMG 临时用就该粗暴一点。
    static func detach(at mountPoint: URL) async throws {
        _ = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/hdiutil",
            arguments: ["detach", mountPoint.path, "-force"]
        )
    }

    private nonisolated static func detach(_ session: MountSession) async {
        for target in session.detachTargets {
            _ = try? await BackendProcessRunner.runAndCapture(
                "/usr/bin/hdiutil",
                arguments: ["detach", target, "-force"]
            )
        }
    }

    private nonisolated static func detachImage(matching imageURL: URL) async {
        guard
            let info = try? await BackendProcessRunner.runAndCapture("/usr/bin/hdiutil", arguments: ["info", "-plist"]),
            let data = info.data(using: .utf8),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let images = plist["images"] as? [[String: Any]]
        else { return }

        let targetPath = imageURL.resolvingSymlinksInPath().path
        for image in images {
            guard let imagePath = image["image-path"] as? String,
                  URL(fileURLWithPath: imagePath).resolvingSymlinksInPath().path == targetPath,
                  let entities = image["system-entities"] as? [[String: Any]] else { continue }
            let targets = entities.flatMap { entity in
                [entity["mount-point"] as? String, entity["dev-entry"] as? String].compactMap { $0 }
            }
            await detach(MountSession(mountPoint: imageURL, detachTargets: uniqueDetachingTargets(targets)))
        }
    }

    private nonisolated static func uniqueDetachingTargets(_ targets: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for target in targets where seen.insert(target).inserted {
            result.append(target)
        }
        return result
    }

    /// 列 DMG 内容 = 挂载 + 列顶层文件 + 卸载。
    nonisolated static func list(_ archive: URL) async throws -> [ArchiveItem] {
        let session = try await mountSession(archive)
        do {
            let items = try archiveItems(at: session.mountPoint)
            await detach(session)
            return items
        } catch {
            await detach(session)
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
        let session = try await mountSession(archive)
        do {
            // copyContents 是同步文件系统拷贝（contentsOfDirectory + copyItem 循环），
            // 必须在后台线程执行——app target 默认 @MainActor，await 后继续停在主线程。
            let mountPoint = session.mountPoint
            try await Task.detached { try Self.copyContents(from: mountPoint, to: destination, progress: progress) }.value
            await detach(session)
        } catch {
            await detach(session)
            throw error
        }
    }

    /// 「测试」DMG = 挂上再卸 —— 系统 hdiutil 不报错就算结构 OK。
    nonisolated static func test(_ archive: URL) async throws {
        let session = try await mountSession(archive)
        await detach(session)
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

        // 安全:volumeName 是用户输入,作为 `-volname` 的**值**传(argv 数组,不经 shell,hdiutil 不会再拆它)——
        // 以 - 开头也只是个怪名字、不是注入;但控制字符 / 换行会让 hdiutil 行为未定义,这里清掉控制字符。
        // (hdiutil 的路径参数都来自 URL.path = 绝对路径、必以 / 开头,不可能被当 flag,故无需 `--`。)
        let safeVolumeName: String = {
            let cleaned = String(volumeName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? "SimpleZip" : cleaned
        }()
        progress(ArchiveProgressState(fraction: nil, currentFile: destination.lastPathComponent))
        _ = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/hdiutil",
            arguments: [
                "create",
                "-format", "UDZO",
                "-ov",
                "-volname", safeVolumeName,
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
    // nonisolated:纯文件复制 + @Sendable 进度回调,无 MainActor 状态。extract 已把它丢进 Task.detached
    // 真正在后台跑(app target 默认 @MainActor,不标 nonisolated 时从 detached 闭包调它会报「actor 隔离方法
    // 不能在 actor 外调用」—— Swift 6 语言模式下是 error)。
    private nonisolated static func copyContents(
        from mountPoint: URL,
        to destination: URL,
        progress: @escaping @Sendable (ArchiveProgressState) -> Void
    ) throws {
        let fileManager = FileManager.default
        let items = try fileManager.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: [.isSymbolicLinkKey])
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
            // 安全:DMG 是不可信输入。copyItem 会**原样保留**符号链接:复制成指向同一目标的 link),
            // 若 DMG 顶层有指向挂载点外的 symlink(典型如 `Applications`→/Applications,或恶意的 ../../etc/passwd),
            // 复制进用户目录后用户一跟随就读到挂载点外的敏感文件 → 路径逃逸。解析后逃出挂载点的 symlink 一律跳过。
            if Self.symlinkEscapesMount(item, mountPoint: mountPoint) { continue }
            let target = destination.appendingPathComponent(item.lastPathComponent)
            try fileManager.copyItem(at: item, to: target)
        }
        progress(ArchiveProgressState(fraction: 1, currentFile: nil, statusText: nil, completedUnitCount: total, totalUnitCount: total))
    }

    /// 顶层条目是否为「解析后逃出挂载点」的符号链接(逃逸=不安全,copyContents 跳过)。非 symlink 返回 false。
    /// 逃逸判定走**词法** `.standardized`(收 `..`、不碰 fs、不再跟随更多 symlink),目标不存在也能判,与 ArchiveSafety 同口径。
    private nonisolated static func symlinkEscapesMount(_ item: URL, mountPoint: URL) -> Bool {
        let fm = FileManager.default
        let isSymlink = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        guard isSymlink else { return false }
        guard let raw = try? fm.destinationOfSymbolicLink(atPath: item.path) else { return true }  // 读不到 → 当不安全跳过
        let targetURL = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : URL(fileURLWithPath: raw, relativeTo: item.deletingLastPathComponent())
        let target = targetURL.standardized.path
        let mount = mountPoint.standardized.path
        return !(target == mount || target.hasPrefix(mount + "/"))
    }

    /// 把挂载点下的顶层项目转成 ArchiveItem 数组，用户能在 UI 里浏览。
    /// 目录优先 + 名称自然排序，跟 ArchiveService 别的 backend 一致。
    private nonisolated static func archiveItems(at mountPoint: URL) throws -> [ArchiveItem] {
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
    /// nonisolated：DMG list 串行(mount→list→detach)只读调 `string(from:)`,让 nonisolated 解析路径取它而不弹回主线程。
    private nonisolated static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

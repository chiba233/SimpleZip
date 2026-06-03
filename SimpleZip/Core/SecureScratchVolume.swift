//
//  SecureScratchVolume.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/03.
//
//  「每次会话随机密钥的 AES-256 加密临时卷」—— 所有解密 / 解压临时产物落进这里。
//
//  动机：打开 `.gpg` / `.siz` 等加密档案、或解压任意压缩包时，明文会写进 `/var/folders/.../T/...`。
//  加密的意义就是别让明文裸落盘 —— 这等于把它破坏了。本组件在首次需要时用一个**只存在于内存**的随机
//  密码建一个加密 sparse 镜像并挂载，临时产物全放进去；关 app → detach + 删镜像，密码随进程消失。
//
//  保证：
//  - 正常退出：detach + 删镜像，明文彻底消失。
//  - 崩溃 / 强退：镜像文件留在磁盘但是 **AES-256 密文**（没有内存里的密钥谁都挂不上 / 打不开）；
//    下次启动 `sweepStale()` 强制 detach 遗留挂载 + 删旧镜像。崩溃到下次启动之间挂载点可能仍在
//    （内核持有），这是已知窗口，靠启动清扫收口。
//
//  非沙盒前提：SimpleZip 不开 App Sandbox，启动期自挂载自建加密镜像可行（与 DiskImageBackend 同样用
//  系统 `/usr/bin/hdiutil`）。
//

import Darwin
import Foundation
import Security

/// 进程级单例。线程安全（NSLock）。`ensureMounted()` 给「加密源」fail-closed 调用方；
/// `currentMountPoint` 给「普通临时产物」的同步调用方（未挂载即返回 nil，调用方自行回落）。
///
/// **`nonisolated`**：本类自己用 NSLock 保证线程安全，被 Core 里 `nonisolated` 的临时目录分配函数调用；
/// app target 默认 MainActor 隔离会把它推成 MainActor，导致 nonisolated 调用方编译不过。显式 nonisolated 退出。
nonisolated final class SecureScratchVolume: @unchecked Sendable {
    static let shared = SecureScratchVolume()

    /// 镜像文件名前缀 —— 启动清扫据此识别本应用产生的遗留镜像。
    static let imageNamePrefix = "SimpleZip-Scratch-"
    static let mountNamePrefix = "SimpleZip-Scratch-mnt-"
    private static let volumeName = "SimpleZipScratch"
    /// sparse 镜像逻辑上限（不预分配，按需增长）；够大以扛大压缩包解压。
    private static let maxSize = "500g"

    private let lock = NSLock()
    private var imageURL: URL?
    private var mountPoint: URL?
    private var mountInFlight: Task<MountResult, Error>?

    private init() {}

    /// 镜像 / 挂载点的存放目录 —— 系统临时目录（`/var/folders/.../T`）。
    private static var baseDirectory: URL { FileManager.default.temporaryDirectory }

    // MARK: - 查询

    /// 已挂载则返回挂载根（同步、非阻塞）；未挂载返回 nil。给非敏感临时产物的同步调用方用。
    ///
    /// **校验真的还挂着**：缓存的 mountPoint 可能已被卸载（用户手动 detach / 系统弹出）—— 那样它只是真实磁盘上
    /// 一个普通空目录，再往里写就是明文落进**未加密分区**。卸载即作废缓存 → fail-closed 调用方会触发重挂。
    var currentMountPoint: URL? {
        lock.lock(); defer { lock.unlock() }
        guard let mp = mountPoint else { return nil }
        if Self.isMountedVolume(at: mp) { return mp }
        mountPoint = nil   // 卷已不在 → 作废，强制下次重挂
        return nil
    }

    /// 判定 `url` 是否为「独立挂载卷的根」—— 比对它与父目录的设备号（`st_dev`）：不同 = 跨了挂载点（真挂着）；
    /// 相同 = 没挂（卸载后挂载点退化成父文件系统上的普通目录）。
    private static func isMountedVolume(at url: URL) -> Bool {
        var volStat = stat()
        var parentStat = stat()
        let path = url.path
        let parent = url.deletingLastPathComponent().path
        guard stat(path, &volStat) == 0, stat(parent, &parentStat) == 0 else { return false }
        return volStat.st_dev != parentStat.st_dev
    }

    // MARK: - 挂载（懒加载 + 并发合并）

    /// 确保加密卷已挂载并返回挂载根。**fail-closed**：挂不上就 throw —— 给「加密源解密」这类
    /// 绝不能退回明文落盘的调用方用。并发调用合并到同一次挂载。
    @discardableResult
    func ensureMounted() async throws -> URL {
        if let mp = currentMountPoint { return mp }
        // NSLock 不能跨 await 持有，加锁全放在同步 helper 里。
        let task = inFlightOrStartMount()
        do {
            let result = try await task.value
            commitMount(result)
            return result.mountPoint
        } catch {
            clearInFlight()
            throw error
        }
    }

    private struct MountResult: Sendable { let imageURL: URL; let mountPoint: URL }

    /// 同步：已有进行中的挂载则复用，否则起一次（并发合并）。
    /// 起新挂载前，把上一卷（已被卸载/作废）的镜像句柄交给新任务删除 —— 它已经打不开了，留着白占空间。
    private func inFlightOrStartMount() -> Task<MountResult, Error> {
        lock.lock(); defer { lock.unlock() }
        if let inflight = mountInFlight { return inflight }
        let staleImage = imageURL
        imageURL = nil
        let created = Task { try await SecureScratchVolume.createAndAttach(deletingStaleImage: staleImage) }
        mountInFlight = created
        return created
    }

    /// 同步：挂载成功后落地状态。
    private func commitMount(_ result: MountResult) {
        lock.lock(); defer { lock.unlock() }
        mountPoint = result.mountPoint
        imageURL = result.imageURL
        mountInFlight = nil
    }

    /// 同步：挂载失败后清掉 in-flight，允许下次重试。
    private func clearInFlight() {
        lock.lock(); defer { lock.unlock() }
        mountInFlight = nil
    }

    private static func createAndAttach(deletingStaleImage staleImage: URL? = nil) async throws -> MountResult {
        // 上一卷已被卸载/作废 → 删掉它的旧镜像（已打不开，留着白占空间）。
        if let staleImage { try? FileManager.default.removeItem(at: staleImage) }
        let password = try generatePassword()
        let imageURL = baseDirectory.appendingPathComponent("\(imageNamePrefix)\(UUID().uuidString).sparseimage")

        // 建加密 sparse 镜像（密码经 stdin，不进 ps 输出）。
        _ = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/hdiutil",
            arguments: [
                "create", "-type", "SPARSE", "-fs", "APFS",
                "-encryption", "AES-256", "-stdinpass",
                "-size", maxSize, "-volname", volumeName, imageURL.path
            ],
            inputStrategy: .staticInput(password)
        )

        // 挂载：`-nobrowse -noautoopen` 不污染 Finder / 不自动打开；`-owners off` 让任意用户态写入不受属主限制。
        let mountDir = baseDirectory.appendingPathComponent("\(mountNamePrefix)\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)
        let output: String
        do {
            output = try await BackendProcessRunner.runAndCapture(
                "/usr/bin/hdiutil",
                arguments: [
                    "attach", "-plist", "-stdinpass", "-nobrowse", "-noautoopen",
                    "-owners", "off", "-mountpoint", mountDir.path, imageURL.path
                ],
                inputStrategy: .staticInput(password)
            )
        } catch {
            // 挂载失败：删掉刚建的镜像，避免留垃圾；向上抛让 fail-closed 调用方报错。
            try? FileManager.default.removeItem(at: imageURL)
            throw error
        }

        let mountPoint = parseMountPoint(from: output) ?? mountDir
        return MountResult(imageURL: imageURL, mountPoint: mountPoint)
    }

    /// 从 `hdiutil attach -plist` 输出解析挂载点（与 DiskImageBackend 同套路）。
    static func parseMountPoint(from output: String) -> URL? {
        guard
            let data = output.data(using: .utf8),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]]
        else { return nil }
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                return URL(fileURLWithPath: mountPoint)
            }
        }
        return nil
    }

    /// 生成 32 字节随机密码（base64）。`SecRandomCopyBytes` 失败属系统级异常，向上抛。
    static func generatePassword() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ArchiveError.commandFailed("SecRandomCopyBytes failed: \(status)")
        }
        return Data(bytes).base64EncodedString()
    }

    // MARK: - 拆除（退出时同步尽力）

    /// 退出时调用：detach 挂载 + 删镜像。同步阻塞（`applicationWillTerminate` 不能 await），尽力而为。
    func teardown() {
        lock.lock()
        let mp = mountPoint
        let img = imageURL
        mountPoint = nil
        imageURL = nil
        mountInFlight = nil
        lock.unlock()

        if let mp { Self.detachSync(mountPoint: mp) }
        if let img { try? FileManager.default.removeItem(at: img) }
    }

    /// 同步运行 `hdiutil detach -force`（退出路径用，不能 await）。
    private static func detachSync(mountPoint: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path, "-force"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - 启动清扫（清上次崩溃残留）

    /// 启动时调用：强制 detach 上次会话遗留的 SimpleZip 临时卷，删掉遗留镜像文件。
    /// 镜像本是密文、无害，但留着白占空间；遗留挂载点是明文暴露，必须 detach。
    static func sweepStale() async {
        // 1) 找出仍挂着的本应用镜像并 detach（按 image-path 前缀匹配）。
        if let info = try? await BackendProcessRunner.runAndCapture("/usr/bin/hdiutil", arguments: ["info", "-plist"]),
           let data = info.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let images = plist["images"] as? [[String: Any]] {
            for image in images {
                guard let imagePath = image["image-path"] as? String,
                      URL(fileURLWithPath: imagePath).lastPathComponent.hasPrefix(imageNamePrefix) else { continue }
                if let entities = image["system-entities"] as? [[String: Any]] {
                    for entity in entities where (entity["mount-point"] as? String)?.isEmpty == false {
                        if let mp = entity["mount-point"] as? String {
                            _ = try? await BackendProcessRunner.runAndCapture(
                                "/usr/bin/hdiutil", arguments: ["detach", mp, "-force"])
                        }
                    }
                }
                // 顶层 dev-entry 兜底 detach（有些镜像无 mount-point 仍 attach 着）。
                if let dev = image["image-path"] as? String, dev == imagePath,
                   let devEntry = (image["system-entities"] as? [[String: Any]])?.first?["dev-entry"] as? String {
                    _ = try? await BackendProcessRunner.runAndCapture(
                        "/usr/bin/hdiutil", arguments: ["detach", devEntry, "-force"])
                }
            }
        }

        // 2) 删掉临时目录里遗留的本应用镜像文件（本次会话的镜像此刻还没建，不会误删）。
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) {
            for url in entries where url.lastPathComponent.hasPrefix(imageNamePrefix)
                && url.pathExtension == "sparseimage" {
                try? fm.removeItem(at: url)
            }
            // 遗留的空挂载目录也清掉。
            for url in entries where url.lastPathComponent.hasPrefix(mountNamePrefix) {
                try? fm.removeItem(at: url)
            }
        }
    }
}

//
//  ArchiveBrowserModel+SZSAndDiskImage.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//
//  `.szs` 虚拟目录 + DMG 挂载 / 卸载。两者都是「把外部容器映射成本地文件夹浏览」的特殊路径，归到一处。
//

import Foundation

extension ArchiveBrowserModel {
    /// 把 `.szs` 打开成虚拟目录。
    /// - `manifestURL`：原 `.szs` 路径（地址栏 / title 显示用）；
    /// - `verifyReport`：完整验证报告 —— **只 `.match` 条目**进 allowedFiles。未通过 SHA 校验的 `.mismatch` /
    ///   `.missing` / `.unreadable` 不进虚拟目录，避免「冒充已验证」误导。
    /// - `payloadRoot`：真实的根目录（通常 = `.szs` 所在目录）。
    func openSZSAsVirtualFolder(
        manifestURL: URL,
        verifyReport: SZSArchive.VerifyReport,
        payloadRoot: URL
    ) {
        let standardizedRoot = payloadRoot.standardizedFileURL
        // 只把通过 SHA 校验的条目放进 allowedFiles —— mismatch / missing / unreadable 不进虚拟目录。
        let allowedFiles: Set<URL> = Set(verifyReport.entries.compactMap { entry -> URL? in
            guard case .match(let relativePath, _) = entry else { return nil }
            return standardizedRoot.appendingPathComponent(relativePath).standardizedFileURL
        })
        var allowedDirs: Set<URL> = [standardizedRoot]
        for fileURL in allowedFiles {
            var current = fileURL.deletingLastPathComponent().standardizedFileURL
            // 走到 payloadRoot 为止 —— 上面的目录不该被「虚拟可见」。
            while current.path.hasPrefix(standardizedRoot.path) && current.path != standardizedRoot.path {
                allowedDirs.insert(current)
                current = current.deletingLastPathComponent().standardizedFileURL
            }
        }
        manifestVirtualMode = ManifestVirtualMode(
            manifestURL: manifestURL,
            payloadRoot: standardizedRoot,
            allowedFiles: allowedFiles,
            allowedDirs: allowedDirs
        )
        archiveDisplayOverride = manifestURL
        openFolder(standardizedRoot)
    }

    /// 把 `.gpg` 解密出的**单个普通文件**以虚拟目录形式在 app 内展示（**不丢给 Finder**）。
    ///
    /// 镜像 `.siz`/`.szs` 的处理思路：`.siz` 内层是 archive → `openArchive(displayedAs:)`；这里内层是松散
    /// 文件 → 复用 `.szs` 的 `manifestVirtualMode` 虚拟目录机制。payloadRoot = 解密临时目录（只含这一个文件），
    /// 地址栏 / 标题显示原 `.gpg` 路径而不是丑陋的 `/var/folders/...`。`ManifestVirtualMode.manifestURL`
    /// 这里承载「原 `.gpg` 显示 URL」（字段是通用的「容器显示 URL」，不限 `.szs`）。
    func openDecryptedFileAsVirtualFolder(_ decryptedURL: URL, displayedAs containerURL: URL) {
        let std = decryptedURL.standardizedFileURL
        let root = std.deletingLastPathComponent().standardizedFileURL
        manifestVirtualMode = ManifestVirtualMode(
            manifestURL: containerURL,
            payloadRoot: root,
            allowedFiles: [std],
            allowedDirs: [root]
        )
        archiveDisplayOverride = containerURL
        pendingSelectionURL = std
        openFolder(root)
    }

    /// 退出虚拟目录模式 —— 用户「上一级」走到 payloadRoot 之上 / 主动点退出时调用。
    func exitManifestVirtualMode() {
        manifestVirtualMode = nil
        archiveDisplayOverride = nil
    }

    func openDiskImage(_ url: URL) {
        cleanupMountedDiskImageIfNeeded(for: nil)
        status = L10n.text("status.readingArchive")
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let mountPoint = try await ArchiveService.mountDiskImage(url)
                mountedDiskImage = MountedDiskImageSession(sourceURL: url, mountPoint: mountPoint)
                session.clearArchive()
                mode = .folder(mountPoint)
                reload()
            } catch {
                errorMessage = error.localizedDescription
                status = L10n.text("status.failed")
            }
            isWorking = false
        }
    }

    func cleanupMountedDiskImageIfNeeded(for targetURL: URL?) {
        guard let mountedDiskImage else { return }
        if let targetURL, targetURL.standardizedFileURL.path.hasPrefix(mountedDiskImage.mountPoint.standardizedFileURL.path) {
            return
        }
        let mountPoint = mountedDiskImage.mountPoint
        self.mountedDiskImage = nil
        Task.detached {
            try? await ArchiveService.detachDiskImage(at: mountPoint)
        }
    }
}

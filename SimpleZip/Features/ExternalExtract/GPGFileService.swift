//
//  GPGFileService.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/03.
//
//  「双击打开 .gpg / 右键加密到 .gpg」的**编排层**——无 UI、无 model 依赖，只调 Core
//  （GPGBackend / TemporaryResourceManager / ArchiveService）。镜像 `SignedContainerService` 的定位：
//  主窗口路径（ContentView 浏览）和独立浮窗路径（NSServices）共用同一份编排，不各写一份。
//
//  关键安全约束：`.gpg`/`.pgp`/`.asc` **按后缀不保证是加密数据**，可能是公钥/私钥导出。打开前必须
//  `GPGBackend.classifyFile` 嗅探（只读包头，不解密、不要 passphrase），按类别路由——钥匙串材料走导入、
//  加密数据才解密。本服务只提供「解密 / 加密」两个原子动作；分类与路由决策由调用方（ContentView）做。
//

import Foundation

enum GPGFileService {
    /// 当成「加密文件」识别的后缀。`.asc` 也在内：它可能是装甲加密数据，也可能是公钥/私钥/签名——
    /// 所以**不能只看后缀**，必须配合 `GPGBackend.classifyFile` 嗅探内容再决定动作。
    static let recognizedExtensions: Set<String> = ["gpg", "pgp", "asc"]

    static func isRecognizedGPGFile(_ url: URL) -> Bool {
        recognizedExtensions.contains(url.pathExtension.lowercased())
    }

    /// 从 Finder 外部打开一个 `.gpg`/`.pgp`/`.asc` 时，是否应走「自动解压」式的**独立浮窗解密到文件夹**
    /// （而非主窗口浏览 / 导入 sheet）。镜像压缩包的 Finder 自动解压判定：
    /// - 必须开了「Finder 自动解压」偏好 + 启用 GPG + 后端可用；
    /// - **且内容嗅探为加密数据**（钥匙串材料 / 签名 / 无法识别 → 不自动解密，仍交主窗口处理）。
    /// `classifyFile` 只读包头、不起 gpg、不弹密码，所以这个判定可同步、可在路由分支里反复调用。
    static func shouldAutoDecryptOnExternalOpen(_ url: URL) -> Bool {
        guard AppPreferences.finderOpenAutoExtract,
              AppPreferences.gpgEnabled,
              GPGBackend.isAvailable(),
              isRecognizedGPGFile(url) else { return false }
        return GPGBackend.classifyFile(at: url) == .encryptedMessage
    }

    /// 剥掉一层 `.gpg`/`.pgp`/`.asc` 还原内层文件名：`secret.zip.gpg` → `secret.zip`。
    /// 没有可识别后缀（如装甲 `.asc` 直接命名）→ 退回原名加 `.decrypted`，避免覆盖原文件 / 产出空名。
    static func decryptedInnerName(for url: URL) -> String {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        for ext in [".gpg", ".pgp", ".asc"] where lower.hasSuffix(ext) {
            let stripped = String(name.dropLast(ext.count))
            return stripped.isEmpty ? "\(name).decrypted" : stripped
        }
        return "\(name).decrypted"
    }

    /// 解密一个加密数据文件到**会话级临时目录**（`makeOpenedArchiveItemDirectory`——浏览期间存活，
    /// 下次启动 stale 清理），返回解密产物 URL。调用方负责后续把它当压缩包打开 / reveal。
    ///
    /// - `decryptionKey` / `passphrase` 均 nil 时由 gpg-agent + pinentry-mac 兜底弹密码框
    ///   （公钥模式的私钥 passphrase **只走 pinentry**，SimpleZip 不经手；对称密码同理）。
    static func decryptToTemporary(
        _ encryptedURL: URL,
        decryptionKey: String? = nil,
        passphrase: String? = nil,
        operationID: UUID? = nil
    ) async throws -> URL {
        // **加密源 → fail-closed**：解密产物必落进加密临时卷；卷挂不上就抛错，绝不退回明文裸落盘。
        let tempRoot = try await TemporaryResourceManager.makeSecureTemporaryDirectory(prefix: "SimpleZip-GPGDecrypt")
        let outputURL = tempRoot.appendingPathComponent(decryptedInnerName(for: encryptedURL))
        try await GPGBackend.decrypt(
            fileURL: encryptedURL,
            outputURL: outputURL,
            decryptionKeyFingerprint: decryptionKey,
            passphrase: passphrase,
            operationID: operationID
        )
        return outputURL
    }

    /// 把选中的文件 / 文件夹加密成源旁的 `.gpg`，返回产物 URL（供调用方 reveal / 刷新）。
    ///
    /// - **单个文件** → 直接 `gpg --encrypt`，产物 `name.ext.gpg`，无中转。
    /// - **单个文件夹 / 多选** → 先 `tar` 进**加密临时卷**（fail-closed：明文中转绝不裸落普通磁盘），
    ///   再加密 tar，产物 `base.tar.gpg`（`base` = 单文件夹名 / 所在目录名）。tar 用完即删。
    ///
    /// `recipients`（收件人公钥 fingerprint）与 `symmetricPassphrase` 至少给一个非空，否则
    /// `GPGBackend.encrypt` 会抛错（调用方 / sheet 已用按钮禁用拦在前面，这里是后端最后一道）。
    /// 所有源必须是 `directory` 下的同级项（右键多选天然满足：都在当前文件夹）。
    static func encryptToGPG(
        sources: [URL],
        in directory: URL,
        recipients: [String],
        symmetricPassphrase: String?,
        operationID: UUID? = nil
    ) async throws -> URL {
        let fm = FileManager.default
        guard !sources.isEmpty else { throw ArchiveError.commandFailed("no sources to encrypt") }

        // 单个文件（非目录）→ 直接加密，无需 tar 中转。
        if sources.count == 1 {
            var isDir: ObjCBool = false
            let source = sources[0]
            fm.fileExists(atPath: source.path, isDirectory: &isDir)
            if !isDir.boolValue {
                let destination = encryptedDestination(for: source.lastPathComponent, in: directory)
                try await GPGBackend.encrypt(
                    fileURL: source,
                    recipients: recipients,
                    symmetricPassphrase: symmetricPassphrase,
                    outputURL: destination,
                    operationID: operationID
                )
                return destination
            }
        }

        // 文件夹 / 多选 → tar 到加密临时卷再加密。明文 tar 中转只准落进加密卷，绝不裸落普通磁盘。
        let staging = try await TemporaryResourceManager.makeSecureTemporaryDirectory(prefix: "SimpleZip-GPGEncrypt")
        defer { try? fm.removeItem(at: staging) }
        let rawBase = sources.count == 1 ? sources[0].lastPathComponent : directory.lastPathComponent
        let baseName = rawBase.isEmpty ? "Archive" : rawBase
        let tarURL = staging.appendingPathComponent("\(baseName).tar")
        var tarArguments = ["-cf", tarURL.path, "-C", directory.path]
        tarArguments.append(contentsOf: sources.map { $0.lastPathComponent })
        _ = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/tar",
            arguments: tarArguments,
            operationID: operationID
        )
        let destination = encryptedDestination(for: "\(baseName).tar", in: directory)
        try await GPGBackend.encrypt(
            fileURL: tarURL,
            recipients: recipients,
            symmetricPassphrase: symmetricPassphrase,
            outputURL: destination,
            operationID: operationID
        )
        return destination
    }

    /// 加密目标落点：源文件旁，`name.ext.gpg`；重名则 ` 2`、` 3`… 递增，**绝不覆盖**已有文件。
    static func encryptedDestination(for sourceName: String, in directory: URL) -> URL {
        let fm = FileManager.default
        func candidate(_ tail: String) -> URL {
            directory.appendingPathComponent("\(sourceName)\(tail).gpg")
        }
        var destination = candidate("")
        var n = 2
        while fm.fileExists(atPath: destination.path) {
            destination = candidate(" \(n)")
            n += 1
        }
        return destination
    }
}

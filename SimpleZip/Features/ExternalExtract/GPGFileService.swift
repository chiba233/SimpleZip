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

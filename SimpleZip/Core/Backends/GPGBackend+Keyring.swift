//
//  GPGBackend+Keyring.swift
//  SimpleZip
//
//  0.3.0 架构拆分：从 GPGBackend.swift 按职责切出，纯移动、零行为变更。
//

import Foundation

extension GPGBackend {
    // MARK: - 私有 keyring（SimpleZip 自有 / 走独立 GNUPGHOME）

    /// SimpleZip 私有 GNUPGHOME 目录 `~/Library/Application Support/SimpleZip/gnupg/`。
    ///
    /// **从 `--keyring` 切换到 `--homedir`** 的根因：gpg `--no-default-keyring --keyring <SZ>` 在
    /// `--quick-generate-key` 路径上不可靠（部分 gpg 版本仍写到 `~/.gnupg/pubring.kbx`，加 `--primary-keyring`
    /// 也救不回）。改用 `--homedir <SZ>` = 完全独立的 GNUPGHOME，gpg 没歧义、公钥 + 私钥 + trustdb 全部落到这里。
    ///
    /// **真正的隔离**：之前用 `--keyring` 时私钥仍存 `~/.gnupg/private-keys-v1.d/`；现在用 `--homedir` 后
    /// 私钥进 `<SZ>/gnupg/private-keys-v1.d/`。卸载 SimpleZip 删 Application Support/SimpleZip 即可彻底清理。
    ///
    /// 目录权限设 0700（gpg 强制要求 GNUPGHOME 是 owner-only）。
    /// 自动迁移：发现旧 `<SZ>/keyring/pubring.kbx` 存在且新位置没有 → 移过来，老用户不丢公钥。
    static func simpleZipGPGHomeDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("SimpleZip", isDirectory: true)
            .appendingPathComponent("gnupg", isDirectory: true)
        let existed = FileManager.default.fileExists(atPath: dir.path)
        if !existed {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            migrateLegacySimpleZipKeyring(to: dir)
        }
        // 即使目录已存在也强制 0700，避免老版本 SimpleZip 创建时没设权限导致 gpg 拒用。
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    /// 给 gpg 拼 `--homedir <path>` —— SimpleZip 私有 ring 所有操作（list / import / sign / verify / edit / delete）都加这个。
    static func simpleZipHomedirArguments() -> [String] {
        ["--homedir", simpleZipGPGHomeDirectory().path]
    }

    /// 把老的 `<SZ>/keyring/pubring.kbx`（仅公钥环模式时代）迁移到新 `<SZ>/gnupg/`。
    /// 仅在新 homedir 还没 pubring.kbx 时迁移；用户已经在新 homedir 创建过密钥时跳过避免覆盖。
    private static func migrateLegacySimpleZipKeyring(to newHomedir: URL) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let oldDir = base.appendingPathComponent("SimpleZip", isDirectory: true)
            .appendingPathComponent("keyring", isDirectory: true)
        let oldPubring = oldDir.appendingPathComponent("pubring.kbx")
        let newPubring = newHomedir.appendingPathComponent("pubring.kbx")
        guard FileManager.default.fileExists(atPath: oldPubring.path),
              !FileManager.default.fileExists(atPath: newPubring.path) else { return }
        try? FileManager.default.moveItem(at: oldPubring, to: newPubring)
    }

    // 兼容旧 API（外部 health pane / 高级区路径展示等场合仍引用）。
    /// 已弃用：保留只是为了让 advanced 区「SimpleZip 私有 ring」路径行还能显示路径；新代码请用 `simpleZipGPGHomeDirectory()`。
    static func simpleZipKeyringDirectory() -> URL {
        simpleZipGPGHomeDirectory()
    }

    /// 已弃用：保留显示用；新代码读 `simpleZipGPGHomeDirectory().appendingPathComponent("pubring.kbx")`。
    static func simpleZipPubringPath() -> URL {
        simpleZipGPGHomeDirectory().appendingPathComponent("pubring.kbx")
    }

    /// 已弃用：新代码用 `simpleZipHomedirArguments()`。保留只为编译兼容。
    static func simpleZipKeyringArguments() -> [String] {
        simpleZipHomedirArguments()
    }
}

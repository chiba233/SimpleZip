//
//  GPGBackend+KeyLifecycle.swift
//  SimpleZip
//
//  0.3.0 架构拆分：从 GPGBackend.swift 按职责切出，纯移动、零行为变更。
//

import Foundation

extension GPGBackend {
    // MARK: - 删除 / 修改过期 / 撤销证书

    /// 撤销证书的「撤销原因」枚举（对应 gpg menu 的 0-3 编号）。
    enum GPGRevocationReason: String, CaseIterable, Hashable, Identifiable {
        case none = "0"          // 未指定原因
        case compromised = "1"   // 密钥已泄漏 / 不再可信
        case superseded = "2"    // 密钥已被新密钥替代
        case notUsed = "3"       // 密钥不再被使用

        var id: String { rawValue }
    }

    /// 从指定 ring 删除一把密钥。
    ///
    /// `deleteSecret = true`：私钥也删（`--delete-secret-and-public-key`）；本机有私钥时**必须**走这条，否则只删公钥 gpg 会拒绝。
    /// `deleteSecret = false`：仅删公钥（`--delete-keys`），用于「他人公钥」/ 无私钥场景。
    /// **`--batch --yes` 跳过 gpg 自带交互确认** —— 删除前的「你真的要删吗」对话框由 SimpleZip UI 层做。
    ///
    /// 注意：智能卡 stub 密钥执行删除时，本机 stub 会消失，但**卡上私钥不受影响** —— 重新插卡 `gpg --card-status` 又能拉回来。
    @discardableResult
    static func deleteKey(
        fingerprint: String,
        deleteSecret: Bool,
        source: GPGKeyringSource = .userKeyring
    ) async throws -> String {
        let tool = try resolve()
        var args: [String] = ["--batch", "--yes", "--no-tty"]
        if source == .simpleZipKeyring {
            // SimpleZip 私有走独立 GNUPGHOME（`--homedir <SZ>`）—— 公钥 + 私钥 + trustdb 全部隔离。
            args.insert(contentsOf: simpleZipKeyringArguments(), at: 0)
        }
        if deleteSecret {
            args.append("--delete-secret-and-public-key")
        } else {
            args.append("--delete-keys")
        }
        args.append(fingerprint)
        return try await BackendProcessRunner.runAndCapture(tool, arguments: args)
    }

    /// 修改密钥过期时间。走 `gpg --edit-key <fpr> expire <duration> save` interactive menu。
    /// `gpg-agent + pinentry-mac` 会弹密码框收私钥 passphrase；本函数不接触 passphrase。
    static func setKeyExpiration(
        fingerprint: String,
        expiration: GPGKeyExpiration,
        source: GPGKeyringSource = .userKeyring
    ) async throws {
        let tool = try resolve()
        var args: [String] = ["--batch", "--yes", "--no-tty", "--command-fd", "0"]
        if source == .simpleZipKeyring {
            // SimpleZip 私有走独立 GNUPGHOME（`--homedir <SZ>`）—— 公钥 + 私钥 + trustdb 全部隔离。
            args.insert(contentsOf: simpleZipKeyringArguments(), at: 0)
        }
        args.append(contentsOf: ["--edit-key", fingerprint])
        // expire prompt 输入：duration 字符串（如 `1y` / `2y` / `0` = never）+ save 落盘。
        let commands = "expire\n\(expiration.rawValue)\nsave\n"
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: args,
            inputStrategy: .staticInput(commands)
        )
    }

    /// 生成撤销证书（armor 文本）。把返回值写到用户选的 `.asc` 文件即可日后发布到 keyserver 宣告撤销。
    /// gpg `--gen-revoke` 的 interactive 序列：`y\n<reason>\n<description>\n\ny\n`（reason 0-3，description 可空）。
    /// 私钥 passphrase 由 gpg-agent + pinentry-mac 弹原生密码框收。
    static func generateRevocationCert(
        fingerprint: String,
        reason: GPGRevocationReason,
        description: String,
        source: GPGKeyringSource = .userKeyring
    ) async throws -> String {
        let tool = try resolve()
        // ⚠️ `--no-tty` 必须有：`--gen-revoke` 是交互菜单命令，即便用 `--command-fd 0` 喂回答，
        //    gpg 仍会去开 `/dev/tty` 显示提示；SimpleZip 用 Process 起 gpg 没有控制终端 →
        //    `cannot open '/dev/tty': Device not configured` → 整个生成失败。这是「撤销证书都不工作」的主因。
        //    注意：**不能加 `--batch`** —— batch 会让 gpg 拒绝 `--gen-revoke` 的交互流程。
        var args: [String] = ["--armor", "--no-tty", "--command-fd", "0"]
        if source == .simpleZipKeyring {
            // SimpleZip 私有走独立 GNUPGHOME（`--homedir <SZ>`）—— 公钥 + 私钥 + trustdb 全部隔离。
            args.insert(contentsOf: simpleZipKeyringArguments(), at: 0)
        }
        args.append(contentsOf: ["--gen-revoke", fingerprint])
        let escaped = description.replacingOccurrences(of: "\n", with: " ")
        // gpg --gen-revoke menu：
        //   y       —— 「真要生成撤销证书吗」
        //   <r>     —— 撤销原因编号
        //   <desc>  —— 描述：gpg 提示「输入描述，以空行结束」，所以**结束符就是一个空行**。
        //              非空描述 = 「描述行 + 空行」；空描述 = 「只发一个空行」即结束。
        //   y       —— 「Is this okay?」确认
        // ⚠️ 历史 bug：无论描述是否为空都发 `\(escaped)\n\n`，空描述时第一行空行已结束描述，
        //    多出的第二行空行被当成「Is this okay?」的回答（空 = 默认 N）→ gpg 放弃生成。
        //    所以描述为空时绝不能补那一行。
        let descriptionLines = escaped.isEmpty ? "" : "\(escaped)\n"
        let commands = "y\n\(reason.rawValue)\n\(descriptionLines)\ny\n"
        return try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: args,
            inputStrategy: .staticInput(commands)
        )
    }
}

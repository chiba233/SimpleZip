//
//  GPGBackend+Keyserver.swift
//  SimpleZip
//
//  0.4.3 GPG 面板补全:密钥服务器(keys.openpgp.org)的搜索 / 接收 / 发布。
//  全部走 `--batch` 非交互路径(gpg 2.5:`--batch --with-colons --search-keys` 直接打印
//  结果列表不进交互菜单;`--recv-keys` 输出 IMPORT_OK;`--send-keys` 上传公钥)。
//  网络由 gpg 自带的 dirmngr 承担,SimpleZip 不自己发 HTTP。
//

import Foundation

extension GPGBackend {

    /// 默认密钥服务器 —— keys.openpgp.org:邮箱经验证才可按邮箱搜到,无第三方签名垃圾,GDPR 合规。
    static let defaultKeyserver = "hkps://keys.openpgp.org"

    /// keyserver 搜索的一条命中。
    struct GPGKeyserverHit: Identifiable, Equatable {
        let fingerprint: String
        let userIDs: [String]
        /// 算法名(由 colons 输出的算法编号映射;未知编号原样给数字)。
        let algorithm: String
        let created: Date?

        var id: String { fingerprint }
        var displayFingerprint: String { GPGKey.formatFingerprint(fingerprint) }
    }

    /// 在默认 keyserver 上按邮箱 / 姓名 / 指纹搜索公钥。
    /// 「没搜到」不算错误 —— gpg 以非零退出 + "Not found" 报告,这里归一化成空数组;其它失败照常抛。
    static func searchKeyserver(_ query: String) async throws -> [GPGKeyserverHit] {
        let tool = try resolve()
        do {
            let output = try await BackendProcessRunner.runAndCapture(
                tool,
                arguments: ["--batch", "--no-tty", "--with-colons", "--keyserver", defaultKeyserver, "--search-keys", query]
            )
            return parseKeyserverSearch(output)
        } catch {
            let text = String(describing: error)
            if text.localizedCaseInsensitiveContains("not found") {
                return []
            }
            throw error
        }
    }

    /// 按指纹从默认 keyserver 接收公钥到指定 keyring。返回 gpg 输出(含 imported/unchanged 统计)。
    @discardableResult
    static func receiveKey(fingerprint: String, into ring: GPGKeyringSource = .userKeyring) async throws -> String {
        let tool = try resolve()
        var args = ["--batch", "--no-tty", "--keyserver", defaultKeyserver, "--recv-keys"]
        if ring == .simpleZipKeyring {
            args.insert(contentsOf: simpleZipKeyringArguments(), at: 0)
        }
        args.append(fingerprint)
        return try await BackendProcessRunner.runAndCapture(tool, arguments: args)
    }

    /// 把一把公钥发布到默认 keyserver。**公开动作** —— 调用方必须先经用户显式确认。
    /// keys.openpgp.org 收到后会给 UID 邮箱发验证邮件,验证过的邮箱才能被按邮箱搜索到。
    static func publishKey(fingerprint: String) async throws {
        let tool = try resolve()
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: ["--batch", "--no-tty", "--keyserver", defaultKeyserver, "--send-keys", fingerprint]
        )
    }

    /// 解析 `--batch --with-colons --search-keys` 的输出。格式(gpg 2.5):
    /// ```
    /// info:1:1
    /// pub:D477…6BF7:22:256:1701906891::
    /// uid:%3Cdkg@debian.org%3E:1705467792::
    /// ```
    /// `pub` 行字段:1=完整指纹 2=算法编号 3=位数 4=创建时间(epoch);`uid` 行字段 1 是百分号转义的 UID。
    nonisolated static func parseKeyserverSearch(_ output: String) -> [GPGKeyserverHit] {
        var hits: [GPGKeyserverHit] = []
        var fingerprint: String?
        var algorithm = ""
        var created: Date?
        var userIDs: [String] = []

        func flush() {
            if let fingerprint, !fingerprint.isEmpty {
                hits.append(GPGKeyserverHit(fingerprint: fingerprint, userIDs: userIDs, algorithm: algorithm, created: created))
            }
        }

        for line in output.split(separator: "\n") {
            let fields = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "pub" where fields.count >= 5:
                flush()
                fingerprint = fields[1].uppercased()
                algorithm = Self.algorithmName(code: fields[2], bits: fields[3])
                created = TimeInterval(fields[4]).map { Date(timeIntervalSince1970: $0) }
                userIDs = []
            case "uid" where fields.count >= 2:
                // gpg 用百分号转义冒号等字符(%3C = '<')。
                if let decoded = fields[1].removingPercentEncoding, !decoded.isEmpty {
                    userIDs.append(decoded)
                }
            default:
                break
            }
        }
        flush()
        return hits
    }

    /// OpenPGP 算法编号 → 可读名(RFC 4880 / RFC 9580)。未知编号给 "算法 N"式回退,不留空。
    nonisolated private static func algorithmName(code: String, bits: String) -> String {
        let name: String
        switch code {
        case "1", "2", "3": name = "RSA"
        case "16", "20": name = "ElGamal"
        case "17": name = "DSA"
        case "18": name = "ECDH"
        case "19": name = "ECDSA"
        case "22": name = "EdDSA"
        default: name = "#\(code)"
        }
        return bits.isEmpty || bits == "0" ? name : "\(name)-\(bits)"
    }
}

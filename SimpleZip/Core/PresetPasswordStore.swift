//
//  PresetPasswordStore.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation
import LocalAuthentication
import Security

/// 「预设密码」的本机安全存储 + Touch ID 揭示。
///
/// 设计动机：早期实现把预设密码直接放在 UserDefaults 里（明文 plist），
/// 任何能读用户偏好的进程或备份都能拿到，安全性堪忧。这里改用 Keychain：
/// 1) 仅 SimpleZip 自己（按 code-signing 隔离）能读写；
/// 2) 设置 `kSecAttrAccessibleAfterFirstUnlock` —— 用户解锁后 SimpleZip 进程能静默读；
/// 3) 系统备份不会带出（默认 ThisDeviceOnly 兜底语义）。
///
/// 揭示密码（设置页眼睛按钮）必须经过 `requestReveal()` 走 LAContext —— 没通过 Touch ID
/// 或本机口令就不显示明文，避免「点眼睛即明文」的肩窥风险。
/// 业务侧（创建压缩包自动填、解压自动尝试）调用 `load()` 静默读取，
/// 不弹 Touch ID 提示，否则每次解压都按指纹会逼用户关掉这个功能。
enum PresetPasswordStore {
    /// Service 标识符 —— 与 app bundle 解耦，将来改 bundle id 时需要兼容旧值。
    private static let service = "yumeka.SimpleZip.PresetPassword"
    /// 单一账号 —— 当前只有一个预设密码，未来扩展多档可以改成 ${profile}。
    private static let account = "default"
    /// 旧版本（0.1.6 开发期短暂用过 UserDefaults 明文）遗留 key，迁移后会清掉。
    private static let legacyUserDefaultsKey = "presetPassword"

    /// 进程内缓存：每次 app 启动后第一次 load 触发 Keychain 访问（dev 期的 ad-hoc 签名会弹「允许访问」对话框），
    /// 之后所有 load 直接读缓存，避免重复弹框。save / clear 会同步更新缓存。
    /// 用 NSLock 保护，因为业务侧的 Task.detached 可能在非 main 线程读取。
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedValue: String?

    // MARK: - 读取 / 写入 / 清除

    /// 业务侧静默读取入口。返回空字符串表示尚未配置。
    /// 第一次调用时会顺手把残留在 UserDefaults 里的明文搬到 Keychain 并删掉。
    static func load() -> String {
        cacheLock.lock()
        if let cached = cachedValue {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        migrateLegacyIfNeeded()
        let value = readKeychain()

        cacheLock.lock()
        cachedValue = value
        cacheLock.unlock()
        return value
    }

    /// 保存预设密码。空字符串等同 `clear()`。
    /// 失败（如 Keychain 拒绝）静默忽略，调用方下次 load 会拿到空字符串，UI 自己会显示「未配置」。
    static func save(_ value: String) {
        if value.isEmpty {
            clear()
            return
        }
        writeKeychain(value)
        UserDefaults.standard.removeObject(forKey: legacyUserDefaultsKey)
        cacheLock.lock()
        cachedValue = value
        cacheLock.unlock()
    }

    /// 把 Keychain 里的预设密码彻底删掉。
    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: legacyUserDefaultsKey)
        cacheLock.lock()
        cachedValue = ""
        cacheLock.unlock()
    }

    /// 设置页眼睛按钮调用：要求用户做一次本机认证（Touch ID / Mac 解锁口令）才解锁明文显示。
    /// - 返回 true：UI 可以把密码框切到明文；
    /// - 返回 false：保持掩码（包含「用户取消」「无生物识别」「认证失败」三种）。
    static func requestReveal(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        // .deviceOwnerAuthentication 在没 Touch ID 的 Mac（旧 Intel）会自动回落到登录口令。
        let policy: LAPolicy = .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &error) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch {
            return false
        }
    }

    // MARK: - Keychain 实现细节

    private static func readKeychain() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue as Any
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return value
    }

    private static func writeKeychain(_ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // 已存在 → 更新内容（值变化时常见）；不存在 → SecItemAdd 新建。
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            // 用户首次登录后即可读 —— 不需要每次解锁都再认证（业务静默读取要求）。
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private static func migrateLegacyIfNeeded() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: legacyUserDefaultsKey), !legacy.isEmpty else {
            return
        }
        // 仅在 Keychain 还没有值时迁移；已有值代表用户后续在新版本里又设过，以新值为准。
        if readKeychain().isEmpty {
            writeKeychain(legacy)
        }
        defaults.removeObject(forKey: legacyUserDefaultsKey)
    }
}

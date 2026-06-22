//
//  SuiteDefaults.swift
//  SimpleZipCoreTests
//
//  测试用隔离 UserDefaults 工厂。每个临时域用唯一 suiteName(UUID),持有者(测试 suite 实例)
//  释放时自动 removePersistentDomain —— 测试不再往真实 ~/Library/Preferences 堆 plist。
//
//  背景:`UserDefaults(suiteName:)` 一建就在 ~/Library/Preferences 落一个 plist。此前各 store
//  测试虽用唯一 suiteName 做并行隔离(对),却没在测试结束清理(漏),每跑一次就堆数百个 plist。
//
//  用法:测试 suite 改 `final class`(才有 deinit),持有 `private let suiteDefaults = SuiteDefaults()`,
//  用 `suiteDefaults.make("Label")` 取隔离的 UserDefaults。Swift Testing 为每个 @Test 新建 suite
//  实例 → 测试结束实例释放 → deinit 清掉本测试建过的所有临时域。一个测试内可多次 make(各自独立域)。
//
import Foundation

final class SuiteDefaults {
    private var suiteNames: [String] = []

    /// 取一个隔离的、起始为空的 UserDefaults;其域会在本工具实例释放时自动清理。
    func make(_ label: String) -> UserDefaults {
        let name = "\(label).\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)   // 起始干净(防御,正常新域本就空)
        return defaults
    }

    deinit {
        let prefsDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Preferences", isDirectory: true)
        for name in suiteNames {
            // ① 清 cfprefsd 内存域。
            UserDefaults.standard.removePersistentDomain(forName: name)
            // ② 注销 suite —— 让 cfprefsd 不再持有它,否则进程退出 flush 时会把它重建成 42 字节空壳。
            UserDefaults.standard.removeSuite(named: name)
            // ③ 删掉可能残留的空壳文件兜底。
            if let file = prefsDir?.appendingPathComponent("\(name).plist") {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

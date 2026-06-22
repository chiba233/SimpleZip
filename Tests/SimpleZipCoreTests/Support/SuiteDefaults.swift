//
//  SuiteDefaults.swift
//  SimpleZipCoreTests
//
//  测试用隔离键值存储工厂。每个 `make()` 产出一个独立的**内存** store(`InMemoryKeyValueStore`)——
//  **不落 ~/Library/Preferences**,根治 CLI `swift test` 退出时 cfprefsd 重建空壳 plist 的顽疾。
//
//  历史:曾用 `UserDefaults(suiteName:)` + deinit 三连(removePersistentDomain / removeSuite / 删文件),但 cfprefsd
//  在进程退出 flush 时仍把每个临时域重建成 42 字节空壳,in-process 拦不住(实测一次 swift test 堆上百个)。各 store
//  的 `defaults` 现已协议化为 `KeyValueDataStore`,测试直接注入内存实现 → 零落盘、cfprefsd 无从重建。
//
//  用法:测试持有 `private let suiteDefaults = SuiteDefaults()`,用 `suiteDefaults.make("Label")` 取隔离 store。
//  (测试 suite 不必再为 deinit 改 `final class` —— 已无需任何清理;改了也无妨。)
//
import Foundation
@testable import SimpleZipCore

final class SuiteDefaults {
    /// 取一个隔离的、起始为空的内存键值存储。`label` 仅作可读标识(不再生成 suiteName、不落盘)。
    func make(_ label: String) -> KeyValueDataStore {
        InMemoryKeyValueStore()
    }
}

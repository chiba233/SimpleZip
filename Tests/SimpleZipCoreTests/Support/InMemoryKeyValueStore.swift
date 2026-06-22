//
//  InMemoryKeyValueStore.swift
//  SimpleZipCoreTests
//
//  测试用**内存**键值存储:conform `KeyValueDataStore`,数据只在内存 Dictionary,**绝不落 ~/Library/Preferences**。
//  取代 `UserDefaults(suiteName:)` 做测试隔离 —— 后者每建一个临时域就在 Preferences 落一个 plist,且 cfprefsd 会在
//  CLI `swift test` 进程退出 flush 时把它重建成 42 字节空壳,in-process 清理拦不住(实测堆上百个)。各 store 的
//  `defaults` 已协议化为 `KeyValueDataStore`,测试注入它即可零落盘。
//
//  加锁:store 测试通常单线程,但个别后端会在 nonisolated 上下文读写 → 用 NSLock 保线程安全(@unchecked Sendable)。
//

import Foundation
@testable import SimpleZipCore

final class InMemoryKeyValueStore: KeyValueDataStore, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Any] = [:]

    func data(forKey key: String) -> Data? { lock.withLock { store[key] as? Data } }
    func set(_ data: Data, forKey key: String) { lock.withLock { store[key] = data } }
    func string(forKey key: String) -> String? { lock.withLock { store[key] as? String } }
    func set(_ string: String?, forKey key: String) { lock.withLock { store[key] = string } }
    func stringArray(forKey key: String) -> [String]? { lock.withLock { store[key] as? [String] } }
    func set(_ array: [String], forKey key: String) { lock.withLock { store[key] = array } }
    func removeObject(forKey key: String) { lock.withLock { store[key] = nil } }
}

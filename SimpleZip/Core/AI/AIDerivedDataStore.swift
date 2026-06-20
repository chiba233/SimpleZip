//
//  AIDerivedDataStore.swift
//  SimpleZipCore
//
//  独立 AI 进程改造 · 阶段0a 抽出 / 阶段2 移入 Core · 派生 AI 数据的**独立文件存储**。
//
//  原本随 `AIBackgroundIndexStore`(App target)定义。阶段2 后台索引迁 agent 后,agent 也要按同一布局
//  读 / 写这份派生数据(写回索引、读回沿用旧摘要)→ 下沉 Core,App 与 agent 共用同一份(不复制)。
//

import Foundation

/// 阶段0a:派生 AI 数据(索引本体 `AIFileMemoryIndex` + 下游预烘焙缓存 folderGroups / organize / workbench*)的
/// **独立文件存储**,从 UserDefaults(偏好域)解耦出来 —— 这些是体量可能很大、且**不是用户偏好**的派生数据,
/// 不该塞进偏好、也不该进偏好备份(白皮书迁移清单:这批 key 迁出偏好)。每个 key 一份 JSON 文件,放
/// `Application Support/<bundle id>/AIDerivedData/`。接口刻意对齐 UserDefaults 的 `data(forKey:)` /
/// `set(_:forKey:)` / `removeObject(forKey:)`,让从偏好搬迁是机械替换、最小 diff。
///
/// 只持不可变的 `directory`、无共享可变状态 → 跨上下文安全。按 bundle id 隔离目录:dev(`.dev`)与正式版各用各的,
/// 互不污染。**agent 进程必须传显式 `directory:`**(A19:agent 的 `Bundle.main` 指向符号链接母目录、不可信,
/// 默认 init 的 `Bundle.main.bundleIdentifier` 会落错域)—— App 共享路径 = `Application Support/<App bundle id>/AIDerivedData`,
/// 由 agent 侧据约定 App bundle id 显式拼出后传入。App 进程继续用默认 init(`Bundle.main` 即 App 自身,正确)。
nonisolated final class AIDerivedDataStore {
    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            let bundleID = Bundle.main.bundleIdentifier ?? "SimpleZip"
            self.directory = base
                .appendingPathComponent(bundleID, isDirectory: true)
                .appendingPathComponent("AIDerivedData", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func fileURL(forKey key: String) -> URL {
        // key 形如 "SimpleZip.ai.fileMemoryIndex.v1"(含点、无斜杠),可直接做文件名。
        directory.appendingPathComponent(key + ".json", isDirectory: false)
    }

    func data(forKey key: String) -> Data? {
        try? Data(contentsOf: fileURL(forKey: key))
    }

    /// 原子写(写临时文件再 rename),杜绝半写文件污染下次解码。
    func set(_ data: Data, forKey key: String) {
        try? data.write(to: fileURL(forKey: key), options: .atomic)
    }

    func removeObject(forKey key: String) {
        try? FileManager.default.removeItem(at: fileURL(forKey: key))
    }
}

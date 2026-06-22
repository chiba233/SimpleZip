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

/// 大对象的**键值持久化后端抽象** —— `data / set / removeObject(forKey:)`。`UserDefaults` 与 `AIDerivedDataStore`
/// (文件后端)都 conform,让"体量大、非偏好"的数据(AI 派生缓存、归档清单缓存、活动历史、AI 工作区快照…)能把
/// 持久化后端从偏好域换成文件:偏好域(plist)有 CFPreferences 的 **4 MB 单值硬上限**,且整份 domain 随每次进程
/// 启动加载并在每次写时整体重序列化 —— 大对象一旦塞进去,任何写都 fault + 反复重序列化,拖垮**每一次**启动
/// (App Intents 后台 helper 因此没能在连接窗口内 ready → Shortcuts 报「Couldn't communicate…」,实测)。
/// 生产一律走文件后端;测试可注入内存 `UserDefaults`(快、隔离),无需碰盘。
nonisolated protocol KeyValueDataStore {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func string(forKey key: String) -> String?
    func set(_ string: String?, forKey key: String)
    func stringArray(forKey key: String) -> [String]?
    func set(_ array: [String], forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: KeyValueDataStore {
    /// `data(forKey:)` / `string(forKey:)` / `stringArray(forKey:)` / `removeObject(forKey:)` 已是 `UserDefaults` 原生
    /// 签名;只需把「Data / String / [String] 专用」的 set 适配到原生 `Any?` 版(更具体的实参类型会优先选这些重载,语义等价)。
    public nonisolated func set(_ data: Data, forKey key: String) { set(data as Any?, forKey: key) }
    public nonisolated func set(_ string: String?, forKey key: String) { set(string as Any?, forKey: key) }
    public nonisolated func set(_ array: [String], forKey key: String) { set(array as Any?, forKey: key) }
}

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
nonisolated final class AIDerivedDataStore: KeyValueDataStore {
    private let directory: URL

    /// `subdirectory` 决定落盘子目录(`Application Support/<bundle id>/<subdirectory>/`):AI 派生数据沿用默认
    /// `AIDerivedData`;归档清单缓存等"非 AI 的通用大对象"传各自的子目录(如 `DerivedData`),分目录隔离、互不混淆。
    init(directory: URL? = nil, subdirectory: String = "AIDerivedData") {
        if let directory {
            self.directory = directory
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            let bundleID = Bundle.main.bundleIdentifier ?? "SimpleZip"
            self.directory = base
                .appendingPathComponent(bundleID, isDirectory: true)
                .appendingPathComponent(subdirectory, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// 文件存储**根目录**(`Application Support/<bundle id>/`,各 subdirectory —— `AIDerivedData` / `DerivedData` —— 的父)。
    /// 与默认 init 的目录同源(同 base + 同 bundle id),只是不带 subdirectory。供 DevTools「关键路径」跳转 / 诊断用。
    static var storeRootDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "SimpleZip", isDirectory: true)
    }

    private func fileURL(forKey key: String) -> URL {
        // key 形如 "SimpleZip.ai.fileMemoryIndex.v1"(含点、无斜杠),可直接做文件名。
        directory.appendingPathComponent(key + ".json", isDirectory: false)
    }

    func data(forKey key: String) -> Data? {
        try? Data(contentsOf: fileURL(forKey: key))
    }

    /// 文件后端把 string 桥成 UTF-8 Data 存取(生产用它的 store 只存 Data;string 仅为满足协议、给注入 string 的 store 兜底)。
    func string(forKey key: String) -> String? {
        data(forKey: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// 原子写(写临时文件再 rename),杜绝半写文件污染下次解码。
    func set(_ data: Data, forKey key: String) {
        try? data.write(to: fileURL(forKey: key), options: .atomic)
    }

    func set(_ string: String?, forKey key: String) {
        if let string { set(Data(string.utf8), forKey: key) } else { removeObject(forKey: key) }
    }

    /// [String] 同样桥成 JSON Data 存取(生产用它的 store 不存 [String];仅为满足协议、给注入 [String] 的 store 兜底)。
    func stringArray(forKey key: String) -> [String]? {
        data(forKey: key).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
    }

    func set(_ array: [String], forKey key: String) {
        if let data = try? JSONEncoder().encode(array) { set(data, forKey: key) }
    }

    func removeObject(forKey key: String) {
        try? FileManager.default.removeItem(at: fileURL(forKey: key))
    }
}

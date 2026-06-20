//
//  AIAgentConfiguration.swift
//  SimpleZipAgentSupport(由 App + SimpleZipAIAgent + SimpleZipAIXPCService 三 target 共同编译)
//
//  独立 AI 进程改造 · 阶段1 · App → agent 的**配置同步 payload**(坑 9:带 schemaVersion 协商)。
//  App 把当前 AI 设置编码成它发给 agent,agent 解码后存进 AIAgentConfigurationStore,据此门控生成
//  (红线:`aiAssistantEnabled == false` = 整个 agent AI 能力禁用,前台也不豁免)。agent 回报自己支持的
//  schemaVersion,供 App 将来跨版本时按版本降级。
//
//  **只用基本类型(Bool / Int / String)**:让 agent / XPC Service target 不必 link SimpleZipCore 即可编 ——
//  与 AIAgentXPCProtocol / AIAgentService 同处共享层。活跃度档位用 AIBackgroundActivityLevel.rawValue 的裸
//  字符串携带(不引 Core 枚举),App 侧负责转换。XPC 传输时编成 Data(JSON),避免把 Swift 类型直接暴露给 XPC。
//

import Foundation

public nonisolated struct AIAgentConfiguration: Codable, Sendable, Equatable {
    /// 当前 schema 版本。App 与 agent 同构建时天然对齐(本文件三 target 同编、值一致);跨版本时靠它协商。
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// AI 主开关。**红线:false = 整个 agent AI 能力禁用**(不生成、不索引、不预读)。
    public var aiAssistantEnabled: Bool
    /// AI 建议子开关。
    public var aiSuggestionEnabled: Bool
    /// 后台索引开关。
    public var indexingEnabled: Bool
    /// 内容预读开关。
    public var contentPrereadEnabled: Bool
    /// 后台活跃度档位(AIBackgroundActivityLevel.rawValue 裸字符串)。
    public var activityLevel: String

    public init(schemaVersion: Int = AIAgentConfiguration.currentSchemaVersion,
                aiAssistantEnabled: Bool, aiSuggestionEnabled: Bool,
                indexingEnabled: Bool, contentPrereadEnabled: Bool, activityLevel: String) {
        self.schemaVersion = schemaVersion
        self.aiAssistantEnabled = aiAssistantEnabled
        self.aiSuggestionEnabled = aiSuggestionEnabled
        self.indexingEnabled = indexingEnabled
        self.contentPrereadEnabled = contentPrereadEnabled
        self.activityLevel = activityLevel
    }

    /// 前台 AI 是否该响应(主 + 子开关都开)。agent 前台生成的红线门控。
    public var foregroundAIAllowed: Bool { aiAssistantEnabled && aiSuggestionEnabled }

    /// XPC 传输用:编成 JSON Data(失败回空 Data,agent 侧解码会判失败拒绝)。
    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    /// 从 XPC 收到的 Data 解码;不兼容 / 损坏回 nil(agent 据此拒绝、回报版本协商失败)。
    public static func decoded(from data: Data) -> AIAgentConfiguration? {
        try? JSONDecoder().decode(AIAgentConfiguration.self, from: data)
    }

    // MARK: - 持久化(App 写 / agent 读;让 App 关着被 launchd 拉起的后台 agent 也能拿到配置,尤其红线主开关)

    /// App bundle id(按构建配置隔离 dev/prod)。三 target #if DEBUG 一致对齐(同 SimpleZipAIAgentXPCNames)。
    #if DEBUG
    public static let appBundleID = "yumeka.SimpleZip-in-mac.dev"
    #else
    public static let appBundleID = "yumeka.SimpleZip-in-mac"
    #endif

    /// 持久化文件:`Application Support/<app bundle id>/AIAgentConfig.json`(dev/prod 各自隔离)。
    public static func persistedFileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent(appBundleID, isDirectory: true)
                   .appendingPathComponent("AIAgentConfig.json")
    }

    /// App 侧:原子写文件。任何 agent 进程启动都能 loadPersisted 读到最新配置。
    public func persist() {
        guard let url = AIAgentConfiguration.persistedFileURL() else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoded().write(to: url, options: .atomic)
    }

    /// agent 侧:读持久化文件;不存在 / 损坏回 nil(agent 退回默认放行)。
    public static func loadPersisted() -> AIAgentConfiguration? {
        guard let url = persistedFileURL(), let data = try? Data(contentsOf: url) else { return nil }
        return decoded(from: data)
    }
}

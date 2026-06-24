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
    /// v4:加 `languageName`(agent 后台烘焙按用户界面语言出摘要)。
    public static let currentSchemaVersion = 4

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
    /// agent 调度:**静默后台索引总开关**(App 关闭后 agent 是否继续后台索引)。false = App 关了不后台跑(独立
    /// opt-in,与「打开应用时索引」分开)。下面的间隔 / timeout 只在它为 true 时有意义。
    public var silentBackgroundIndexEnabled: Bool
    /// agent 调度:后台索引触发间隔(小时)。launchd 按它周期拉起 agent 跑一轮(AI 索引迁 agent 后生效)。
    public var backgroundIndexIntervalHours: Int
    /// agent 调度:单次后台运行最长 timeout(秒),超时停、下次继续。电源门控仍复用现有 AIBackgroundSchedulingRules。
    public var maxBackgroundRunSeconds: Int
    /// 用户界面语言名(英文描述,如 "Simplified Chinese")—— agent 后台烘焙据此让模型用对的语言出摘要 / 解释。
    /// App 用 `AIReportAssistant.uiLanguageName` 填;旧 payload 无此字段时解码回退 "English"。
    public var languageName: String

    public init(schemaVersion: Int = AIAgentConfiguration.currentSchemaVersion,
                aiAssistantEnabled: Bool, aiSuggestionEnabled: Bool,
                indexingEnabled: Bool, contentPrereadEnabled: Bool, activityLevel: String,
                silentBackgroundIndexEnabled: Bool,
                backgroundIndexIntervalHours: Int, maxBackgroundRunSeconds: Int,
                languageName: String = "English") {
        self.schemaVersion = schemaVersion
        self.aiAssistantEnabled = aiAssistantEnabled
        self.aiSuggestionEnabled = aiSuggestionEnabled
        self.indexingEnabled = indexingEnabled
        self.contentPrereadEnabled = contentPrereadEnabled
        self.activityLevel = activityLevel
        self.silentBackgroundIndexEnabled = silentBackgroundIndexEnabled
        self.backgroundIndexIntervalHours = backgroundIndexIntervalHours
        self.maxBackgroundRunSeconds = maxBackgroundRunSeconds
        self.languageName = languageName
    }

    // 向后兼容:旧 payload(schema ≤3)无 `languageName` → 解码回退 "English"(其余字段照常)。
    enum CodingKeys: String, CodingKey {
        case schemaVersion, aiAssistantEnabled, aiSuggestionEnabled, indexingEnabled
        case contentPrereadEnabled, activityLevel, silentBackgroundIndexEnabled
        case backgroundIndexIntervalHours, maxBackgroundRunSeconds, languageName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        aiAssistantEnabled = try c.decode(Bool.self, forKey: .aiAssistantEnabled)
        aiSuggestionEnabled = try c.decode(Bool.self, forKey: .aiSuggestionEnabled)
        indexingEnabled = try c.decode(Bool.self, forKey: .indexingEnabled)
        contentPrereadEnabled = try c.decode(Bool.self, forKey: .contentPrereadEnabled)
        activityLevel = try c.decode(String.self, forKey: .activityLevel)
        silentBackgroundIndexEnabled = try c.decode(Bool.self, forKey: .silentBackgroundIndexEnabled)
        backgroundIndexIntervalHours = try c.decode(Int.self, forKey: .backgroundIndexIntervalHours)
        maxBackgroundRunSeconds = try c.decode(Int.self, forKey: .maxBackgroundRunSeconds)
        languageName = (try c.decodeIfPresent(String.self, forKey: .languageName)) ?? "English"
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

    /// 读 / 写 **App 偏好域**(`appBundleID`)的 UserDefaults —— 跨进程共享(scope 白名单 / 运行遥测等)统一走它。
    /// 当**当前进程的 `Bundle.main.bundleIdentifier` 恰好等于 `appBundleID`** 时
    /// —— App 自己,或 agent 被 launchd 当**嵌入 helper**(`SimpleZip.app/Contents/MacOS/SimpleZipAIAgent`)
    /// 直接拉起、其 `Bundle.main` 解析到 app bundle —— `UserDefaults(suiteName: appBundleID)` 会被系统判为
    /// 「拿自己的 bundle id 当 suite」而**失效**(返回读不到数据的实例 + 控制台告警),后台索引就会读到空白名单。
    /// 这种情况下 `.standard` 正好就是该域;否则(agent 独立 / 经符号链接 → bundle id ≠ appBundleID 或为 nil)
    /// 用 suiteName 跨进程读 App 域。两条路最终都落到同一个 appBundleID 域。
    public static func appDomainDefaults() -> UserDefaults {
        if Bundle.main.bundleIdentifier == appBundleID { return .standard }
        return UserDefaults(suiteName: appBundleID) ?? .standard
    }

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

/// 后台 agent **运行遥测**:agent 每次被 launchd 拉起跑 `--background-index` 都记一笔(无论真扫还是因间隔/让位跳过),
/// 这样 App / DevTools 能确认「后台 agent 到底有没有真被拉起过、几次、最近何时、结果如何」——光有「上次成功索引」时间戳
/// 看不出 launchd 是否在按计划唤醒。偏好域 = App bundle id(A19):agent 用 suiteName 写,App 同域可读。
public enum AIAgentRunTelemetry {
    public static let runCountKey = "SimpleZip.ai.agent.bgRunCount.v1"
    public static let lastWakeKey = "SimpleZip.ai.agent.bgLastWake.v1"
    public static let lastOutcomeKey = "SimpleZip.ai.agent.bgLastOutcome.v1"

    public struct Snapshot: Sendable {
        public let runCount: Int
        public let lastWake: Date?
        public let lastOutcome: String?
        public init(runCount: Int, lastWake: Date?, lastOutcome: String?) {
            self.runCount = runCount
            self.lastWake = lastWake
            self.lastOutcome = lastOutcome
        }
    }

    /// agent 侧:每次 `--background-index` 唤醒后记一笔(计数++、最近唤醒时刻、最近结果说明)。
    public static func recordWake(outcome: String, at date: Date) {
        let defaults = AIAgentConfiguration.appDomainDefaults()
        defaults.set(defaults.integer(forKey: runCountKey) + 1, forKey: runCountKey)
        defaults.set(date.timeIntervalSince1970, forKey: lastWakeKey)
        defaults.set(outcome, forKey: lastOutcomeKey)
    }

    /// App 侧:读运行遥测。
    public static func read() -> Snapshot {
        let defaults = AIAgentConfiguration.appDomainDefaults()
        let epoch = defaults.double(forKey: lastWakeKey)
        return Snapshot(
            runCount: defaults.integer(forKey: runCountKey),
            lastWake: epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil,
            lastOutcome: defaults.string(forKey: lastOutcomeKey))
    }
}

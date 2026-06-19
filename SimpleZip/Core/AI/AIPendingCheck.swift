//
//  AIPendingCheck.swift
//  SimpleZip
//
//  0.4.5 #80:只读自动检查的「pending 队列」(用户 2026-06-18 拍板的两阶段架构)。
//
//  这些**只读**行为(自动哈希 / 自动测试 / 自动安全检测 / 自动发布包检测)分两步:
//  - **没插电(电池)**:AI 只决定「哪个文件该做哪种检查」→ 入队成 pending(便宜、电池可跑)。
//  - **插电后**:逐个**执行**真检查(真 I/O,耗能),任务间按活跃度间隔节流(越激进越短),避免高耗能尖峰。
//
//  **幂等**:同一(文件路径 + 行为)只一条;文件指纹(size + mtime)没变且已 done 就不重做,改了才重排。
//  纯值类型 + 确定性队列逻辑(SwiftPM 可断言);持久化 / 执行 / 调度在 app 侧。**只读红线**:这些行为不写不删不放行。
//

import Foundation

nonisolated struct AIPendingCheck: Codable, Equatable, Sendable, Identifiable {
    /// 只读自动检查的种类。新增种类前确认它**只读安全**(不写盘、不放行、不删)。
    nonisolated enum Behavior: String, Codable, Equatable, Sendable, CaseIterable {
        case hash        // 算 SHA-256 → 内联「当前文件 sha256 为 xxx」
        case test        // 测试归档完整性 → 内联「已通过自动测试」
        case security    // 归档安全检测 → 内联白话介绍
        case inspect     // 发布包检测 → 内联白话介绍
    }

    nonisolated enum Status: String, Codable, Equatable, Sendable {
        case pending, done, failed
    }

    let path: String
    let behavior: Behavior
    /// 文件指纹(size + mtime):改了指纹变 → 允许重排;没变 + done → 不重做(和预读「没变就跳过」同口径)。
    let fingerprint: String
    var status: Status
    let queuedAt: Date
    var executedAt: Date?

    /// 去重身份 = 行为 + 路径(同文件同检查恒一条;指纹变了**替换**而非新增)。
    var id: String { AIPendingCheck.identity(path: path, behavior: behavior) }

    static func identity(path: String, behavior: Behavior) -> String { "\(behavior.rawValue)\n\(path)" }

    /// 从文件元数据算指纹(size + mtime 秒级)。
    static func fingerprint(byteSize: Int64?, modifiedAt: Date?) -> String {
        "\(byteSize ?? -1):\(modifiedAt.map { Int($0.timeIntervalSince1970) } ?? 0)"
    }

    init(path: String, behavior: Behavior, fingerprint: String, status: Status = .pending,
         queuedAt: Date, executedAt: Date? = nil) {
        self.path = path
        self.behavior = behavior
        self.fingerprint = fingerprint
        self.status = status
        self.queuedAt = queuedAt
        self.executedAt = executedAt
    }
}

/// 纯值队列:确定性 enqueue(幂等去重)/ 取下一个 pending / 标记结果 / 修剪。app 侧 store 持久化它。
nonisolated struct AIPendingCheckQueue: Codable, Equatable, Sendable {
    private(set) var checks: [AIPendingCheck]
    let maxEntries: Int

    init(checks: [AIPendingCheck] = [], maxEntries: Int = 500) {
        self.checks = checks
        self.maxEntries = maxEntries
    }

    /// 幂等入队。同 (path, behavior):
    /// - 指纹相同 → 不动(已排队 / 已做 / 已失败,都不重复);
    /// - 指纹不同(文件改了)→ 替换成新的 pending(重新检查)。
    /// 新 (path, behavior) → 追加 pending。返回是否有新增 / 变更。
    @discardableResult
    mutating func enqueue(path: String, behavior: AIPendingCheck.Behavior,
                          fingerprint: String, now: Date) -> Bool {
        let identity = AIPendingCheck.identity(path: path, behavior: behavior)
        if let idx = checks.firstIndex(where: { $0.id == identity }) {
            guard checks[idx].fingerprint != fingerprint else { return false }   // 没改 → 不重做
            checks[idx] = AIPendingCheck(path: path, behavior: behavior, fingerprint: fingerprint,
                                         status: .pending, queuedAt: now)
            return true
        }
        checks.append(AIPendingCheck(path: path, behavior: behavior, fingerprint: fingerprint,
                                     status: .pending, queuedAt: now))
        trim()
        return true
    }

    /// 下一个待执行(最早入队的 pending;确定性)。
    func nextPending() -> AIPendingCheck? {
        checks.filter { $0.status == .pending }.min { $0.queuedAt < $1.queuedAt }
    }

    var pendingCount: Int { checks.lazy.filter { $0.status == .pending }.count }
    var doneCount: Int { checks.lazy.filter { $0.status == .done }.count }

    /// 标记某条执行结果(done / failed)。
    mutating func mark(id: String, status: AIPendingCheck.Status, executedAt: Date) {
        guard let idx = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[idx].status = status
        checks[idx].executedAt = executedAt
    }

    /// 该 (path, behavior, 指纹) 是否已做完 —— 给幂等查询 / 「内联结果还算不算数」用。
    func isDone(path: String, behavior: AIPendingCheck.Behavior, fingerprint: String) -> Bool {
        let identity = AIPendingCheck.identity(path: path, behavior: behavior)
        return checks.contains { $0.id == identity && $0.fingerprint == fingerprint && $0.status == .done }
    }

    /// 修剪:done / failed 超过保留期的清掉,再按上限裁最旧(pending 不裁)。
    mutating func prune(doneRetention: TimeInterval, now: Date) {
        checks.removeAll {
            ($0.status == .done || $0.status == .failed)
                && now.timeIntervalSince($0.executedAt ?? $0.queuedAt) > doneRetention
        }
        trim()
    }

    /// 上限保护:超了先留全部 pending,再按时间留最近的 done / failed,裁最旧。
    private mutating func trim() {
        guard checks.count > maxEntries else { return }
        let pending = checks.filter { $0.status == .pending }
        let finished = checks.filter { $0.status != .pending }
            .sorted { ($0.executedAt ?? $0.queuedAt) > ($1.executedAt ?? $1.queuedAt) }
        checks = Array((pending + finished).prefix(maxEntries))
    }
}

/// 插电后 pending 任务之间的**间隔**(秒),按活跃度:越激进越短(用户拍板 4 / 15 / 30 分钟)。
nonisolated enum AIPendingCheckSchedule {
    static func interval(for level: AIBackgroundActivityLevel) -> TimeInterval {
        switch level {
        case .aggressive: return 4 * 60
        case .balanced:   return 15 * 60
        case .powerSaver: return 30 * 60
        case .off:        return .greatestFiniteMagnitude   // off = 不执行
        }
    }
}

/// 只读检查**执行完后**「值不值得内联展示」的复判(用户拍板的「执行完再判」那一步)。
/// - hash / test 是**事实必显**(算出 sha256 / 测过了就显示),不走这里。
/// - security / inspect 走这里:**没异常 / 不值得就不冒**(否则会弹「这个包很干净」这种废话建议)。
///
/// 纯函数,SwiftPM 可测。确定性只筛掉「全干净」的;真有异常时再交端上模型润色成白话(模型空返=仍不显示),
/// 符合「拒绝假 AI」—— 这里不发明结论,只判断「有没有值得说的东西」。
nonisolated enum AIPendingCheckJudge {
    /// 路径安全检测:有任何安全发现、或评级被某维度拉低(`dominant` 非空)才值得展示;全干净不冒。
    static func securityWorthSurfacing(findings: [ArchiveSecurityFinding],
                                       assessment: ArchiveRiskScore.Assessment) -> Bool {
        !findings.isEmpty || assessment.dominant != nil
    }

    /// 发布包检测:有安全发现 / 有 macOS 垃圾 / 完整性测试没过 / 有 bundle 级问题才值得展示;干净的发布包不冒。
    static func inspectWorthSurfacing(report: ReleaseInspectionReport) -> Bool {
        !report.securityFindings.isEmpty
            || (report.stats?.junkCount ?? 0) > 0
            || report.testPassed == false
            || !report.bundleFindings.isEmpty
    }
}

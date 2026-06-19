//
//  AIReportAssistant.swift
//  SimpleZip
//
//  0.4.4 · macOS 26 AI:FoundationModels 本地模型的统一封装。
//
//  **红线**:只读输入 · 生成文本 · 绝不进安全写入路径 —— 不删文件、不放行危险路径、不忽略签名失败、
//  不自动修复 / 覆盖。AI 只「解释 · 分类 · 建议」,产出落进可编辑文本框由用户审阅后自行使用。
//  全本地推理、不外发;prompt 绝不包含加密归档条目名 / 内容、GPG 密文、口令、解密明文(见隐私口径)。
//
//  可用性跨基线收敛:macOS < 26 恒不可用;26+ 再看系统模型 availability + 用户主开关。
//  任一不满足 → 调用点把入口 disabled / 隐藏,UI 永不因 AI 崩。
//

import Foundation
import FoundationModels

enum AIReportAssistant {
    /// AI 入口是否该出现:用户主开关开 + macOS 26+ + 系统模型 available。
    static var isReady: Bool {
        guard AppPreferences.aiAssistantEnabled else { return false }
        guard #available(macOS 26.0, *) else { return false }
        return SystemLanguageModel.default.isAvailable
    }

    /// macOS 26+ 但模型当前不可用的人话原因(给 disabled 按钮 / 设置说明)。可用时返回空串。
    static var unavailableReason: String {
        guard #available(macOS 26.0, *) else { return L10n.text("ai.unavailable.osTooOld") }
        switch SystemLanguageModel.default.availability {
        case .available:
            return ""
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return L10n.text("ai.unavailable.deviceNotEligible")
            case .appleIntelligenceNotEnabled:
                return L10n.text("ai.unavailable.notEnabled")
            default:
                return L10n.text("ai.unavailable.modelNotReady")
            }
        }
    }

    /// 生成文本。仅 macOS 26+ 调用(调用点已用 `isReady` 守卫)。失败抛出,UI 显示错误文案、不崩。
    /// 自动把「用当前界面语言回复」硬加进 instructions —— 本机模型没语言信号时会默认英文(用户实测中文界面
    /// 出英文),显式指定才稳。所有 AI 功能共用这条,prompt 里不必再各写一遍。
    ///
    /// **串行(修崩溃)**:本机 FoundationModels 是共享单例资源。创建/解压速览会随 token(格式/级别/异步估算)
    /// 动态重跑,SwiftUI `.task(id:)` 把上一个 respond() 中途拆毁、同时起下一个 —— 重叠 + 中途拆毁让框架在
    /// 迭代 transcript 时越界 trap(用户实测崩溃栈)。所有模型调用统一过 `AIGenerationSerializer`:一次只跑
    /// 一个,且一旦开始就跑到底(不随调用方取消)。见 [[feedback_no_published_on_reload_path]] 同类「动态重跑」教训。
    @available(macOS 26.0, *)
    static func generate(instructions: String, prompt: String) async throws -> String {
        let combined = instructions + "\n\n" + replyLanguageInstruction
        return try await AIGenerationSerializer.shared.run {
            let session = LanguageModelSession(instructions: combined)
            // ⚠️ 绝不给 respond() 套**可取消的超时**:超时取消会丢下一个**还没真停**的 respond,污染 FoundationModels
            // 的 transcript 状态机 → 下一个串行调用遍历 transcript 时越界 trap(用户实测崩溃栈,`catch` 接不住)。
            // serializer 的链尾等的是这个 operation 跑到底 —— 必须让它等**真正的 respond 完成**,而非超时提前返回,
            // 否则「表面串行、底层重叠」。prompt 已在各 pass 封顶,正常 respond 很快;真卡死宁可阻塞后台生成也不崩。
            return try await session.respond(to: prompt).content
        }
    }

    /// 「整段回复用 <当前界面语言>」—— 按 app 语言覆盖优先,否则取实际加载的本地化。
    nonisolated static var replyLanguageInstruction: String {
        "Write your entire reply in \(uiLanguageName). Do not restate these instructions; reply only with the note itself."
    }

    /// 当前界面语言的英文名(给 prompt 指定输出语言用)。app 语言覆盖优先,否则取实际加载的本地化。
    /// **结构化生成里给人看的字段(目录名 / 理由)也要按这个本地化**(用户报 AI 文件夹名固定英文)。
    nonisolated static var uiLanguageName: String {
        let code: String
        let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        if let language = AppLanguage(rawValue: raw), let explicit = language.localizationCode {
            code = explicit
        } else {
            code = Bundle.main.preferredLocalizations.first ?? "en"
        }
        if code.hasPrefix("zh-Hant") || code.hasPrefix("zh-HK") || code.hasPrefix("zh-TW") {
            return "Traditional Chinese"
        } else if code.hasPrefix("zh") {
            return "Simplified Chinese"
        } else if code.hasPrefix("ja") {
            return "Japanese"
        } else if code.hasPrefix("ko") {
            return "Korean"
        } else if code.hasPrefix("de") {
            return "German"
        } else if code.hasPrefix("es") {
            return "Spanish"
        } else if code.hasPrefix("fr") {
            return "French"
        } else if code.hasPrefix("ru") {
            return "Russian"
        } else if code.hasPrefix("th") {
            return "Thai"
        } else {
            return "English"
        }
    }
}

/// AI 入口在不可用时被点到的兜底错误(理论上 isReady 已挡住,防御性留一个)。
struct AIAssistError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 模型调用的**全局串行闸**(修 FoundationModels transcript 越界崩溃)。
///
/// 本机 on-device 模型是共享资源,**重叠的 `respond()` 会让框架在迭代 session transcript 时越界 trap**
/// (实测:创建/解压内联速览随格式/级别/异步估算动态重跑,`.task(id:)` 把上一个生成中途拆毁、同时起下一个)。
/// 这里把所有生成排成一条链:`operation` 一个接一个跑,**绝不重叠**;承载它的是 unstructured `Task`,
/// **不随调用方 Task 取消而中途拆毁**(中途拆毁正是崩因)—— 调用方取消只是不再等结果,生成自身跑到底后被丢弃。
@available(macOS 26.0, *)
actor AIGenerationSerializer {
    static let shared = AIGenerationSerializer()

    /// 链尾:下一个生成要等它结束才开始(只关心「结束」,不关心结果类型,故抹成 Void)。
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) async throws -> T {
        let prior = tail
        // unstructured Task:不继承调用方的取消 —— 保证 respond() 跑到底,框架不被中途拆毁。
        let work = Task { () -> Result<T, Error> in
            _ = await prior?.value          // 等上一个生成彻底结束,杜绝重叠
            do { return .success(try await operation()) }
            catch { return .failure(error) }
        }
        tail = Task { _ = await work.value }  // 新链尾(Void 化)
        return try await work.value.get()
    }
}

// MARK: - 自然语言查询(NL → 结构化「过滤 / 定位」规格,App 端确定性应用,AI 绝不执行)

// 这些 `@Generable` 规格是 AI 的**唯一**输出形态:它把用户的一句话映射成一组**受约束的字段**,
// 由调用点的 Swift 代码确定性地翻成现有的过滤 / 跳转动作(只读展示 / 导航,从不写入、不放行)。
// 字段一律用 String + `@Guide` 列出允许值,Swift 端做容错映射(模型给了界外值就退回安全默认),
// 避免依赖「@Generable 枚举」的细节、也更耐模型抖动。

// #60 活动中心「一句话筛选」(NL → ActivityFilterSpec)已随建议六 v2 砍除 —— 工作台改用确定性的
// 「建议筛选 chip × AI 推荐时间维度」双重叠加(见 ActivityAIWorkbenchView),不再有自然语言筛选输入框。
// 对应的 @Generable 过滤枚举 / struct / `activityFilterSpec(for:)` 一并移除(无其它调用方)。

/// #63:归档清单缓存自然语言查询 —— 一句话 → 一个用来在已缓存归档里搜的**文件名关键词**。
@available(macOS 26.0, *)
@Generable
struct ArchiveFileQuerySpec: Sendable {
    @Guide(description: "The single most useful file-name keyword to search archives for, extracted from the user's request. A bare word or short phrase, no punctuation, no path. Empty if the request names no file.")
    var keyword: String
}

/// #64:设置自然语言搜索 —— 一句话 → 命中的设置标识 + 想要的动作(只导航 / 建议切换)。
@available(macOS 26.0, *)
@Generable
enum SettingIntent: String, Equatable { case navigate, enable, disable }

@available(macOS 26.0, *)
@Generable
struct SettingsQuerySpec: Sendable {
    @Guide(description: "The id of the single best-matching setting from the provided catalog, copied verbatim. Empty string if nothing in the catalog matches the request.")
    var settingID: String
    @Guide(description: "What the user wants done with that setting: navigate to find it, enable it, or disable it. Use navigate unless the user clearly asks to turn it on or off.")
    var intent: SettingIntent
}

@available(macOS 26.0, *)
extension AIReportAssistant {
    /// 结构化生成的薄封装:不注入回复语言(输出是受约束的 token / 关键词,不是给人读的散文)。
    /// 同样过全局串行闸,和散文生成共用同一条链 —— 杜绝任何两个 `respond()` 重叠(见 `AIGenerationSerializer`)。
    /// **同一串行槽内连试 `maxAttempts` 代**:本机 @Generable 结构化生成偶发不符 schema 抛错(越复杂 / 越长越易),
    /// 每代换个新 session 再试,尽量成功;全部败才抛给调用点。默认 2(轻量查询够用);重 schema(如 AI 文件夹复核)
    /// 传更高的代数把报错压到near-zero。所有尝试都在同一槽内,不与其它生成重叠。
    static func generateStructured<T: Generable & Sendable>(
        instructions: String, prompt: String, as type: T.Type, maxAttempts: Int = 2
    ) async throws -> T {
        try await AIGenerationSerializer.shared.run {
            var lastError: Error?
            for _ in 0..<max(1, maxAttempts) {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    // 不套可取消超时(见 `generate` 注释:取消 respond 会污染 transcript 状态机 → 下次越界 trap)。
                    return try await session.respond(to: prompt, generating: type).content
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? AIAssistError(message: "structured generation failed after retries")
        }
    }

    /// #63:从用户的一句话里抽出最有用的文件名关键词(用来跑现有的「哪个归档含某文件」缓存查询)。
    static func archiveFileKeyword(for query: String) async throws -> String {
        let instructions = """
        The user is looking for a file they remember is inside some archive. Extract the single most useful \
        file-name keyword to search for. Prefer a concrete noun or the likely file name; drop filler words. \
        Return just the keyword, no punctuation or path.
        """
        return try await generateStructured(instructions: instructions, prompt: query, as: ArchiveFileQuerySpec.self).keyword
    }

    /// #64:把用户的一句话映射到一个设置(从传入目录里选)+ 想要的动作。catalog 是「id\\t标题\\t说明」多行。
    static func settingsQuerySpec(for query: String, catalog: String) async throws -> SettingsQuerySpec {
        let instructions = """
        The user describes a setting they want to find or change in an archive app. From the catalog below \
        (one per line as "id<TAB>title<TAB>summary"), pick the single best-matching setting and copy its id \
        verbatim, and decide the intent: navigate (just find it), enable (turn it on) or disable (turn it \
        off). If nothing matches, return an empty id. Output only the two fields.

        Catalog:
        \(catalog)
        """
        return try await generateStructured(instructions: instructions, prompt: query, as: SettingsQuerySpec.self)
    }
}

// MARK: - Prompt 构造(纯字符串组装,只读输入)

extension AIReportAssistant {
    /// 喂给模型时,每类发现取这么多条**真实条目路径**做样本 —— 让 AI 说得出具体的「哪个文件」而不是
    /// 空泛的「可能有些问题,请检查」(用户原话:数据太薄 AI 就是废话文学)。隐私:这些是**未加密**清单
    /// 里的条目路径(头加密的归档根本列不出名字,自然不会进来),非加密路径登录用户本就可见,不必脱敏;
    /// 但 prompt 永不含加密内容 / GPG 密文 / 口令 / 解密明文。见 [[feedback_privacy_only_encrypted]]。
    static func sampleEntries(_ paths: [String], perKind: Int = 5) -> String {
        let samples = paths.prefix(perKind)
        let more = paths.count - samples.count
        let joined = samples.joined(separator: ", ")
        return more > 0 ? "\(joined), +\(more) more" : joined
    }

    /// A:发布检查报告 → 风险总结。给计数 + 关键信号 + **真实样本条目路径**(数据太薄 AI 只会输出空泛
    /// 套话;喂具体条目它才能说出「哪个文件值得注意」)。隐私按 `sampleEntries`(只非加密清单路径)。
    static func riskSummaryPrompt(for report: ReleaseInspectionReport) -> (instructions: String, prompt: String) {
        let instructions = """
        You are a release-engineering assistant for the SimpleZip archive manager. Given an inspection \
        report for an archive that is about to be published, write a short, plain-language risk summary \
        for the person publishing it: first say whether it looks publishable, then a few concise bullet \
        points on anything noteworthy. Be specific and concrete — when an example entry illustrates a \
        point, name it; avoid vague filler. Use only the facts provided — never invent issues. Do not \
        give instructions to delete files or change anything. Reply in the user's language.
        """
        var lines: [String] = ["Archive: \(report.archiveURL.lastPathComponent)"]
        if let stats = report.stats {
            lines.append("Files: \(stats.fileCount), folders: \(stats.folderCount), total bytes: \(stats.totalBytes)")
            lines.append("macOS junk entries: \(stats.junkCount), empty directories: \(stats.emptyDirectoryCount), executables: \(stats.executableCount), symlinks: \(stats.symlinkCount)")
        }
        if let passed = report.testPassed { lines.append("Integrity test passed: \(passed)") }
        if let failure = report.testFailureMessage { lines.append("Integrity test failure: \(failure)") }
        if report.hasComment { lines.append("Archive carries a header comment.") }
        // 可疑路径:给真实样本条目,不只给计数(UI 列得出,prompt 之前却只发数字 = AI 空泛)。
        if report.securityFindings.isEmpty {
            lines.append("Suspicious-path findings: none.")
        } else {
            lines.append("Suspicious-path findings by type, with example entries (non-encrypted listing paths):")
            for finding in report.securityFindings {
                lines.append("- \(finding.kind.rawValue) (\(finding.entryPaths.count)): \(sampleEntries(finding.entryPaths, perKind: 4))")
            }
        }
        lines.append("SHA256SUMS actually written: \(report.wroteChecksums)")
        if let publicKey = report.publicKeyBesideSignature {
            lines.append("Public key sits beside the signature container: \(publicKey)")
        }
        // App bundle / 磁盘镜像检查:给每条的严重度 + 标题 + detail 具体内容(签名 / 公证 / 镜像挂载等)。
        if !report.bundleFindings.isEmpty {
            lines.append("App-bundle / disk-image checks:")
            for f in report.bundleFindings {
                var part = "\(f.severity): \(L10n.text(f.titleKey))"
                if let detail = f.detail, !detail.isEmpty { part += " — \(detail)" }
                lines.append("- \(part)")
            }
        }
        // 质量门违规:逐条列规则名 + 是否阻断,而非只给总数。
        if !report.gateViolations.isEmpty {
            lines.append("Quality-gate violations:")
            for v in report.gateViolations {
                lines.append("- \(v.rule.rawValue)\(v.isBlocking ? " (BLOCKING)" : " (warning)")\(v.count.map { " ×\($0)" } ?? "")")
            }
        }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// D:失败任务 → 大白话解释 + 建议。喂失败消息 + 命令输出尾部(口令本就不进后端输出,安全)。
    static func failureExplanationPrompt(taskTitle: String, failureMessage: String, output: String?) -> (instructions: String, prompt: String) {
        let instructions = """
        You are a helpful assistant for the SimpleZip archive manager. A background task failed. \
        Explain, in plain language for a non-expert, the most likely reason it failed and what the user \
        could try next. Point at the specific error lines from the log when they explain the failure — be \
        concrete, not generic. Base your answer only on the provided error and log; if the cause is \
        unclear, say so. Never tell the user to delete files or run destructive commands. Reply in the \
        user's language.
        """
        var lines: [String] = ["Task: \(taskTitle)", "Error: \(failureMessage)"]
        if let output, !output.isEmpty {
            // 尾部 ~6000 字符:UI 把命令输出折叠,这里给模型更全的日志才能指向具体出错行(口令本就不进后端输出,安全)。
            let tail = output.count > 6000 ? "…(earlier output truncated)\n" + String(output.suffix(6000)) : output
            lines.append("Command output:\n\(tail)")
        }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// B:把已生成的 GitHub Issue Markdown 润色得更易读(已脱敏,直接喂)。
    static func issuePolishPrompt(rawIssue: String) -> (instructions: String, prompt: String) {
        let instructions = """
        You are a developer assistant. Rewrite the following auto-generated GitHub issue so it reads \
        clearly for maintainers: keep every technical fact (versions, environment table, error, logs) \
        and keep all "[REDACTED]" markers untouched, but improve the structure and add a one-line \
        summary at the top. Do not invent details. Reply in the user's language.
        """
        return (instructions, rawIssue)
    }

    /// C:批量体检结果 → 给每个包建议描述标签(只建议、不参与任何安全判定 / 不改状态)。
    static func checkupLabelsPrompt(for report: ArchiveCheckupReport) -> (instructions: String, prompt: String) {
        let instructions = """
        You are an archive-triage assistant for the SimpleZip archive manager. For each archive in this \
        batch checkup, suggest a few short, descriptive labels (e.g. release-artifact, source-archive, \
        backup, installer, corrupted, encrypted, contains-macOS-junk, possible-duplicate, missing-volumes, \
        read-only). Base labels ONLY on the facts given — these are suggestions, not a verdict. Output one \
        line per archive in the form "filename: label, label". Reply in the user's language.
        """
        var lines: [String] = ["Checkup scope: \(report.scopeName)"]
        for row in report.rows {
            var parts: [String] = []
            switch row.testOutcome {
            case .passed: parts.append("integrity test passed")
            case .failed(let kind): parts.append("integrity test failed (\(kind.rawValue))")
            case .needsPassword: parts.append("needs a password")
            case .notListable: parts.append("not listable")
            }
            // 规模 + 真实样本条目(UI 只展示计数;喂给 AI 这些细节,标签才具体不空泛)。
            if row.fileCount > 0 { parts.append("files: \(row.fileCount)") }
            if row.totalBytes > 0 {
                parts.append("size: \(ByteCountFormatter.string(fromByteCount: row.totalBytes, countStyle: .file))")
            }
            if let facts = row.facts {
                parts.append("suspicious paths: \(facts.suspiciousPathCount)")
                parts.append("macOS junk entries: \(facts.junkCount)")
                parts.append("encrypted entries: \(facts.encryptedCount)")
            }
            if !row.suspiciousSamplePaths.isEmpty {
                parts.append("suspicious e.g. \(row.suspiciousSamplePaths.prefix(4).joined(separator: ", "))")
            }
            if !row.junkSampleNames.isEmpty {
                parts.append("junk e.g. \(row.junkSampleNames.prefix(4).joined(separator: ", "))")
            }
            if row.missingVolumeCount > 0 { parts.append("missing volumes: \(row.missingVolumeCount)") }
            if row.readOnlyFormat { parts.append("read-only format") }
            if !row.duplicatePeers.isEmpty { parts.append("structurally identical to \(row.duplicatePeers.count) other(s)") }
            lines.append("\(row.fileName): \(parts.joined(separator: ", "))")
        }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// #51:安全报告 A/B/C → 白话解释。**只解释规则评分,绝不自己判安全 / 不重新定级 / 不放行**
    /// (评分由确定性规则系统给出,AI 只把字母等级和发现类型翻成人话 + 解压时该留意什么)。
    /// 只喂等级 + 每类发现的计数(不放具体条目路径,够解释也更稳)。
    static func securityExplanationPrompt(
        archiveName: String,
        assessment: ArchiveRiskScore.Assessment,
        findings: [ArchiveSecurityFinding]
    ) -> (instructions: String, prompt: String) {
        let instructions = """
        You are a safety assistant for the SimpleZip archive manager. The app already graded this \
        archive's path safety with a deterministic rule system (A = low risk, B = medium, C = high). \
        Explain to a non-expert, in plain language, what the grade means and what each finding type is — \
        and for the risky ones, what to watch for when extracting. Use ONLY the facts given; never invent \
        findings, never tell the user to delete files or override a safety prompt, and do not contradict \
        or re-grade the rule-based score. Keep it short. Reply in the user's language.
        """
        var lines: [String] = [
            "Archive: \(archiveName)",
            "Rule-based grade: \(assessment.grade.rawValue.uppercased()) (\(assessment.level.rawValue) risk)"
        ]
        if let dominant = assessment.dominant {
            lines.append("Most serious issue driving the grade: \(dominant.dimension.rawValue) (\(dominant.count) flagged entries)")
        } else {
            lines.append("No risk-affecting issues found.")
        }
        // 喂**全部**加权因素(不只 dominant)—— 让 AI 把每一项参与定级的维度都说清,而非只解释最重的那个。
        if !assessment.contributions.isEmpty {
            let all = assessment.contributions
                .map { "\($0.dimension.rawValue) ×\($0.count) [\($0.severity.rawValue)]" }
                .joined(separator: ", ")
            lines.append("All weighted factors (severity-ordered): \(all)")
        }
        if findings.isEmpty {
            lines.append("Suspicious-path findings: none.")
        } else {
            // 给 AI 真实样本条目(非加密清单路径),它才能具体指出「哪个文件为什么危险」,而非泛泛而谈。
            lines.append("Suspicious-path findings by type, with example entries (non-encrypted listing paths):")
            for finding in findings {
                lines.append("- \(finding.kind.rawValue) (\(finding.entryPaths.count)): \(sampleEntries(finding.entryPaths))")
            }
        }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// 归档抽屉内联「发布包检测」:确定性只读检查已经完成,AI 只把计数事实压成一句白话介绍。
    /// Prompt 刻意中性:不点名任何 App / 平台 / 具体软件,不建议发布 / 修复 / 放行。
    static func inlineReleaseInspectionPrompt(for report: ReleaseInspectionReport) -> (instructions: String, prompt: String) {
        let instructions = """
        Explain a read-only archive inspection result in exactly one plain-language sentence. Use only the \
        provided facts. Do not mention any app, vendor, product, marketplace, publishing platform, or \
        specific software name. Do not tell the user to publish, extract, delete, repair, trust, override a \
        warning, or take action. Do not present a security verdict; describe what the checks found.
        """
        var lines: [String] = [
            "Report kind: read-only archive inspection",
            "Listing available: \(report.listable)"
        ]
        if let passed = report.testPassed {
            lines.append("Integrity test passed: \(passed)")
        } else {
            lines.append("Integrity test passed: unknown")
        }
        if let stats = report.stats {
            lines.append("Files: \(stats.fileCount)")
            lines.append("Folders: \(stats.folderCount)")
            lines.append("Total bytes: \(stats.totalBytes)")
            lines.append("Metadata junk entries: \(stats.junkCount)")
            lines.append("Empty folders: \(stats.emptyDirectoryCount)")
            lines.append("Executable entries: \(stats.executableCount)")
            lines.append("Symbolic links: \(stats.symlinkCount)")
        }
        lines.append("Suspicious path finding types: \(report.securityFindings.count)")
        lines.append("Has archive comment: \(report.hasComment)")
        return (instructions, lines.joined(separator: "\n"))
    }

    /// 归档抽屉内联「路径安全报告」:规则系统已经定级,AI 只解释这一份只读报告的一句话摘要。
    static func inlinePathSafetyPrompt(
        assessment: ArchiveRiskScore.Assessment,
        findings: [ArchiveSecurityFinding],
        listable: Bool
    ) -> (instructions: String, prompt: String) {
        let instructions = """
        Explain a read-only archive path-safety report in exactly one plain-language sentence. Use only the \
        provided facts. Do not mention any app, vendor, product, marketplace, publishing platform, or \
        specific software name. Do not tell the user to extract, delete, repair, trust, override a warning, \
        or take action. Do not re-grade the report; describe the deterministic rule result and what was \
        found.
        """
        var lines: [String] = [
            "Report kind: read-only path-safety analysis",
            "Listing available: \(listable)",
            "Rule grade: \(assessment.grade.rawValue.uppercased())",
            "Rule level: \(assessment.level.rawValue)"
        ]
        if let dominant = assessment.dominant {
            lines.append("Dominant issue: \(dominant.dimension.rawValue) (\(dominant.count) entries)")
        } else {
            lines.append("Dominant issue: none")
        }
        if findings.isEmpty {
            lines.append("Finding types: none")
        } else {
            lines.append("Finding types:")
            for finding in findings {
                lines.append("- \(finding.kind.rawValue): \(finding.entryPaths.count)")
            }
        }
        return (instructions, lines.joined(separator: "\n"))
    }

    // MARK: - 报告富化批:更多报告接 AI 解释(每条都喂比 UI 更全的具体数据)

    /// GPG 验签结果 → 给模型的事实句(签名是否有效·可信·谁签的·有何隐患)。
    private static func signatureFacts(_ sig: GPGBackend.GPGVerifyResult) -> String {
        switch sig {
        case .validSignature(let signer, let fingerprint, let trusted, let concerns):
            var s = "Signature is cryptographically VALID. Signer: \(signer ?? "unknown"). Key fingerprint: \(fingerprint ?? "n/a"). Key trust in your keyring: \(trusted ? "trusted" : "NOT trusted")."
            if !concerns.isEmpty { s += " Concerns: \(concerns.map(\.rawValue).sorted().joined(separator: ", "))." }
            return s
        case .unknownSigner(let keyID):
            return "Signature matches, but the signer's public key is NOT in your keyring (key ID \(keyID ?? "unknown")) — the signer's identity is unverified."
        case .badSignature(let signer, let fingerprint):
            return "Signature is BAD — the content does not match the signature (tampered, corrupted, or wrong key). Claimed signer: \(signer ?? "unknown"), fingerprint \(fingerprint ?? "n/a")."
        case .verificationError(let message):
            return "Signature could not be checked (gpg error): \(message)"
        }
    }

    /// #52:.szs / .siz 签名验证 → 白话解释。**绝不建议忽略坏 / 不可信签名。**
    static func szsVerifyExplanationPrompt(
        signature: GPGBackend.GPGVerifyResult,
        manifest: SZSArchive.Manifest,
        report: SZSArchive.VerifyReport
    ) -> (instructions: String, prompt: String) {
        let instructions = """
        You explain a signed-container (.szs / .siz) verification result to a non-expert: whether the \
        cryptographic signature is valid AND trusted, who signed it, and whether every file still matches \
        the SHA-256 recorded in the signed manifest. Be specific — name the problem files. NEVER advise \
        the user to ignore or override a bad or untrusted signature; if the signature is bad or the key \
        isn't trusted, say plainly the container should not be trusted. Reply in the user's language.
        """
        var lines: [String] = [signatureFacts(signature), "Manifest says signed by: \(manifest.createdBy)"]
        if let title = manifest.title, !title.isEmpty { lines.append("Title: \(title)") }
        if let desc = manifest.description, !desc.isEmpty { lines.append("Description: \(desc)") }
        let s = report.summary
        lines.append("Files: \(s.total) total — \(s.matched) match the manifest, \(s.mismatched) mismatched, \(s.missing) missing, \(s.unreadable) unreadable. All files OK: \(s.allFilesOk).")
        let problems = report.entries.compactMap { entry -> String? in
            switch entry {
            case .match: return nil
            case .mismatch(let path, _, _): return "mismatch (hash differs): \(path)"
            case .missing(let path): return "missing: \(path)"
            case .unreadable(let path, let reason): return "unreadable: \(path) (\(reason))"
            }
        }
        if !problems.isEmpty {
            lines.append("Problem entries (examples):")
            problems.prefix(8).forEach { lines.append("- \($0)") }
        }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// #52:.siz 打开前的签名信息 sheet → 白话解释(签名是否有效·可信·谁签的·内层是否被改动)。
    /// **绝不建议打开坏 / 不可信签名的容器。**
    static func sizSignatureExplanationPrompt(signature: SIZSignatureSummary) -> (instructions: String, prompt: String) {
        let instructions = """
        You explain a .siz signed-container's signature to a non-expert who is about to open it: whether \
        the signature is cryptographically valid AND the signer's key is trusted, who signed it, and \
        whether the inner content is unmodified. The ONLY reason to advise against opening is a BAD \
        signature or an UNTRUSTED signer — in that case say plainly it shouldn't be opened. A valid \
        signature from a trusted signer is safe to open. Encryption is a SEPARATE concern about \
        confidentiality (who could read the contents in transit) — whether or not the container is \
        encrypted is NOT a reason to open or avoid opening it, so never frame "not encrypted" as unsafe. \
        Reply in the user's language.
        """
        var lines: [String] = [signatureFacts(signature.verify), "Signer (shown): \(signature.signerDisplay)"]
        if !signature.signedAt.isEmpty { lines.append("Signed at: \(signature.signedAt)") }
        lines.append("Format: .\(SIZArchive.extensionName) v\(signature.schemaVersion)")
        if let encryption = signature.encryption {
            lines.append("Container is encrypted for confidentiality (recipients: \(encryption.recipients.count), symmetric passphrase: \(encryption.hasSymmetricPassphrase ?? false)). (Encryption affects who can read it, not whether it's safe to open.)")
        } else {
            lines.append("Container is not separately encrypted — its contents are readable by anyone who has the file. This is normal and is NOT a safety problem for opening it.")
        }
        if let note = signature.deliveryInstructions, !note.isEmpty { lines.append("Recipient note: \(note)") }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// #53:可复现构建报告 → 白话解释(两次打包是否字节一致 + 哪些因素可能破坏可复现)。
    static func reproducibilityExplanationPrompt(for report: ReproducibilityReport) -> (instructions: String, prompt: String) {
        let instructions = """
        You explain a reproducible-build check to a non-expert: whether packing the same folder twice \
        produced byte-for-byte identical archives, and which factors (timestamps, entry order, permissions, \
        owner/group, extended attributes) are normalized vs. stored as-is and could make builds differ. Be \
        concrete about which stored-as-is factors are the likely cause when the two builds differ. Reply in \
        the user's language.
        """
        var lines: [String] = ["Format: \(report.formatRawValue)", "Reproducible mode enabled: \(report.reproducibleEnabled)"]
        if let identical = report.identical { lines.append("Two builds byte-for-byte identical: \(identical)") }
        if let first = report.firstSHA256, let second = report.secondSHA256 {
            lines.append("First build SHA-256: \(first)")
            lines.append("Second build SHA-256: \(second)")
        }
        lines.append("Factors:")
        for factor in report.factors { lines.append("- \(factor.factor): \(factor.status)") }
        if !report.nonReproducibleFactors.isEmpty {
            lines.append("Factors stored as-is (may break reproducibility): \(report.nonReproducibleFactors.map { "\($0)" }.joined(separator: ", "))")
        }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// #67:归档元数据 → 「这是什么包」白话判断。只描述、不放行。
    static func metadataExplanationPrompt(for report: ArchiveMetadataReport) -> (instructions: String, prompt: String) {
        let instructions = """
        You are an archive-triage assistant. From the metadata below, explain in plain language what kind \
        of archive this most likely is and what stands out (format, compression method, solid or split, \
        encryption, macOS metadata traces, permission patterns). Base everything ONLY on the facts given; \
        this is a description, not a security verdict. Reply in the user's language.
        """
        var lines: [String] = ["Archive: \(report.archiveName)"]
        if let p = report.properties {
            var props: [String] = []
            if let type = p.type { props.append("type \(type)") }
            if let method = p.method { props.append("method \(method)") }
            if let solid = p.solid { props.append("solid \(solid)") }
            if let volumes = p.volumes { props.append("volumes \(volumes)") }
            if let phys = p.physicalSizeBytes { props.append("physical size \(phys) bytes") }
            if !props.isEmpty { lines.append("Header: \(props.joined(separator: ", "))") }
        }
        let agg = report.aggregate
        lines.append("Entries: \(agg.fileCount) files, \(agg.folderCount) folders. Encrypted entries: \(agg.encryptedCount). AppleDouble/__MACOSX traces: \(agg.appleDoubleCount).")
        if !agg.methodDistribution.isEmpty {
            lines.append("Compression methods: \(agg.methodDistribution.prefix(6).map { "\($0.method)×\($0.count)" }.joined(separator: ", "))")
        }
        if !agg.topAttributes.isEmpty {
            lines.append("Top permission/attribute strings: \(agg.topAttributes.prefix(6).map { "\($0.method)×\($0.count)" }.joined(separator: ", "))")
        }
        if !report.headerComment.isEmpty { lines.append("Header comment: \(report.headerComment)") }
        if report.securityFindingCount > 0 { lines.append("Suspicious-path findings: \(report.securityFindingCount)") }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// 空间分析 → 白话解释(什么占体积 / 压缩率 / 垃圾占比),给最大文件·目录·扩展名真实样本。
    static func spaceAnalysisExplanationPrompt(for report: ArchiveSpaceAnalysisReport) -> (instructions: String, prompt: String) {
        let instructions = """
        You explain an archive's disk-usage breakdown to a non-expert: what is taking the most space, how \
        well it compressed, and whether there's notable wasted space (macOS junk). Name the actual largest \
        files / folders / extensions. Reply in the user's language.
        """
        let a = report.analysis
        var lines: [String] = [
            "Archive: \(report.archiveName)",
            "Files: \(a.fileCount). Original total: \(a.totalBytes) bytes, packed: \(a.packedBytes) bytes."
        ]
        if let ratio = a.compressionRatio { lines.append("Compression ratio (packed/original): \(String(format: "%.2f", ratio))") }
        if a.junkCount > 0 { lines.append("macOS junk: \(a.junkCount) entries, \(a.junkBytes) bytes.") }
        if a.encryptedCount > 0 { lines.append("Encrypted entries: \(a.encryptedCount), \(a.encryptedBytes) bytes.") }
        if !a.largestFiles.isEmpty {
            lines.append("Largest files (of \(a.fileCount) total): \(a.largestFiles.prefix(10).map { "\($0.name) (\($0.bytes)B)" }.joined(separator: ", "))")
        }
        if !a.topLevelDirectories.isEmpty {
            lines.append("Top-level folders by size: \(a.topLevelDirectories.prefix(6).map { "\($0.name.isEmpty ? "(root)" : $0.name) (\($0.bytes)B)" }.joined(separator: ", "))")
        }
        if !a.extensions.isEmpty {
            lines.append("Biggest extensions: \(a.extensions.prefix(6).map { "\($0.name.isEmpty ? "(none)" : $0.name) (\($0.bytes)B)" }.joined(separator: ", "))")
        }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// #66:数据救援结果 → 白话解释(救出多少 / 哪些读不出);**绝不暗示归档已修好**。
    static func salvageExplanationPrompt(for report: ArchiveSalvageReport) -> (instructions: String, prompt: String) {
        let instructions = """
        You explain a best-effort data-rescue result for a damaged archive to a non-expert: how many files \
        were recovered, which entries couldn't be read and why, and the important caveat that rescued files \
        may be incomplete and the archive itself was NOT repaired. Name the failed entries. Never imply the \
        archive is now fixed. Reply in the user's language.
        """
        let o = report.outcome
        var lines: [String] = ["Archive: \(report.archiveName)"]
        if let total = report.totalEntryCount {
            lines.append("Recovered \(o.rescuedFileCount) of \(total) entries.")
        } else {
            lines.append("Recovered \(o.rescuedFileCount) files.")
        }
        if let errs = o.reportedErrorCount { lines.append("Backend reported \(errs) sub-item errors.") }
        if !o.failedEntryPaths.isEmpty {
            lines.append("Entries that could not be read (examples):")
            o.failedEntryPaths.prefix(8).forEach { lines.append("- \($0)") }
        }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// #68:敏感/配置/脚本/许可证文件扫描结果 → 白话解释。**只在确定性结果上解释**(扫描是按文件名归类、
    /// 非内容检查),所以说「看起来像」而非断言;机密类温和提醒别随意外传,绝不让删文件。
    static func sensitiveFilesExplanationPrompt(for report: SensitiveFileReport) -> (instructions: String, prompt: String) {
        let instructions = """
        You explain to a non-expert what notable files an archive contains, grouped as: likely private keys / \
        credentials / secrets, license & copyright files, configuration, and scripts. Say what each present \
        category is, and for the secrets/keys group gently note those may be sensitive and shouldn't be shared \
        casually. This is NAME-based pattern matching, not content inspection, so say "looks like" rather than \
        asserting, and name real example files. Never tell the user to delete anything. Reply in the user's language.
        """
        var lines: [String] = ["Archive: \(report.archiveName)", "Files scanned: \(report.result.scannedFileCount)"]
        if report.result.isEmpty {
            lines.append("No license, configuration, script, or secret-looking files were matched by name.")
        } else {
            for group in report.result.groups {
                lines.append("\(group.category.rawValue) (\(group.paths.count)): \(sampleEntries(group.paths, perKind: 6))")
            }
        }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// #69:近似重复文件分组 → 白话解释(哪些是同一份的不同版本 vs 纯改名同源,值不值得清理)。
    /// 只在确定性分组结果上解释(分组靠归一化文件名,非内容比对),说「看起来是」而非断言,绝不让删。
    static func nearDuplicateExplanationPrompt(for report: NearDuplicateReport) -> (instructions: String, prompt: String) {
        let instructions = """
        You explain near-duplicate file groups in an archive to a non-expert: which look like different \
        versions or copies of the same item, and which are byte-identical renames. Note this is based on \
        FILE NAMES (and whether their checksums match), not on comparing contents, so say "looks like". \
        Point out groups worth a closer look (e.g. several near-identical copies). Never tell the user to \
        delete anything. Reply in the user's language.
        """
        var lines: [String] = ["Archive: \(report.archiveName)", "Files scanned: \(report.result.scannedFileCount)"]
        if report.result.isEmpty {
            lines.append("No near-duplicate groups found by name.")
        } else {
            for group in report.result.groups.prefix(20) {
                let kind = group.hasByteIdentical ? "includes byte-identical copies" : "similar versions"
                lines.append("\"\(group.displayName)\" (\(group.entries.count), \(kind)): \(sampleEntries(group.entries.map { $0.path }, perKind: 5))")
            }
        }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// 发布目录完整性检查 → 白话解释(哪些项过 / 警告 / 失败 + 具体受影响文件)。
    static func directoryAuditExplanationPrompt(for report: ReleaseDirectoryAuditReport) -> (instructions: String, prompt: String) {
        let instructions = """
        You explain a release-directory integrity check to a non-expert: whether the folder forms a \
        complete, verifiable release, and what each warning or failure means and which files it affects. \
        Be specific. Don't tell the user to publish anyway if checks failed. Reply in the user's language.
        """
        var lines: [String] = ["Directory: \(report.directoryURL.lastPathComponent)", "Worst severity: \(report.worstSeverity)"]
        for finding in report.findings {
            var part = "\(finding.severity): \(finding.message)"
            if !finding.detailItems.isEmpty { part += " — \(finding.detailItems.prefix(5).joined(separator: ", "))" }
            lines.append("- \(part)")
        }
        return (instructions, lines.joined(separator: "\n"))
    }

    // MARK: - 生成器批(AI 起草发布文档,产出落进可编辑 sheet 由用户审阅后自取)

    /// #55:从发布目录检查结果 → 起草一份 `VERIFY.md`(告诉下载者怎么校验这次发布)+ 一节「缺失 / 建议」。
    /// 只根据目录**实际有什么**起草(findings 已编码 SHA256SUMS 是否齐、公钥能否验签、孤儿文件等);
    /// **绝不**让用户跳过校验或执行破坏性命令。产出是草稿,用户审阅后自行放进发布。
    static func verifyDraftPrompt(for report: ReleaseDirectoryAuditReport) -> (instructions: String, prompt: String) {
        let instructions = """
        You are a release-engineering assistant for the SimpleZip archive manager. Draft the contents of a \
        VERIFY.md file that tells someone who downloaded this release how to verify it, based ONLY on what \
        the directory actually contains. Where checksums or a signature are present, include the concrete \
        shell commands (e.g. `shasum -a 256 -c SHA256SUMS`, `gpg --import <key>.asc` then `gpg --verify`). \
        Then add a short "Missing / recommended" section noting any verification material that is absent \
        (no checksums file, no signature container, no public key) and suggest adding it. Use Markdown. \
        Write the file content directly — do not restate this instruction, do not ask questions, do not \
        invent files that aren't listed. Never instruct destructive actions or tell anyone to skip verification.
        """
        var lines: [String] = ["Release directory: \(report.directoryURL.lastPathComponent)"]
        lines.append("Audit findings (severity: message — affected files):")
        for finding in report.findings {
            var part = "- \(finding.severity): \(finding.message)"
            if !finding.detailItems.isEmpty {
                part += " — \(finding.detailItems.prefix(8).joined(separator: ", "))"
            }
            lines.append(part)
        }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// #56:发布检查报告 → 起草一段 GitHub Release 正文(下载文件名 / SHA-256 / 校验步骤 / 系统要求 /
    /// 可复现 / 签名说明)。GPG 段仅在确实签了 + 公钥在场时出现(传入参数已三道闸过滤)。只起草,不放行。
    static func releaseBodyPrompt(
        for report: ReleaseInspectionReport,
        versionLabel: String?,
        signedContainerName: String?,
        publicKeyFileName: String?,
        reproducible: Bool?,
        wroteChecksums: Bool
    ) -> (instructions: String, prompt: String) {
        let instructions = """
        You are a release-engineering assistant. Draft the body of a GitHub Release announcement for this \
        artifact in Markdown: a short intro line, a "Downloads" mention of the file, a "Verify" section with \
        the SHA-256 and the concrete check command when a checksums file was written, GPG signature \
        verification steps ONLY if a signature container and public key are provided below, and a one-line \
        system-requirements note (macOS). Keep it concise and factual. Write the body directly — do not \
        restate this instruction, do not ask questions, do not invent download URLs, version numbers, or \
        changelog entries that aren't given. Never instruct destructive actions.
        """
        var lines: [String] = ["Artifact file: \(report.archiveURL.lastPathComponent)"]
        if let versionLabel, !versionLabel.isEmpty { lines.append("Version label: \(versionLabel)") }
        if let stats = report.stats {
            lines.append("Contents: \(stats.fileCount) files, \(stats.folderCount) folders, \(ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file)).")
        }
        if let passed = report.testPassed { lines.append("Integrity test passed: \(passed).") }
        if let failure = report.testFailureMessage, !failure.isEmpty {
            lines.append("Integrity test failure: \(failure).")
        }
        if let sha256 = report.sha256 { lines.append("SHA-256: \(sha256)") }
        if let fingerprint = report.structuralFingerprint {
            lines.append("Structural fingerprint (entry-structure hash, stable across re-packs): \(fingerprint).")
        }
        lines.append("SHA256SUMS checksum file written: \(wroteChecksums).")
        if let reproducible { lines.append("Reproducible build: \(reproducible).") }
        if let signedContainerName, let publicKeyFileName {
            lines.append("Signed container present: \(signedContainerName); public key file: \(publicKeyFileName).")
        } else {
            lines.append("No GPG signature container / public key alongside this artifact — omit the signature section.")
        }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// #70:据用户实际使用习惯(操作 / 触发来源计数)→ 起草 1–2 个 Shortcuts / 自动化点子(草稿,用户自建)。
    /// 只产草稿、不自动建不执行;喂的是非加密的聚合用法计数(无文件名 / 无内容)。
    static func automationSuggestionPrompt(usageSummary: String) -> (instructions: String, prompt: String) {
        let instructions = """
        You suggest one or two Shortcuts / automation ideas for a macOS archive app, tailored to how the \
        user actually uses it (their recent operation and trigger counts are below). For each idea give a \
        short title and 3–5 plain setup steps a person could follow in the Shortcuts app, using the app's \
        available actions (Create Archive, Extract, Verify Checksums, Compare Archives, Create Release \
        Package, Search Archive Contents, Inspect Archive). Base the ideas on the actual usage; if usage is \
        thin, suggest a generally useful starter automation. This is a DRAFT for the user to build \
        themselves — never claim to create, install, or run anything. Reply in the user's language.
        """
        return (instructions, "Recent usage:\n\(usageSummary)")
    }

    /// #59:GitHub Issue 智能归类 —— 在润色之外,额外建议 issue 类型标签 + 标题。喂已脱敏的 issue 原文。
    /// 只建议分类,不替用户提交、不改内容判定。
    static func issueCategorizePrompt(rawIssue: String) -> (instructions: String, prompt: String) {
        let instructions = """
        You are a developer-triage assistant for the SimpleZip archive manager. Read the auto-generated \
        GitHub issue below (already redacted) and produce, in this exact order: (1) a one-line suggested \
        issue title; (2) a "Suggested labels:" line with a few short labels chosen from a typical set \
        (bug, crash, regression, performance, ui, archive-format, gpg, extraction, compression, cli, \
        shortcuts, enhancement, needs-info); (3) a one-paragraph plain-language summary of what seems to be \
        going on. Base everything ONLY on the facts in the issue — never invent details, keep every \
        "[REDACTED]" marker untouched, and these are suggestions, not a verdict. Write the result directly. \
        Reply in the user's language.
        """
        return (instructions, rawIssue)
    }

    /// #65:发布产物「本次 vs 上次」账面对比 → 白话总结(体积 / 文件数 / 指纹 / junk 回潮 / 卫生倒退)。
    /// 只描述账面差异、点出值得留意的倒退(junk 回潮、指纹意外变化、签名 / 校验文件丢失),不替用户判断该不该发。
    static func releaseCompareSummaryPrompt(
        old: ReleaseLedgerEntry,
        new: ReleaseLedgerEntry,
        comparison: ReleaseLedgerComparison
    ) -> (instructions: String, prompt: String) {
        let instructions = """
        You explain how a new release compares to the previous one, in plain language for the person \
        publishing it. Summarize the meaningful differences (size, file count, whether the structural \
        fingerprint changed, hygiene), and clearly flag any regression worth a second look — junk files \
        reappearing, the fingerprint changing unexpectedly, or checksums/signing that were done last time \
        but not this time. Base everything ONLY on the facts given; this is a description, not a go/no-go \
        verdict — never tell the user to publish or not. Write the summary directly — do not restate this \
        instruction or ask questions. Reply in the user's language.
        """
        var lines: [String] = [
            "Previous release: \(old.versionLabel) (\(old.date.formatted(date: .abbreviated, time: .shortened)))",
            "New release: \(new.versionLabel) (\(new.date.formatted(date: .abbreviated, time: .shortened)))",
            "Format: \(old.formatRawValue) → \(new.formatRawValue)"
        ]
        if let oldBytes = old.totalBytes, let newBytes = new.totalBytes, let delta = comparison.totalBytesDelta {
            lines.append("Size: \(oldBytes) → \(newBytes) bytes (delta \(delta >= 0 ? "+" : "")\(delta)).")
        }
        if let oldCount = old.fileCount, let newCount = new.fileCount, let delta = comparison.fileCountDelta {
            lines.append("File count: \(oldCount) → \(newCount) (delta \(delta >= 0 ? "+" : "")\(delta)).")
        }
        if let changed = comparison.fingerprintChanged {
            lines.append("Structural fingerprint changed: \(changed) (false = same packed content, repackaged or not).")
        } else {
            lines.append("Structural fingerprint: not comparable (one side has none).")
        }
        if comparison.junkRegression {
            lines.append("JUNK REGRESSION: previous release had no macOS junk, this one has \(new.junkCount ?? 0).")
        }
        lines.append("Hygiene — reproducible: \(old.reproducible) → \(new.reproducible); SHA256SUMS written: \(old.wroteChecksums) → \(new.wroteChecksums); signed as .szs requested: \(old.signRequested) → \(new.signRequested); exclude-junk on: \(old.excludeJunk) → \(new.excludeJunk).")
        if let oldSus = old.suspiciousPathCount, let newSus = new.suspiciousPathCount {
            lines.append("Suspicious entry paths: \(oldSus) → \(newSus).")
        }
        if let oldEmpty = old.emptyDirectoryCount, let newEmpty = new.emptyDirectoryCount {
            lines.append("Empty directories: \(oldEmpty) → \(newEmpty).")
        }
        if let oldTest = old.testPassed, let newTest = new.testPassed {
            lines.append("Integrity test passed: \(oldTest) → \(newTest).")
        }
        if old.appVersion != new.appVersion {
            lines.append("Built by app version: \(old.appVersion) → \(new.appVersion).")
        }
        return (instructions, lines.joined(separator: "\n"))
    }

    // MARK: - 内联自动速览(创建 / 解压窗口打开即静默跑,动态)

    /// 创建对话框 → 速览:预估耗时(定性)+ 一条实用建议(格式 / 级别 / 没问题)+ 冲突提醒。只建议不替用户改。
    /// `inputItems` = 顶层被打包项的真实样本(名字 + 文件夹/大小),让 AI 能针对**具体内容**给建议
    /// (如已压缩媒体压不动、文件夹进单文件格式会先打 tar)而非空泛套话。隐私:非加密文件名,可喂。
    static func createAdvisoryPrompt(
        dryRun: ArchiveService.ArchiveCreationDryRun,
        estimatedCompressedBytes: Int64?,
        format: String,
        compressionLevel: String,
        outputExists: Bool,
        inputItems: [String]
    ) -> (instructions: String, prompt: String) {
        let instructions = """
        Write a short, plain note (one sentence, two at most) about creating this archive, based STRICTLY on \
        the facts below. NEVER invent, estimate, or state a size, a duration, or any number — the dialog \
        already shows the real figures; you only add a qualitative remark. You may say qualitatively whether \
        it should be quick or take a while, but only as judged from the size already given, never a fabricated \
        one. Add at most one useful remark when the facts clearly support it (for example a folder is going \
        into a single-file format, or a same-named output already exists). Do NOT guess file types you can't \
        see, and do NOT list file formats. If nothing stands out, say the settings look fine. Write the note \
        directly — no preamble, no questions, no recap. Suggest, never change settings.
        """
        var lines: [String] = [
            "Packing \(dryRun.inputFileCount) file(s), \(ByteCountFormatter.string(fromByteCount: dryRun.totalBytes, countStyle: .file)) uncompressed.",
            "Chosen format: \(format); compression level: \(compressionLevel)."
        ]
        if !inputItems.isEmpty {
            lines.append("Top-level items being packed: \(sampleEntries(inputItems, perKind: 12)).")
        }
        if let estimate = estimatedCompressedBytes, dryRun.totalBytes > 0 {
            let pct = Int((Double(estimate) / Double(dryRun.totalBytes) * 100).rounded())
            lines.append("Estimated compressed size: \(ByteCountFormatter.string(fromByteCount: estimate, countStyle: .file)) (~\(pct)% of original).")
        }
        if dryRun.excludedCount > 0 { lines.append("Excluded by rules: \(dryRun.excludedCount).") }
        if dryRun.symlinkCount > 0 { lines.append("Symlinks: \(dryRun.symlinkCount).") }
        if dryRun.packageCount > 0 { lines.append("macOS packages/bundles: \(dryRun.packageCount).") }
        if let volumes = dryRun.estimatedVolumeCount { lines.append("Will split into about \(volumes) volumes.") }
        if outputExists { lines.append("An output file with this name already exists.") }
        return (instructions, lines.joined(separator: "\n"))
    }

    /// 解压对话框 → 速览:定性大小/耗时 + 解压前值得知道的事(可疑路径 / 覆盖 / 缺卷 / 空间不足)。绝不让跳过安全询问。
    /// `topLevelEntries` = 归档顶层条目真实名字样本,`suspiciousSamples` = 可疑路径真实样本 —— 让 AI 能说出
    /// 「解出来会是什么 / 哪条路径可疑」而非只报数字。隐私:非加密清单条目名,可喂(头加密归档根本列不出名)。
    static func extractAdvisoryPrompt(
        preflight: ArchiveExtractPreflight,
        overwriteCount: Int,
        missingVolumeCount: Int,
        lowSpaceNeeded: String?,
        lowSpaceAvailable: String?,
        destinationName: String,
        topLevelEntries: [String],
        suspiciousSamples: [String]
    ) -> (instructions: String, prompt: String) {
        let instructions = """
        Write a short, plain note (one sentence, two at most) about extracting this archive, based STRICTLY \
        on the facts below. NEVER invent, estimate, or state a size, a duration, or any number — the dialog \
        already shows the real figures; you only add a qualitative remark. Grounded in the ACTUAL entries \
        listed, you may say what it will unpack into (a single top folder, or loose items scattered into the \
        destination). If the facts show suspicious paths that could write outside the destination, files that \
        would be overwritten, missing volumes, or low disk space, point out that specific concern and name \
        the suspicious entry when given. If none of those appear, say it looks straightforward. Write the \
        note directly — no preamble, no questions, no recap. Never tell the user to skip a safety prompt.
        """
        var lines: [String] = [
            "Will extract \(preflight.fileCount) file(s), \(preflight.folderCount) folder(s), \(ByteCountFormatter.string(fromByteCount: preflight.totalBytes, countStyle: .file)) into \"\(destinationName)\"."
        ]
        if !topLevelEntries.isEmpty {
            lines.append("Top-level entries: \(sampleEntries(topLevelEntries, perKind: 12)).")
        }
        if preflight.encryptedEntryCount > 0 { lines.append("Encrypted entries: \(preflight.encryptedEntryCount).") }
        if preflight.suspiciousEntryCount > 0 {
            var line = "Suspicious paths (could escape the destination folder): \(preflight.suspiciousEntryCount)."
            if !suspiciousSamples.isEmpty { line += " Examples: \(sampleEntries(suspiciousSamples, perKind: 5))." }
            lines.append(line)
        }
        if preflight.symlinkCount > 0 { lines.append("Symlinks: \(preflight.symlinkCount).") }
        if overwriteCount > 0 { lines.append("Would overwrite \(overwriteCount) existing file(s).") }
        if missingVolumeCount > 0 { lines.append("Missing split volumes: \(missingVolumeCount).") }
        if let needed = lowSpaceNeeded, let available = lowSpaceAvailable {
            lines.append("Low disk space: needs \(needed), only \(available) available.")
        }
        return (instructions, lines.joined(separator: "\n"))
    }
}

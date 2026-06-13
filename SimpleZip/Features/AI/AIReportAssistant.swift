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
    @available(macOS 26.0, *)
    static func generate(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions + "\n\n" + replyLanguageInstruction)
        return try await session.respond(to: prompt).content
    }

    /// 「整段回复用 <当前界面语言>」—— 按 app 语言覆盖优先,否则取实际加载的本地化。
    nonisolated static var replyLanguageInstruction: String {
        let code: String
        let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        if let language = AppLanguage(rawValue: raw), let explicit = language.localizationCode {
            code = explicit
        } else {
            code = Bundle.main.preferredLocalizations.first ?? "en"
        }
        let name: String
        if code.hasPrefix("zh-Hant") || code.hasPrefix("zh-HK") || code.hasPrefix("zh-TW") {
            name = "Traditional Chinese"
        } else if code.hasPrefix("zh") {
            name = "Simplified Chinese"
        } else if code.hasPrefix("ja") {
            name = "Japanese"
        } else if code.hasPrefix("ko") {
            name = "Korean"
        } else if code.hasPrefix("de") {
            name = "German"
        } else if code.hasPrefix("es") {
            name = "Spanish"
        } else if code.hasPrefix("fr") {
            name = "French"
        } else if code.hasPrefix("ru") {
            name = "Russian"
        } else if code.hasPrefix("th") {
            name = "Thai"
        } else {
            name = "English"
        }
        return "Write your entire reply in \(name). Do not restate these instructions; reply only with the note itself."
    }
}

/// AI 入口在不可用时被点到的兜底错误(理论上 isReady 已挡住,防御性留一个)。
struct AIAssistError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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
            case .failed: parts.append("integrity test failed")
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
            lines.append("Container is encrypted for confidentiality (recipients: \(encryption.recipients.count), symmetric passphrase: \(encryption.hasSymmetricPassphrase)). (Encryption affects who can read it, not whether it's safe to open.)")
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
        if a.encryptedCount > 0 { lines.append("Encrypted entries: \(a.encryptedCount).") }
        if !a.largestFiles.isEmpty {
            lines.append("Largest files: \(a.largestFiles.prefix(6).map { "\($0.name) (\($0.bytes)B)" }.joined(separator: ", "))")
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
        if let sha256 = report.sha256 { lines.append("SHA-256: \(sha256)") }
        lines.append("SHA256SUMS checksum file written: \(wroteChecksums).")
        if let reproducible { lines.append("Reproducible build: \(reproducible).") }
        if let signedContainerName, let publicKeyFileName {
            lines.append("Signed container present: \(signedContainerName); public key file: \(publicKeyFileName).")
        } else {
            lines.append("No GPG signature container / public key alongside this artifact — omit the signature section.")
        }
        return (instructions, lines.joined(separator: "\n"))
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

    // MARK: - 内联自动速览(创建 / 解压窗口打开即静默跑,动态)

    /// 创建对话框 → 速览:预估耗时(定性)+ 一条实用建议(格式 / 级别 / 没问题)+ 冲突提醒。只建议不替用户改。
    static func createAdvisoryPrompt(
        dryRun: ArchiveService.ArchiveCreationDryRun,
        estimatedCompressedBytes: Int64?,
        format: String,
        compressionLevel: String,
        outputExists: Bool
    ) -> (instructions: String, prompt: String) {
        let instructions = """
        Write a 1–2 sentence plain-language note about creating this archive. Give a rough sense of how long \
        it should take from the data size (quick / a while — never invent exact seconds), and add ONE concrete \
        useful remark if warranted: that the chosen format and level suit this content, or a brief better \
        alternative, or that a same-named file already exists so a conflict prompt will appear; otherwise just \
        say the settings look fine. Write the note itself directly — do not restate this instruction, do not \
        ask the user questions, do not list what you checked. Suggest, never change settings yourself.
        """
        var lines: [String] = [
            "Packing \(dryRun.inputFileCount) file(s), \(ByteCountFormatter.string(fromByteCount: dryRun.totalBytes, countStyle: .file)) uncompressed.",
            "Chosen format: \(format); compression level: \(compressionLevel)."
        ]
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
    static func extractAdvisoryPrompt(
        preflight: ArchiveExtractPreflight,
        overwriteCount: Int,
        missingVolumeCount: Int,
        lowSpaceNeeded: String?,
        lowSpaceAvailable: String?,
        destinationName: String
    ) -> (instructions: String, prompt: String) {
        let instructions = """
        Write a 1–2 sentence plain-language note about extracting this archive. State its rough size and \
        whether it should be quick. If the facts below show suspicious paths that could write outside the \
        destination, files that would be overwritten, missing volumes, or low disk space, point out that \
        specific concern. If none of those appear, simply say it looks straightforward to extract. Write the \
        note itself directly — do not restate this instruction, do not ask the user questions, do not list \
        what you checked. Never tell the user to skip a safety prompt.
        """
        var lines: [String] = [
            "Will extract \(preflight.fileCount) file(s), \(preflight.folderCount) folder(s), \(ByteCountFormatter.string(fromByteCount: preflight.totalBytes, countStyle: .file)) into \"\(destinationName)\"."
        ]
        if preflight.encryptedEntryCount > 0 { lines.append("Encrypted entries: \(preflight.encryptedEntryCount).") }
        if preflight.suspiciousEntryCount > 0 { lines.append("Suspicious paths (could escape the destination folder): \(preflight.suspiciousEntryCount).") }
        if preflight.symlinkCount > 0 { lines.append("Symlinks: \(preflight.symlinkCount).") }
        if overwriteCount > 0 { lines.append("Would overwrite \(overwriteCount) existing file(s).") }
        if missingVolumeCount > 0 { lines.append("Missing split volumes: \(missingVolumeCount).") }
        if let needed = lowSpaceNeeded, let available = lowSpaceAvailable {
            lines.append("Low disk space: needs \(needed), only \(available) available.")
        }
        return (instructions, lines.joined(separator: "\n"))
    }
}

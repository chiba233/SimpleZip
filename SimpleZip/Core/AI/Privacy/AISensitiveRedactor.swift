//
//  AISensitiveRedactor.swift
//  SimpleZip
//
//  0.4.5 #80:进入 AI 上下文前的**确定性脱敏 + 信号抽取**。统一 AI 数据层的红线执行点。
//
//  后端正常运行不会把口令塞 argv(7zz/rar 走 stdin),但「喂给 AI」要按防御性纵深处理:任何看起来像
//  口令 / passphrase / token / 私钥块的串,在进 prompt / 缓存 / 索引 / 日志解释前一律抹成 [REDACTED]。
//  argv 形态(`-p<...>` / `-hp<...>`)复用 OperationDiagnosticsReporter.sanitize 的**单一实现**(不重造,
//  见 A2),这里只补它没覆盖的 `password=` / `--passphrase X` / `Authorization: Bearer` / PEM 私钥块。
//
//  另外两个抽取器把「整段后端日志」收成 AI 友好信号:errorLines(只给像错误的行)+ logTail(脱敏的短尾部)。
//  纯字符串处理,无 IO,SwiftPM 可精确断言。
//

import Foundation

nonisolated enum AISensitiveRedactor {
    static let placeholder = "[REDACTED]"

    /// 脱敏一段将进入 AI 上下文的文本。先过 argv 口令规则(复用现成 sanitize),再补常见 secret 形态。
    /// 宁可过度脱敏(安全侧)也不漏 —— 误伤一段非密文本无害,漏一个口令是红线事故。
    static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        // 先抹键值 / 空格分隔值 / PEM 块,**再**过 argv sanitize —— 顺序很关键:sanitize 的 `-p` 规则会
        // 把 `--passphrase value` 误吃成 `--p[REDACTED] value`(只抹掉选项名、漏掉真正的值),所以必须先
        // 让空格分隔规则把 `value` 抹掉,sanitize 再跑就只是对选项名锦上添花的过度脱敏(安全侧,无害)。
        var out = text
        for rule in extraRules { out = rule.apply(to: out) }
        out = OperationDiagnosticsReporter.sanitize(out)   // -p<...> / -hp<...>
        return out
    }

    /// 从后端输出里抽出「像错误」的行 —— 给 AI 抓重点比塞整段日志更稳、更省 token。
    /// 每行 trim + 脱敏 + 去重,封顶 `maxLines`。空输入返回空数组。
    static func errorLines(from output: String, maxLines: Int = 12) -> [String] {
        guard !output.isEmpty, maxLines > 0 else { return [] }
        var result: [String] = []
        var seen = Set<String>()
        for rawLine in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            guard Self.errorMarkers.contains(where: { lower.contains($0) }) else { continue }
            let redacted = redact(line)
            guard seen.insert(redacted).inserted else { continue }
            result.append(redacted)
            if result.count >= maxLines { break }
        }
        return result
    }

    /// 取末尾不超过 `maxChars` 个字符的日志尾部。**默认先截尾再脱敏** —— 避免对几 MB 的完整日志跑正则
    /// (审计:logTail 原来对整段日志跑 redact 再截,大日志会很慢)。多留一倍余量(脱敏可能改变长度)。
    ///
    /// **私钥块红线(白皮书工程补充一·边界四)**:先截尾会把超长私钥块从中段切断,丢掉 `-----BEGIN` marker,
    /// 导致 PEM 正则匹配不到、尾部密钥 base64 中段泄漏。所以截尾前先做轻量 sentinel 扫描:原文一旦含私钥块 armor
    /// (`-----BEGIN … PRIVATE KEY` / `BEGIN OPENSSH PRIVATE KEY`),改对**完整原文**脱敏(整块 BEGIN…END 被抹)
    /// 再截尾;若脱敏后仍残留 armor(块不完整、无法整块匹配),直接返回固定占位,绝不输出尾部。普通日志(无私钥
    /// 块,绝大多数)仍走快速路径。
    static func logTail(of output: String, maxChars: Int = 800) -> String {
        if containsRawPrivateKeyArmor(output) {
            let fullyRedacted = redact(output)
            // 残块:有 BEGIN 无 END,非贪婪 PEM 正则匹配不到 → 整体扣留,绝不冒险输出尾部。
            if containsRawPrivateKeyArmor(fullyRedacted) {
                return "…(output withheld: contained private key material)"
            }
            guard fullyRedacted.count > maxChars else { return fullyRedacted }
            return "…(earlier output truncated)\n" + String(fullyRedacted.suffix(maxChars))
        }
        let rawTail = output.count > maxChars * 2 ? String(output.suffix(maxChars * 2)) : output
        let redacted = redact(rawTail)
        guard redacted.count > maxChars else { return redacted }
        return "…(earlier output truncated)\n" + String(redacted.suffix(maxChars))
    }

    /// 原文是否含私钥块 armor(脱敏占位 `[REDACTED PRIVATE KEY]` 不含 `-----BEGIN`,故可据此判断块是否已被抹掉)。
    private static func containsRawPrivateKeyArmor(_ text: String) -> Bool {
        let upper = text.uppercased()
        return (upper.contains("-----BEGIN") && upper.contains("PRIVATE KEY"))
            || upper.contains("BEGIN OPENSSH PRIVATE KEY")
    }

    /// 只对**文件名 / 路径**应用 key=value 形态的 secret 脱敏 —— 抓 `password=123456.txt` 这类把口令塞进文件名
    /// 的情况(路线图补充八)。**不动** argv / PEM / 空格选项规则(对文件名无意义,且会过度切断正常名字)。
    /// 词边界 + 紧跟 `=`/`:` 才命中,正常名字(`my-password-notes.txt` / `passwords.txt`)不受影响。
    static func redactFileNameSecrets(_ name: String) -> String {
        guard !name.isEmpty else { return name }
        return keyValueSecretRule?.apply(to: name) ?? name
    }

    // MARK: - Private

    /// 触发「这是错误行」的小写标记。curated 以压低误报(不用裸 "crc" / "missing" 这种泛词)。
    private static let errorMarkers: [String] = [
        "error", "denied", "cannot", "can not", "can't open", "failed", "failure",
        "unsupported", "is not supported", "corrupt", "data error", "crc failed",
        "no space", "not enough space", "wrong password", "unavailable", "no such file",
        // 缺卷行常不含上面任何词(审计 #7:否则 missing-volume 标签可能丢失)。
        "missing volume", "cannot find volume", "no such volume"
    ]

    private struct RedactionRule {
        let regex: NSRegularExpression
        let template: String

        init?(_ pattern: String, _ template: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            self.regex = regex
            self.template = template
        }

        func apply(to text: String) -> String {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
    }

    /// key=value 形态 secret 规则。文件名脱敏 `redactFileNameSecrets` 也复用它。整段命中 → `[REDACTED]`。
    /// 审计加固:① 容忍下划线 / 连字符复合键(`client_secret=` / `secret_key=` / `AWS_SECRET_ACCESS_KEY=`)——
    /// 关键词可被 `subtoken_` 前缀和 `_subtoken` 后缀包夹(#2);② `:` 形态要求**冒号前无空格**(真 config /
    /// argv 是 `key:value`,自然语言诊断是 `password : data error`)—— 不再误吃诊断词 / 非加密条目名(#4)。
    private static let keyValueSecretRule = RedactionRule(
        #"(?i)(?<![a-z0-9])([a-z0-9]+[_-])*(password|passphrase|passwd|pwd|secret|token|api[_-]?key)([_-][a-z0-9]+)*(?:\s*=\s*|:)\s*\S+"#,
        "[REDACTED]")

    /// argv 之外的 secret 形态。顺序应用;坏 pattern(理论上不会)被 compactMap 跳过,不致命。
    private static let extraRules: [RedactionRule] = {
        var rules: [RedactionRule] = []
        // PEM 私钥块整体抹掉(多行)。
        if let pem = RedactionRule(
            #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#,
            "[REDACTED PRIVATE KEY]") {
            rules.append(pem)
        }
        // key: value / key=value 形态(password / passphrase / secret / token / api key …)。
        if let kv = keyValueSecretRule { rules.append(kv) }
        // 长短选项 + 空格分隔的值(--password X / -pass X)。
        if let opt = RedactionRule(#"(?i)(--?(?:password|passphrase|pwd|pass))\s+\S+"#, "$1 [REDACTED]") {
            rules.append(opt)
        }
        // HTTP bearer。
        if let bearer = RedactionRule(#"(?i)(authorization:\s*bearer)\s+\S+"#, "$1 [REDACTED]") {
            rules.append(bearer)
        }
        // 关键词 + 空格 + **像 token 的长值**(`bearer xY9…` / `denied: token abc123def456` —— 审计 #3
        // 空格分隔的 secret)。要求值 ≥12 个 token 字符,避免误伤 "token bucket" / "secret sauce" 这类普通词。
        if let spacedToken = RedactionRule(
            #"(?i)\b(password|passphrase|secret|token|api[_-]?key|bearer)\b\s+([A-Za-z0-9+/=._-]{12,})"#,
            "$1 [REDACTED]") {
            rules.append(spacedToken)
        }
        return rules
    }()
}

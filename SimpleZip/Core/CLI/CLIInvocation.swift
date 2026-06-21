//
//  CLIInvocation.swift
//  SimpleZip
//
//  CLI companion(`simplezip` 命令)的入口判定 + 参数解析 —— 纯函数,无副作用,SwiftPM 可测。
//  真正执行在 app target 的 CLIRunner(需要后端、AppKit 与活动中心)。
//

import Foundation

/// 0.4.4 A:全局输出旗标(任意位置可出现,先于子命令解析剥离)。
nonisolated struct CLIOutputOptions: Equatable {
    /// 每命令输出一个 JSON 结果对象到 stdout(人读输出让位;错误仍走 stderr)。
    var json = false
    /// 只输出错误与退出码。
    var quiet = false
    /// 透传后端原始输出(排查用)。
    var verbose = false
}

/// 0.4.4 A:create 的可选旗标。**密码绝不走 argv** —— `--encrypt` 只是开关,
/// 口令从 SIMPLEZIP_PASSWORD 环境变量或 tty 交互读(CLIRunner 负责)。
nonisolated struct CLICreateOptions: Equatable {
    /// 内置任务模板 slug(github-release / max-7z …)。
    var template: String?
    /// 压缩级别 0-9(覆盖默认值/模板)。
    var level: Int?
    var excludeJunk = false
    var reproducible = false
    var encrypt = false
}

enum CLIInvocation: Equatable {
    case help
    /// `help <command>`:单命令详细用法(0.4.4 A)。
    case helpCommand(String)
    case version
    /// 0.4.4 A:环境体检 —— app bundle / 7zz / RAR / GPG / 符号链接。
    case doctor
    case open(paths: [String])
    case check(paths: [String])
    case compare(left: String, right: String)
    /// 创建归档。`options.template` 与创建对话框「套用模板」同一目录(用户拍板的绑定对象);
    /// 无模板时自动套用该格式在 app 里保存的默认值(设置 → 压缩,与 Finder 一键压缩同口径),
    /// 其余旗标在其上覆盖。
    case create(output: String, inputs: [String], options: CLICreateOptions)
    /// 0.4.4 A:verify 支持多个校验文件(逐个验,末尾汇总)。
    case verify(paths: [String])

    /// 0.4.4 #48:打印指定 shell 的补全脚本到 stdout(zsh / bash / fish)。
    case completions(shell: CLICompletions.Shell)

    enum ParseError: Error, Equatable {
        case unknownCommand(String)
        case missingArguments(command: String)
        case unexpectedOption(String)
        case invalidValue(option: String, value: String)

        /// CLI 输出固定英文:进程经 PATH 符号链接运行时 Bundle.main 解析不到 app bundle
        /// (实测 bundlePath 落在符号链接所在目录),L10n 不可用;脚本/CI 也需要稳定输出。
        var message: String {
            switch self {
            case .unknownCommand(let command):
                // 0.4.4 A 智能纠错:打错一两个字母时按编辑距离指路。
                if let suggestion = CLIInvocation.nearestCommand(to: command) {
                    return "unknown command: \(command) (did you mean “\(suggestion)”?)"
                }
                return "unknown command: \(command)"
            case .missingArguments(let command):
                return "missing or wrong arguments for: \(command)"
            case .unexpectedOption(let option):
                return "unexpected option: \(option)"
            case .invalidValue(let option, let value):
                return "invalid value for \(option): \(value)"
            }
        }
    }

    /// 进程是否应进 CLI 模式:以 `simplezip` 之名被调用(PATH 里的符号链接),或显式 `--cli` 前缀
    /// (无符号链接时的直调测试口)。GUI 二进制名是大写 `SimpleZip`,比较区分大小写 ——
    /// Finder / LaunchServices 启动不会撞上。
    nonisolated static func isCLIInvocation(argv0: String, firstArgument: String?) -> Bool {
        if URL(fileURLWithPath: argv0).lastPathComponent == "simplezip" { return true }
        return firstArgument == "--cli"
    }

    nonisolated static let knownCommands = ["help", "version", "doctor", "open", "check", "compare", "create", "verify", "completions"]

    /// 0.4.4 A:剥离全局旗标(--json/--quiet/--verbose,任意位置)→ (剩余参数, 旗标)。
    nonisolated static func extractOutputOptions(from arguments: [String]) -> (rest: [String], options: CLIOutputOptions) {
        var options = CLIOutputOptions()
        var rest: [String] = []
        for argument in arguments {
            switch argument {
            case "--json": options.json = true
            case "--quiet", "-q": options.quiet = true
            case "--verbose": options.verbose = true
            default: rest.append(argument)
            }
        }
        return (rest, options)
    }

    /// 解析子命令与其参数(传入的数组**不含** argv0 与 `--cli` 前缀;全局旗标应已剥离)。
    nonisolated static func parse(_ arguments: [String]) throws -> CLIInvocation {
        guard let command = arguments.first else { return .help }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "help", "--help", "-h":
            if let topic = rest.first {
                guard knownCommands.contains(topic) else { throw ParseError.unknownCommand(topic) }
                return .helpCommand(topic)
            }
            return .help
        case "version", "--version", "-v":
            return .version
        case "doctor":
            try rejectOptions(in: rest)
            return .doctor
        case "open":
            try rejectOptions(in: rest)
            guard !rest.isEmpty else { throw ParseError.missingArguments(command: command) }
            return .open(paths: rest)
        case "check":
            try rejectOptions(in: rest)
            guard !rest.isEmpty else { throw ParseError.missingArguments(command: command) }
            return .check(paths: rest)
        case "compare":
            try rejectOptions(in: rest)
            guard rest.count == 2 else { throw ParseError.missingArguments(command: command) }
            return .compare(left: rest[0], right: rest[1])
        case "create":
            var options = CLICreateOptions()
            var positional: [String] = []
            var index = 0
            while index < rest.count {
                let argument = rest[index]
                switch argument {
                case "--template", "-t":
                    guard index + 1 < rest.count else { throw ParseError.missingArguments(command: command) }
                    options.template = rest[index + 1]
                    index += 2
                case "--level", "-l":
                    guard index + 1 < rest.count else { throw ParseError.missingArguments(command: command) }
                    guard let level = Int(rest[index + 1]), (0...9).contains(level) else {
                        throw ParseError.invalidValue(option: argument, value: rest[index + 1])
                    }
                    options.level = level
                    index += 2
                case "--exclude-junk":
                    options.excludeJunk = true
                    index += 1
                case "--reproducible":
                    options.reproducible = true
                    index += 1
                case "--encrypt":
                    options.encrypt = true
                    index += 1
                default:
                    if argument.hasPrefix("-") {
                        throw ParseError.unexpectedOption(argument)
                    }
                    positional.append(argument)
                    index += 1
                }
            }
            guard positional.count >= 2 else { throw ParseError.missingArguments(command: command) }
            return .create(output: positional[0], inputs: Array(positional.dropFirst()), options: options)
        case "verify":
            try rejectOptions(in: rest)
            guard !rest.isEmpty else { throw ParseError.missingArguments(command: command) }
            return .verify(paths: rest)
        case "completions":
            guard let shellArgument = rest.first else { throw ParseError.missingArguments(command: command) }
            guard let shell = CLICompletions.Shell(rawValue: shellArgument) else {
                throw ParseError.invalidValue(option: "completions", value: shellArgument)
            }
            return .completions(shell: shell)
        default:
            throw ParseError.unknownCommand(command)
        }
    }

    private nonisolated static func rejectOptions(in arguments: [String]) throws {
        if let option = arguments.first(where: { $0.hasPrefix("-") }) {
            throw ParseError.unexpectedOption(option)
        }
    }

    // MARK: - 智能纠错(0.4.4 A)

    /// 与已知命令的最小编辑距离 ≤2 时给建议(更远 = 不像笔误,不乱猜)。
    nonisolated static func nearestCommand(to unknown: String) -> String? {
        let candidate = knownCommands
            .map { (command: $0, distance: editDistance(unknown.lowercased(), $0)) }
            .min { $0.distance < $1.distance }
        guard let candidate, candidate.distance <= 2 else { return nil }
        return candidate.command
    }

    /// 经典 Levenshtein(两行滚动数组;命令都是短词,性能无虞)。
    nonisolated static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                let substitution = previous[j - 1] + (aChars[i - 1] == bChars[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }

    // MARK: - 用法文本

    nonisolated static let usage = """
    simplezip — SimpleZip command-line companion

    USAGE:
      simplezip open <file>...                   Open files or archives in the SimpleZip app
      simplezip check <archive>...               Test archive integrity (exit 1 on any failure)
      simplezip compare <left> <right>           Compare two archives (exit 1 when different)
      simplezip create <output> <input>... [options]
                                                 Create an archive; format from the output extension
      simplezip verify <checksum-file>...        Verify SHA256SUMS / checksums.txt / .sha256 / .md5 / .sfv
      simplezip doctor                           Check the CLI environment (app, backends, symlink)
      simplezip completions <zsh|bash|fish>      Print a shell completion script to stdout
      simplezip version                          Print version
      simplezip help [command]                   Show this help, or detailed help for one command

    GLOBAL OPTIONS:
      --json        Print one JSON result object per command on stdout
      --quiet, -q   Only errors and the exit code
      --verbose     Stream the backend's raw output

    NOTES:
      Finished commands are also recorded in the app's Activity Center.
      Passwords are never accepted on the command line — see `simplezip help create`.
      Exit codes: 0 success · 1 failures or differences found · 2 usage or environment error
    """

    /// `help <command>` 的详细用法(0.4.4 A)。
    nonisolated static func usage(for command: String) -> String {
        switch command {
        case "open":
            return """
            simplezip open <file>...

            Opens files or archives in the SimpleZip app (equivalent to double-clicking them).
            """
        case "check":
            return """
            simplezip check <archive>... [--json] [--quiet] [--verbose]

            Tests archive integrity with the bundled 7-Zip engine. Multiple archives are
            tested one by one and a summary line is printed at the end.
            Encrypted archives prompt with a small dialog — passwords never touch the
            command line. Exit 1 if any archive fails.
            """
        case "compare":
            return """
            simplezip compare <left> <right> [--json] [--quiet]

            Compares the entry lists of two archives (path, size, CRC, modified,
            encryption). Exit 1 when they differ, 0 when identical.
            """
        case "create":
            return """
            simplezip create <output> <input>... [options]

            Creates an archive. The format comes from the output extension (zip, 7z, tar,
            tar.gz, …). Your saved per-format defaults (Settings → Compression) apply
            automatically; the flags below override them.

            OPTIONS:
              --template, -t <name>   Apply a built-in task template (github-release,
                                      windows-friendly, max-7z, encrypted-delivery,
                                      source-code, backup)
              --level, -l <0-9>       Compression level
              --exclude-junk          Skip .DS_Store, AppleDouble, Thumbs.db, desktop.ini
              --reproducible          Deterministic output (zip/7z): same input,
                                      byte-identical archive
              --encrypt               Encrypt the archive. The password is read from the
                                      SIMPLEZIP_PASSWORD environment variable, or prompted
                                      interactively on the terminal (never echoed).
                                      It is NEVER accepted as a command-line argument.

            Never overwrites an existing output file.
            """
        case "verify":
            return """
            simplezip verify <checksum-file>... [--json] [--quiet]

            Verifies the files listed in checksum files (GNU `sha256sum` format, BSD tag
            format, bare digests, .sfv). Paths are resolved relative to each checksum
            file; unsafe entries (absolute paths, ..) are rejected. Exit 1 if anything
            fails; a summary line is printed per file and for the whole run.
            """
        case "doctor":
            return """
            simplezip doctor [--json]

            Checks the CLI environment: the SimpleZip.app this command belongs to, the
            bundled 7-Zip engine, the optional RAR and GPG backends, and whether the
            /usr/local/bin/simplezip symlink points at this app.
            """
        case "version":
            return "simplezip version — prints the app version this CLI belongs to."
        case "completions":
            return """
            simplezip completions <zsh|bash|fish>

            Prints a shell completion script to stdout. Redirect it into your shell's
            completion directory, e.g.:
              simplezip completions zsh  > "${fpath[1]}/_simplezip"
              simplezip completions bash > /usr/local/etc/bash_completion.d/simplezip
              simplezip completions fish > ~/.config/fish/completions/simplezip.fish
            """
        case "help":
            return "simplezip help [command] — this text, or detailed help for one command."
        default:
            return usage
        }
    }
}

// MARK: - simplezip:// URL scheme 动作(队列 #16)

/// `simplezip://` 的用户级动词:`simplezip://check?path=/…`、`simplezip://compare?left=/…&right=/…`、
/// `simplezip://open?path=/…`。解析是纯函数(SwiftPM 可测);URL scheme 任何本地进程 / 网页都能发,
/// 所以**动作执行前必须经 app 内确认弹窗**(AppDelegate 弹,列出动作与完整路径)。
/// 只接受绝对路径;`finder-action` host 是内部管道(独立校验),不在这里。
enum SimpleZipURLCommand: Equatable {
    case check(path: String)
    case compare(left: String, right: String)
    case open(path: String)

    nonisolated static func parse(_ url: URL) -> SimpleZipURLCommand? {
        guard url.scheme?.lowercased() == "simplezip",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func absolutePath(_ name: String) -> String? {
            guard let value = components.queryItems?.first(where: { $0.name == name })?.value,
                  value.hasPrefix("/") else { return nil }
            return value
        }
        switch url.host?.lowercased() {
        case "check", "test":
            guard let path = absolutePath("path") else { return nil }
            return .check(path: path)
        case "compare":
            guard let left = absolutePath("left"), let right = absolutePath("right") else { return nil }
            return .compare(left: left, right: right)
        case "open":
            guard let path = absolutePath("path") else { return nil }
            return .open(path: path)
        default:
            return nil
        }
    }
}

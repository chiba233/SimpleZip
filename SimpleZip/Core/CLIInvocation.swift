//
//  CLIInvocation.swift
//  SimpleZip
//
//  CLI companion(`simplezip` 命令)的入口判定 + 参数解析 —— 纯函数,无副作用,SwiftPM 可测。
//  真正执行在 app target 的 CLIRunner(需要后端、AppKit 与活动中心)。
//

import Foundation

enum CLIInvocation: Equatable {
    case help
    case version
    case open(paths: [String])
    case check(paths: [String])
    case compare(left: String, right: String)
    /// 创建归档。压缩选项自动套用该格式在 app 里保存的默认值(设置 → 压缩,与 Finder 一键压缩同口径)。
    /// `--template <name>` 命名模板暂缓:app 内命名预设存储当前无 UI 使用,绑定对象待用户拍板。
    case create(output: String, inputs: [String])
    case verify(path: String)

    enum ParseError: Error, Equatable {
        case unknownCommand(String)
        case missingArguments(command: String)
        case unexpectedOption(String)

        /// CLI 输出固定英文:进程经 PATH 符号链接运行时 Bundle.main 解析不到 app bundle
        /// (实测 bundlePath 落在符号链接所在目录),L10n 不可用;脚本/CI 也需要稳定输出。
        var message: String {
            switch self {
            case .unknownCommand(let command):
                return "unknown command: \(command)"
            case .missingArguments(let command):
                return "missing or wrong arguments for: \(command)"
            case .unexpectedOption(let option):
                return "unexpected option: \(option)"
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

    /// 解析子命令与其参数(传入的数组**不含** argv0 与 `--cli` 前缀)。
    nonisolated static func parse(_ arguments: [String]) throws -> CLIInvocation {
        guard let command = arguments.first else { return .help }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "help", "--help", "-h":
            return .help
        case "version", "--version", "-v":
            return .version
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
            try rejectOptions(in: rest)
            guard rest.count >= 2 else { throw ParseError.missingArguments(command: command) }
            return .create(output: rest[0], inputs: Array(rest.dropFirst()))
        case "verify":
            try rejectOptions(in: rest)
            guard rest.count == 1 else { throw ParseError.missingArguments(command: command) }
            return .verify(path: rest[0])
        default:
            throw ParseError.unknownCommand(command)
        }
    }

    private nonisolated static func rejectOptions(in arguments: [String]) throws {
        if let option = arguments.first(where: { $0.hasPrefix("-") }) {
            throw ParseError.unexpectedOption(option)
        }
    }

    nonisolated static let usage = """
    simplezip — SimpleZip command-line companion

    USAGE:
      simplezip open <file>...                   Open files or archives in the SimpleZip app
      simplezip check <archive>...               Test archive integrity (exit 1 on any failure)
      simplezip compare <left> <right>           Compare two archives (exit 1 when different)
      simplezip create <output> <input>...       Create an archive; format from the output extension,
                                                 your saved per-format defaults apply automatically
      simplezip verify <checksum-file>           Verify SHA256SUMS / checksums.txt / .sha256 / .md5 / .sfv
      simplezip version                          Print version
      simplezip help                             Show this help

    NOTES:
      Finished commands are also recorded in the app's Activity Center.
      Encrypted archives are not supported by the CLI yet — use the app.
      Exit codes: 0 success · 1 failures or differences found · 2 usage or environment error
    """
}

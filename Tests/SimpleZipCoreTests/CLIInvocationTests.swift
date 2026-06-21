import Foundation
import Testing
@testable import SimpleZipCore

/// CLI companion 的入口判定 + 参数解析回归测试(纯函数,执行器在 app target 不在测试范围)。
struct CLIInvocationTests {

    // MARK: - 入口判定

    @Test func symlinkNameEntersCLIMode() {
        #expect(CLIInvocation.isCLIInvocation(argv0: "/usr/local/bin/simplezip", firstArgument: nil))
        #expect(CLIInvocation.isCLIInvocation(argv0: "simplezip", firstArgument: "check"))
    }

    @Test func guiBinaryNameStaysGUI() {
        #expect(!CLIInvocation.isCLIInvocation(argv0: "/Applications/SimpleZip.app/Contents/MacOS/SimpleZip", firstArgument: nil))
        // LaunchServices 可能传 -psn_… 类参数,不能误判成 CLI。
        #expect(!CLIInvocation.isCLIInvocation(argv0: "/Applications/SimpleZip.app/Contents/MacOS/SimpleZip", firstArgument: "-psn_0_12345"))
    }

    @Test func explicitCLIFlagEntersCLIMode() {
        #expect(CLIInvocation.isCLIInvocation(argv0: "/Applications/SimpleZip.app/Contents/MacOS/SimpleZip", firstArgument: "--cli"))
    }

    // MARK: - 子命令解析

    @Test func emptyArgumentsShowHelp() throws {
        #expect(try CLIInvocation.parse([]) == .help)
        #expect(try CLIInvocation.parse(["help"]) == .help)
        #expect(try CLIInvocation.parse(["--help"]) == .help)
    }

    @Test func versionParses() throws {
        #expect(try CLIInvocation.parse(["version"]) == .version)
        #expect(try CLIInvocation.parse(["-v"]) == .version)
    }

    @Test func openRequiresAtLeastOnePath() throws {
        #expect(try CLIInvocation.parse(["open", "a.zip", "b.7z"]) == .open(paths: ["a.zip", "b.7z"]))
        #expect(throws: CLIInvocation.ParseError.missingArguments(command: "open")) {
            try CLIInvocation.parse(["open"])
        }
    }

    @Test func checkParsesMultipleArchives() throws {
        #expect(try CLIInvocation.parse(["check", "a.zip"]) == .check(paths: ["a.zip"]))
        #expect(try CLIInvocation.parse(["check", "a.zip", "b.tar.zst"]) == .check(paths: ["a.zip", "b.tar.zst"]))
        #expect(throws: CLIInvocation.ParseError.missingArguments(command: "check")) {
            try CLIInvocation.parse(["check"])
        }
    }

    @Test func compareNeedsExactlyTwo() throws {
        #expect(try CLIInvocation.parse(["compare", "a.zip", "b.zip"]) == .compare(left: "a.zip", right: "b.zip"))
        #expect(throws: CLIInvocation.ParseError.missingArguments(command: "compare")) {
            try CLIInvocation.parse(["compare", "a.zip"])
        }
        #expect(throws: CLIInvocation.ParseError.missingArguments(command: "compare")) {
            try CLIInvocation.parse(["compare", "a.zip", "b.zip", "c.zip"])
        }
    }

    @Test func createNeedsOutputAndInputs() throws {
        #expect(try CLIInvocation.parse(["create", "out.zip", "x.txt", "y.txt"])
            == .create(output: "out.zip", inputs: ["x.txt", "y.txt"], options: CLICreateOptions()))
        #expect(throws: CLIInvocation.ParseError.missingArguments(command: "create")) {
            try CLIInvocation.parse(["create", "out.zip"])
        }
    }

    @Test func createParsesTemplateSlug() throws {
        #expect(try CLIInvocation.parse(["create", "out.zip", "x.txt", "--template", "github-release"])
            == .create(output: "out.zip", inputs: ["x.txt"], options: CLICreateOptions(template: "github-release")))
        // 模板 slug 与内置目录对得上(单一事实来源在 CompressionPreset)。
        #expect(CompressionPreset.builtInTemplate(slug: "GitHub-Release") != nil)
        #expect(CompressionPreset.builtInTemplate(slug: "nope") == nil)
        #expect(CompressionPreset.builtInTemplateSlugs.count == CompressionPreset.builtInTemplates().count)
        #expect(throws: CLIInvocation.ParseError.missingArguments(command: "create")) {
            try CLIInvocation.parse(["create", "out.zip", "x.txt", "--template"])
        }
    }

    @Test func verifyParsesOneOrMoreFiles() throws {
        // 0.4.4 A:verify 收多个校验文件(批量摘要)。
        #expect(try CLIInvocation.parse(["verify", "SHA256SUMS"]) == .verify(paths: ["SHA256SUMS"]))
        #expect(try CLIInvocation.parse(["verify", "a.sha256", "b.md5"]) == .verify(paths: ["a.sha256", "b.md5"]))
        #expect(throws: CLIInvocation.ParseError.missingArguments(command: "verify")) {
            try CLIInvocation.parse(["verify"])
        }
    }

    @Test func hashDefaultsToSHA256() throws {
        // 0.4.5:无 --algo 默认 SHA256;接受一个或多个路径。
        #expect(try CLIInvocation.parse(["hash", "a.bin"]) == .hash(paths: ["a.bin"], algorithms: [.sha256]))
        #expect(try CLIInvocation.parse(["hash", "a.bin", "b.bin"]) == .hash(paths: ["a.bin", "b.bin"], algorithms: [.sha256]))
    }

    @Test func hashParsesAlgorithmList() throws {
        #expect(try CLIInvocation.parse(["hash", "--algo", "sha256,sha512", "a.bin"])
                == .hash(paths: ["a.bin"], algorithms: [.sha256, .sha512]))
        // 大小写 / 连字符不敏感,保留顺序、去重。
        #expect(try CLIInvocation.parse(["hash", "-a", "SHA-1,md5,md5", "a.bin"])
                == .hash(paths: ["a.bin"], algorithms: [.sha1, .md5]))
        #expect(try CLIInvocation.parse(["hash", "--algo", "all", "a.bin"])
                == .hash(paths: ["a.bin"], algorithms: HashAlgorithm.allCases))
    }

    @Test func hashRejectsUnknownAlgorithmAndMissingPath() {
        #expect(throws: CLIInvocation.ParseError.invalidValue(option: "--algo", value: "sha999")) {
            try CLIInvocation.parse(["hash", "--algo", "sha999", "a.bin"])
        }
        #expect(throws: CLIInvocation.ParseError.missingArguments(command: "hash")) {
            try CLIInvocation.parse(["hash"])
        }
        #expect(throws: CLIInvocation.ParseError.missingArguments(command: "hash")) {
            try CLIInvocation.parse(["hash", "--algo"])   // 缺算法值
        }
        #expect(throws: CLIInvocation.ParseError.missingArguments(command: "hash")) {
            try CLIInvocation.parse(["hash", "--algo", "sha256"])   // 缺路径
        }
    }

    @Test func listAndInspectTakeExactlyOneArchive() throws {
        #expect(try CLIInvocation.parse(["list", "a.zip"]) == .list(path: "a.zip"))
        #expect(try CLIInvocation.parse(["inspect", "a.zip"]) == .inspect(path: "a.zip"))
        for command in ["list", "inspect"] {
            #expect(throws: CLIInvocation.ParseError.missingArguments(command: command)) {
                try CLIInvocation.parse([command])
            }
            #expect(throws: CLIInvocation.ParseError.missingArguments(command: command)) {
                try CLIInvocation.parse([command, "a.zip", "b.zip"])   // 只收一个
            }
        }
    }

    @Test func extractParsesArchivesAndDestination() throws {
        #expect(try CLIInvocation.parse(["extract", "a.zip"]) == .extract(paths: ["a.zip"], destination: nil))
        #expect(try CLIInvocation.parse(["extract", "a.zip", "b.7z"]) == .extract(paths: ["a.zip", "b.7z"], destination: nil))
        #expect(try CLIInvocation.parse(["extract", "--to", "/out", "a.zip"]) == .extract(paths: ["a.zip"], destination: "/out"))
        #expect(try CLIInvocation.parse(["extract", "a.zip", "-d", "/out"]) == .extract(paths: ["a.zip"], destination: "/out"))
        #expect(throws: CLIInvocation.ParseError.missingArguments(command: "extract")) {
            try CLIInvocation.parse(["extract"])
        }
        #expect(throws: CLIInvocation.ParseError.missingArguments(command: "extract")) {
            try CLIInvocation.parse(["extract", "--to"])   // 缺目标值
        }
        #expect(throws: CLIInvocation.ParseError.unexpectedOption("--bogus")) {
            try CLIInvocation.parse(["extract", "--bogus", "a.zip"])
        }
    }

    @Test func unknownCommandAndOptionsRejected() {
        #expect(throws: CLIInvocation.ParseError.unknownCommand("explode")) {
            try CLIInvocation.parse(["explode"])
        }
        #expect(throws: CLIInvocation.ParseError.unexpectedOption("--force")) {
            try CLIInvocation.parse(["check", "a.zip", "--force"])
        }
    }

    // MARK: - 0.4.4 A:全局旗标 / help 子题 / doctor / create 旗标 / 智能纠错

    @Test func globalFlagsExtractAnywhere() {
        let (rest, options) = CLIInvocation.extractOutputOptions(from: ["--json", "check", "a.zip", "--quiet", "--verbose"])
        #expect(rest == ["check", "a.zip"])
        #expect(options == CLIOutputOptions(json: true, quiet: true, verbose: true))
        let (rest2, options2) = CLIInvocation.extractOutputOptions(from: ["create", "out.zip", "x"])
        #expect(rest2 == ["create", "out.zip", "x"])
        #expect(options2 == CLIOutputOptions())
    }

    @Test func helpWithTopicParses() throws {
        #expect(try CLIInvocation.parse(["help", "create"]) == .helpCommand("create"))
        #expect(throws: CLIInvocation.ParseError.unknownCommand("explode")) {
            try CLIInvocation.parse(["help", "explode"])
        }
        // 每个已知命令都有详细用法(不回落到总 usage)。
        for command in CLIInvocation.knownCommands where command != "open" {
            #expect(CLIInvocation.usage(for: command) != CLIInvocation.usage)
        }
    }

    @Test func doctorParses() throws {
        #expect(try CLIInvocation.parse(["doctor"]) == .doctor)
    }

    @Test func createParsesNewFlags() throws {
        var expected = CLICreateOptions()
        expected.level = 9
        expected.excludeJunk = true
        expected.reproducible = true
        expected.encrypt = true
        #expect(try CLIInvocation.parse([
            "create", "out.7z", "src", "--level", "9", "--exclude-junk", "--reproducible", "--encrypt"
        ]) == .create(output: "out.7z", inputs: ["src"], options: expected))
        #expect(throws: CLIInvocation.ParseError.invalidValue(option: "--level", value: "11")) {
            try CLIInvocation.parse(["create", "out.zip", "x", "--level", "11"])
        }
    }

    @Test func completionsParsePerShell() throws {
        #expect(try CLIInvocation.parse(["completions", "zsh"]) == .completions(shell: .zsh))
        #expect(try CLIInvocation.parse(["completions", "bash"]) == .completions(shell: .bash))
        #expect(try CLIInvocation.parse(["completions", "fish"]) == .completions(shell: .fish))
        #expect(throws: CLIInvocation.ParseError.invalidValue(option: "completions", value: "powershell")) {
            try CLIInvocation.parse(["completions", "powershell"])
        }
        #expect(throws: CLIInvocation.ParseError.missingArguments(command: "completions")) {
            try CLIInvocation.parse(["completions"])
        }
    }

    @Test func completionsScriptsMentionEachShellTarget() {
        // 每个 shell 脚本里都得有它自己的关键标记,确保没串台。
        #expect(CLICompletions.script(for: .zsh).contains("#compdef simplezip"))
        #expect(CLICompletions.script(for: .bash).contains("complete -F _simplezip simplezip"))
        #expect(CLICompletions.script(for: .fish).contains("complete -c simplezip"))
        // 所有已知子命令都该出现在补全里(防止加了命令忘了补全)。
        for command in CLIInvocation.knownCommands {
            #expect(CLICompletions.script(for: .zsh).contains(command), "zsh missing \(command)")
        }
    }

    @Test func nearestCommandSuggestsTypos() {
        #expect(CLIInvocation.nearestCommand(to: "chek") == "check")
        #expect(CLIInvocation.nearestCommand(to: "verfy") == "verify")
        #expect(CLIInvocation.nearestCommand(to: "doctr") == "doctor")
        // 离谱输入不乱猜。
        #expect(CLIInvocation.nearestCommand(to: "frobnicate") == nil)
        // 建议进错误文案。
        #expect(CLIInvocation.ParseError.unknownCommand("chek").message.contains("check"))
    }

    @Test func compressionLevelMapsToClosestTier() {
        #expect(CompressionLevel.closest(toNumeric: 0) == .store)
        #expect(CompressionLevel.closest(toNumeric: 2) == .fast)
        #expect(CompressionLevel.closest(toNumeric: 6) == .normal)
        #expect(CompressionLevel.closest(toNumeric: 9) == .maximum)
        #expect(CompressionLevel.closest(toNumeric: 11) == nil)
    }
}

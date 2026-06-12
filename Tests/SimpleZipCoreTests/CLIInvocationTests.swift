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
            == .create(output: "out.zip", inputs: ["x.txt", "y.txt"], template: nil))
        #expect(throws: CLIInvocation.ParseError.missingArguments(command: "create")) {
            try CLIInvocation.parse(["create", "out.zip"])
        }
    }

    @Test func createParsesTemplateSlug() throws {
        #expect(try CLIInvocation.parse(["create", "out.zip", "x.txt", "--template", "github-release"])
            == .create(output: "out.zip", inputs: ["x.txt"], template: "github-release"))
        // 模板 slug 与内置目录对得上(单一事实来源在 CompressionPreset)。
        #expect(CompressionPreset.builtInTemplate(slug: "GitHub-Release") != nil)
        #expect(CompressionPreset.builtInTemplate(slug: "nope") == nil)
        #expect(CompressionPreset.builtInTemplateSlugs.count == CompressionPreset.builtInTemplates().count)
        #expect(throws: CLIInvocation.ParseError.missingArguments(command: "create")) {
            try CLIInvocation.parse(["create", "out.zip", "x.txt", "--template"])
        }
    }

    @Test func verifyNeedsExactlyOneFile() throws {
        #expect(try CLIInvocation.parse(["verify", "SHA256SUMS"]) == .verify(path: "SHA256SUMS"))
        #expect(throws: CLIInvocation.ParseError.missingArguments(command: "verify")) {
            try CLIInvocation.parse(["verify"])
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
}

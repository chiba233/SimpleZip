import XCTest
@testable import SimpleZipCore

/// 防漂移:加了新子命令(`CLIInvocation.knownCommands`)却忘了同步补全脚本(`CLICompletions`)时,这个测试挂。
final class CLICompletionsDriftTests: XCTestCase {
    func testEveryKnownCommandAppearsInEveryShellScript() {
        for shell in CLICompletions.Shell.allCases {
            let script = CLICompletions.script(for: shell)
            for command in CLIInvocation.knownCommands {
                XCTAssertTrue(
                    script.contains(command),
                    "\(shell.rawValue) completion script is missing the command '\(command)' — update CLICompletions when adding a command."
                )
            }
        }
    }

    func testZshScriptDescribesEachCommandAsACompletionEntry() {
        // zsh 用 'cmd:描述' 形式;确保每个命令都以补全条目出现,而非只是脚本里别处的子串巧合。
        let zsh = CLICompletions.script(for: .zsh)
        for command in CLIInvocation.knownCommands {
            XCTAssertTrue(zsh.contains("'\(command):"), "zsh completion missing entry for '\(command)'.")
        }
    }
}

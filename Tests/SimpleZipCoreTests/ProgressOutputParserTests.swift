import Foundation
import Testing
@testable import SimpleZipCore

/// 7zz 管道下的实时进度是**退格流**(od 实测):`  2%\b\b\b\b    \b\b\b\b  4%…`,整个压缩期间
/// 可能没有任何 \n。解析器必须把 \b 当行界,否则单大文件创建/测试的 UI 全程卡 0%(用户实报)。
struct ProgressOutputParserTests {

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [ArchiveProgressState] = []
        func append(_ state: ArchiveProgressState) {
            lock.lock(); defer { lock.unlock() }
            states.append(state)
        }
        var fractions: [Double] {
            lock.lock(); defer { lock.unlock() }
            return states.compactMap(\.fraction)
        }
        var currentFiles: [String] {
            lock.lock(); defer { lock.unlock() }
            return states.compactMap(\.currentFile)
        }
    }

    @Test func parsesBackspaceSeparatedPercentStream() {
        let collected = Collected()
        let parser = ProgressOutputParser(totalFiles: 1) { collected.append($0) }
        // 真实 7zz -bsp1 管道输出形态:百分比 token 之间只有退格和空格,没有换行。
        parser.consume("  0%\u{08}\u{08}\u{08}\u{08}    \u{08}\u{08}\u{08}\u{08}  2%\u{08}\u{08}\u{08}\u{08}    ")
        parser.consume("\u{08}\u{08}\u{08}\u{08} 47%\u{08}\u{08}\u{08}\u{08}    \u{08}\u{08}\u{08}\u{08} 73%")
        parser.finish()

        let fractions = collected.fractions
        #expect(fractions.contains(0.02))
        #expect(fractions.contains(0.47))
        #expect(fractions.contains(0.73))
        // finish() 收尾必须打满 1.0。
        #expect(fractions.last == 1.0)
        // 纯百分比 token 不得被当成文件名下发。
        #expect(!collected.currentFiles.contains("2%"))
        #expect(!collected.currentFiles.contains("73%"))
    }

    @Test func percentTokenWithFileNameStillReportsBoth() {
        let collected = Collected()
        let parser = ProgressOutputParser(totalFiles: nil) { collected.append($0) }
        parser.consume("  0%    + big1.bin\n 12%\u{08}\u{08}\u{08}\u{08}")
        #expect(collected.fractions.contains(0.12))
    }

    @Test func multithreadPercentAndDigitFragmentsAreNotFileNames() {
        let collected = Collected()
        let parser = ProgressOutputParser(totalFiles: nil) { collected.append($0) }
        // 多线程形态「 51% 1」与退格切出的纯数字片段都不是文件名。
        parser.consume(" 51% 1\u{08}\u{08}\u{08}\u{08}\n1\n 63% 1\n")
        #expect(collected.fractions.contains(0.51))
        #expect(collected.fractions.contains(0.63))
        #expect(collected.currentFiles.isEmpty)
    }
}

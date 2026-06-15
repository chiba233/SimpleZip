//
//  AIFailureDegradationTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 失败降级矩阵(白皮书工程补充十二)。每种失败都有确定性 fallback;AI 失败绝不弹阻塞 alert。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIFailureDegradationTests {
    @Test func everyFailureKindHasStrategyAndCategory() {
        // 矩阵完整:每个失败类型都映射到策略与分类(无遗漏 → 编译期 switch 全覆盖 + 此处遍历断言)。
        for kind in AIFailureKind.allCases {
            _ = AIFailureDegradation.strategy(for: kind)
            _ = AIFailureDegradation.category(for: kind)
        }
        #expect(AIFailureKind.allCases.count == 11)
    }

    @Test func keyStrategiesMatchWhitepaper() {
        #expect(AIFailureDegradation.strategy(for: .modelUnavailable) == .useDeterministic)
        #expect(AIFailureDegradation.strategy(for: .jsonParseFailed) == .discardAIOutput)
        #expect(AIFailureDegradation.strategy(for: .sourceRefInvalid) == .dropElement)
        #expect(AIFailureDegradation.strategy(for: .dangerousAction) == .dropActionKeepReadonly)
        #expect(AIFailureDegradation.strategy(for: .emptyResult) == .showEmptyStateReason)
        #expect(AIFailureDegradation.strategy(for: .redactionBlocked) == .blockShowBasic)
        #expect(AIFailureDegradation.strategy(for: .schemaMismatch) == .migrateOrRebuild)
    }

    @Test func categoriesPartitionFailures() {
        #expect(AIFailureDegradation.category(for: .modelUnavailable) == .modelFailure)
        #expect(AIFailureDegradation.category(for: .sourceRefInvalid) == .validationFailure)
        #expect(AIFailureDegradation.category(for: .dangerousAction) == .validationFailure)
        #expect(AIFailureDegradation.category(for: .redactionBlocked) == .privacyBlock)
        #expect(AIFailureDegradation.category(for: .userDisabled) == .userDisabled)
    }

    @Test func neverShowsBlockingAlert() {
        // 铁律:任何失败都不弹阻塞 alert。
        for kind in AIFailureKind.allCases {
            #expect(!AIFailureDegradation.showsBlockingAlert(for: kind))
        }
    }

    @Test func aiOutputIsNeverSoleSource() {
        #expect(AIFailureDegradation.aiOutputCanBeSoleSource == false)
    }

    @Test func strategyCodableStable() throws {
        for kind in AIFailureKind.allCases {
            let s = AIFailureDegradation.strategy(for: kind)
            let decoded = try JSONDecoder().decode(AIDegradationStrategy.self, from: JSONEncoder().encode(s))
            #expect(decoded == s)
        }
    }
}

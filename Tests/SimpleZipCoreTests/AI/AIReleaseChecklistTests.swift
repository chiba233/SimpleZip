//
//  AIReleaseChecklistTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:发布前 checklist(白皮书 Feat 20)。确定性 facts→清单;GPG 关闭时签名/公钥项不出现(A4)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIReleaseChecklistTests {
    @Test func emptyFactsAllMissingPrimaryIsTest() {
        let list = AIReleaseChecklistBuilder.build(from: AIReleaseChecklistFacts(gpgEnabled: true))
        #expect(list.items.allSatisfy { $0.state == .missing })
        // 第一个缺失且有动作的项 = testArchive → runTest。
        #expect(list.primaryActionID == "runTest")
    }

    @Test func gpgDisabledHidesSignatureItems() {
        let list = AIReleaseChecklistBuilder.build(from:
            AIReleaseChecklistFacts(hasSignature: true, hasPublicKey: true, gpgEnabled: false))
        let ids = Set(list.items.map(\.id))
        #expect(!ids.contains(.checkSignature))
        #expect(!ids.contains(.publicKeyPresent))
        // 非签名项仍在。
        #expect(ids.contains(.testArchive))
        #expect(ids.contains(.verifyHash))
        #expect(ids.contains(.inspectReport))
    }

    @Test func gpgEnabledShowsSignatureItems() {
        let list = AIReleaseChecklistBuilder.build(from:
            AIReleaseChecklistFacts(hasSignature: true, hasPublicKey: true, gpgEnabled: true))
        let ids = Set(list.items.map(\.id))
        #expect(ids.contains(.checkSignature))
        #expect(ids.contains(.publicKeyPresent))
        #expect(list.items.first { $0.id == .checkSignature }?.state == .available)
    }

    @Test func testedAndInspectedShowPassed() {
        let list = AIReleaseChecklistBuilder.build(from:
            AIReleaseChecklistFacts(hasChecksumFile: true, archiveTested: true, inspectionDone: true, gpgEnabled: false))
        #expect(list.items.first { $0.id == .testArchive }?.state == .passed)
        #expect(list.items.first { $0.id == .inspectReport }?.state == .passed)
        #expect(list.items.first { $0.id == .verifyHash }?.state == .available)
    }

    @Test func primaryActionSkipsActionlessMissingItems() {
        // testArchive passed,verifyHash available,但 VERIFY.md 缺(无动作)→ primary 应是下一个有动作的缺失项
        // (inspectReport → runReleaseInspection),而不是无动作的 verifyDocPresent。
        let list = AIReleaseChecklistBuilder.build(from:
            AIReleaseChecklistFacts(hasChecksumFile: true, hasVerifyDoc: false,
                                    archiveTested: true, inspectionDone: false, gpgEnabled: false))
        #expect(list.primaryActionID == "runReleaseInspection")
    }

    @Test func allReadyHasNoPrimaryAction() {
        let list = AIReleaseChecklistBuilder.build(from:
            AIReleaseChecklistFacts(hasChecksumFile: true, hasVerifyDoc: true,
                                    archiveTested: true, inspectionDone: true, gpgEnabled: false))
        // 全部非 missing(passed/available)→ 无缺失动作。
        #expect(list.primaryActionID == nil)
    }

    @Test func itemOrderIsDeterministic() {
        let list = AIReleaseChecklistBuilder.build(from: AIReleaseChecklistFacts(gpgEnabled: true))
        #expect(list.items.map(\.id) == [.testArchive, .verifyHash, .checkSignature, .publicKeyPresent, .verifyDocPresent, .inspectReport])
    }

    @Test func codableRoundTrip() throws {
        let list = AIReleaseChecklistBuilder.build(from: AIReleaseChecklistFacts(gpgEnabled: true))
        let decoded = try JSONDecoder().decode(AIReleaseChecklist.self, from: JSONEncoder().encode(list))
        #expect(decoded == list)
    }
}

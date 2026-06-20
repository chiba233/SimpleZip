//
//  AIWorkspaceEvidenceGapBuilderTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80(工程补充五接线 Phase 1):验证「工作区成员缺哈希」缺口判定的确定性与正确性。
//

import XCTest
@testable import SimpleZipCore

final class AIWorkspaceEvidenceGapBuilderTests: XCTestCase {
    private func ref(_ id: String) -> AIContextSourceRef { AIContextSourceRef(kind: .file, id: id) }

    func testMissingHashGapExcludesAlreadyHashedMembers() {
        let ws = UUID()
        let gaps = AIWorkspaceEvidenceGapBuilder.deriveMissingHash(
            memberRefsByWorkspace: [ws: [ref("a"), ref("b"), ref("c")]],
            hashedSourceRefs: [ref("b")])
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].kind, .missingHash)
        XCTAssertEqual(gaps[0].workspaceID, ws)
        // 排除已哈希的 b,剩 a/c 按 id 升序。
        XCTAssertEqual(gaps[0].affectedSourceRefs, [ref("a"), ref("c")])
    }

    func testNoGapWhenAllMembersHashed() {
        let ws = UUID()
        let gaps = AIWorkspaceEvidenceGapBuilder.deriveMissingHash(
            memberRefsByWorkspace: [ws: [ref("a"), ref("b")]],
            hashedSourceRefs: [ref("a"), ref("b")])
        XCTAssertTrue(gaps.isEmpty)
    }

    func testNoGapForEmptyWorkspace() {
        let gaps = AIWorkspaceEvidenceGapBuilder.deriveMissingHash(
            memberRefsByWorkspace: [UUID(): []],
            hashedSourceRefs: [])
        XCTAssertTrue(gaps.isEmpty)
    }

    func testDeterministicWorkspaceOrderByUUID() {
        let ws1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let ws2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        // 字典输入顺序故意倒置,输出必须按 UUID 升序。
        let gaps = AIWorkspaceEvidenceGapBuilder.deriveMissingHash(
            memberRefsByWorkspace: [ws2: [ref("x")], ws1: [ref("y")]],
            hashedSourceRefs: [])
        XCTAssertEqual(gaps.map(\.workspaceID), [ws1, ws2])
    }

    func testMissingHashGapCarriesEnrichmentAction() {
        let ws = UUID()
        let gaps = AIWorkspaceEvidenceGapBuilder.deriveMissingHash(
            memberRefsByWorkspace: [ws: [ref("a")]],
            hashedSourceRefs: [])
        XCTAssertEqual(gaps.count, 1)
        // missingHash 工厂自带「算 SHA256」增强动作,dispatcher 据此入队。
        XCTAssertNotNil(gaps[0].suggestedEnrichmentAction)
    }

    // MARK: - Phase 2: missingArchiveHealth(小归档没测)

    func testMissingArchiveHealthExcludesTestedAndNonArchive() {
        let ws = UUID()
        // a/c 是小归档没测;b 是小归档但已测;d 不是归档 → 只 a/c 产缺口。
        let gaps = AIWorkspaceEvidenceGapBuilder.deriveMissingArchiveHealth(
            memberRefsByWorkspace: [ws: [ref("a"), ref("b"), ref("c"), ref("d")]],
            archiveSourceRefs: [ref("a"), ref("b"), ref("c")],
            testedSourceRefs: [ref("b")])
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].kind, .missingArchiveHealth)
        XCTAssertEqual(gaps[0].affectedSourceRefs, [ref("a"), ref("c")])
    }

    func testNoArchiveHealthGapWhenNoArchiveMembers() {
        let ws = UUID()
        let gaps = AIWorkspaceEvidenceGapBuilder.deriveMissingArchiveHealth(
            memberRefsByWorkspace: [ws: [ref("a"), ref("b")]],
            archiveSourceRefs: [],
            testedSourceRefs: [])
        XCTAssertTrue(gaps.isEmpty)
    }

    func testArchiveHealthGapCarriesTestEnrichmentAction() {
        let ws = UUID()
        let gaps = AIWorkspaceEvidenceGapBuilder.deriveMissingArchiveHealth(
            memberRefsByWorkspace: [ws: [ref("a")]],
            archiveSourceRefs: [ref("a")],
            testedSourceRefs: [])
        XCTAssertEqual(gaps.count, 1)
        // missingArchiveHealth 工厂自带「测试归档」增强动作。
        XCTAssertNotNil(gaps[0].suggestedEnrichmentAction)
    }
}

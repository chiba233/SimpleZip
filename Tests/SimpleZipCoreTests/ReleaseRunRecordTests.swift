//
//  ReleaseRunRecordTests.swift
//  SimpleZipCoreTests
//
//  0.4.4 F3:发布步骤记录器 —— 成功 / 失败 / 跳过留痕、耗时格式、Codable 容错。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ReleaseRunRecordTests {
    @Test func recorderRecordsSuccessAndResult() async throws {
        let recorder = ReleaseStepRecorder()
        let value = try await recorder.perform(.createArchive) { 42 }
        #expect(value == 42)
        #expect(recorder.steps.count == 1)
        #expect(recorder.steps[0].id == .createArchive)
        #expect(recorder.steps[0].status == .succeeded)
        #expect(recorder.steps[0].failureMessage == nil)
    }

    @Test func recorderRecordsFailureAndRethrows() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let recorder = ReleaseStepRecorder()
        do {
            _ = try await recorder.perform(.inspect) { throw Boom() }
            Issue.record("expected throw")
        } catch {
            // 预期抛出
        }
        #expect(recorder.steps.count == 1)
        #expect(recorder.steps[0].status == .failed)
        #expect(recorder.steps[0].failureMessage == "boom")
    }

    @Test func recorderRecordsSkippedInSequence() async throws {
        let recorder = ReleaseStepRecorder()
        recorder.recordSkipped(.createArchive)
        _ = try await recorder.perform(.checksums) { true }
        #expect(recorder.steps.map(\.id) == [.createArchive, .checksums])
        #expect(recorder.steps.map(\.status) == [.skipped, .succeeded])
        #expect(recorder.steps[0].durationSeconds == 0)
    }

    @Test func durationFormatting() {
        func step(_ seconds: TimeInterval) -> ReleaseRunStep {
            ReleaseRunStep(id: .inspect, status: .succeeded, durationSeconds: seconds, failureMessage: nil)
        }
        #expect(step(0.245).formattedDuration == "245 ms")
        #expect(step(3.21).formattedDuration == "3.2 s")
        #expect(step(125).formattedDuration == "2 min 5 s")
    }

    @Test func unknownStepIDAndStatusDecodeLossily() throws {
        let json = #"{"id":"futureStep","status":"futureStatus","durationSeconds":1.5,"failureMessage":null}"#
        let step = try JSONDecoder().decode(ReleaseRunStep.self, from: Data(json.utf8))
        #expect(step.id == .createArchive)
        #expect(step.status == .failed)
    }

    @Test func roundTripsThroughCodable() throws {
        let step = ReleaseRunStep(id: .checksums, status: .succeeded, durationSeconds: 2.5, failureMessage: nil)
        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(ReleaseRunStep.self, from: data)
        #expect(decoded == step)
    }
}

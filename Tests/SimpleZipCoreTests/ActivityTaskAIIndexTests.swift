//
//  ActivityTaskAIIndexTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:任务 AI 记录 —— 脱敏 / 诊断分类 / 路径低敏化 / JSONL 预算。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ActivityTaskAIIndexTests {
    private func sample(status: String = "failed",
                        failure: String? = "ERROR: Can not create output directory : Permission denied",
                        raw: String? = "ERROR: Can not create output directory : Permission denied") -> AITaskRecord {
        AITaskRecord.make(
            id: "task-7B2F", category: "archive", kind: "extract", source: "finder", status: status,
            title: "Extract minecraft.zip",
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_750_000_018),
            archivePath: "/Users/tester/Downloads/minecraft.zip",
            failureMessage: failure, rawOutput: raw, home: "/Users/tester")
    }

    @Test func classifiesDiagnosticsFromFailure() {
        #expect(sample().diagnostics.tags.contains("permission-denied"))
    }

    @Test func derivesLowSensitivityPathFacts() {
        let r = sample()
        #expect(r.files.archiveName == "minecraft.zip")
        #expect(r.files.archiveExtension == "zip")
        #expect(r.files.locationKinds.contains("downloads"))
        #expect(r.files.pathTokens.contains("minecraft"))
        #expect(r.durationSeconds == 18)
    }

    @Test func failureMessageIsRedacted() {
        let r = sample(failure: "auth failed password=hunter2", raw: "password=hunter2")
        #expect(r.diagnostics.failureMessage?.contains("hunter2") == false)
        #expect(r.diagnostics.errorLines.allSatisfy { !$0.contains("hunter2") })
    }

    @Test func jsonLineIsCompactAndCarriesStableFields() throws {
        let line = try sample().jsonLine()
        #expect(line.contains("\"id\":\"task-7B2F\""))
        #expect(line.contains("\"kind\":\"extract\""))
        #expect(line.contains("\"source\":\"finder\""))
        #expect(!line.contains("\n")) // 单行
    }

    @Test func jsonlCapsToBudgetAndReportsOmission() {
        let many = (0..<10).map { _ in sample() }
        let budget = AIBudget(maxItems: 3, maxTextChars: 800, maxSamplesPerGroup: 8)
        let (text, omission) = ActivityTaskAIIndex.jsonl(many, budget: budget)
        #expect(text.split(separator: "\n").count == 3)
        #expect(omission?.type == "tasks")
        #expect(omission?.count == 7)
    }

    @Test func jsonlIsDeterministic() {
        let records = [sample(), sample(status: "succeeded", failure: nil, raw: nil)]
        #expect(ActivityTaskAIIndex.jsonl(records).text == ActivityTaskAIIndex.jsonl(records).text)
    }

    @Test func cleanTaskHasNoDiagnosticTags() {
        let r = sample(status: "succeeded", failure: nil, raw: "Everything is Ok")
        #expect(r.diagnostics.tags.isEmpty)
        #expect(r.diagnostics.failureMessage == nil)
    }
}

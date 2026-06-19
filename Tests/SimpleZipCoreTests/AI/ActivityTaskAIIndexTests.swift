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

    /// 数据接全:文件操作等**无后端 rawOutput** 的失败,逐文件失败明细经 `extraDiagnosticLines` 喂入 ——
    /// 进 errorLines 给模型具体上下文,且被确定性分类器打成标签(否则顶层泛泛消息只能瞎猜);同样脱敏。
    @Test func extraDiagnosticLinesFeedErrorLinesAndTags() {
        let r = AITaskRecord.make(
            id: "mv-1", category: "fileOperation", kind: "move", source: "app", status: "failed",
            title: "Move 3 items", startedAt: nil, finishedAt: nil,
            failureMessage: "1 item failed", rawOutput: nil,
            extraDiagnosticLines: ["report.pdf: Permission denied", "data.bin: No such file or directory"])
        // 具体逐文件原因进了 errorLines(给模型可读上下文)。
        #expect(r.diagnostics.errorLines.contains { $0.contains("report.pdf") && $0.contains("Permission denied") })
        // 确定性分类器据此打标签(顶层「1 item failed」打不出 permission-denied)。
        #expect(r.diagnostics.tags.contains("permission-denied"))
        // 脱敏仍生效(secret 形态的明细被抓)。
        let secret = AITaskRecord.make(
            id: "mv-2", category: "fileOperation", kind: "copy", source: "app", status: "failed",
            title: "Copy", startedAt: nil, finishedAt: nil, rawOutput: nil,
            extraDiagnosticLines: ["sync.conf: password=hunter2 rejected"])
        #expect(secret.diagnostics.errorLines.allSatisfy { !$0.contains("hunter2") })
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

    @Test func titleWithSecretFormIsRedacted() {
        let r = AITaskRecord.make(id: "t", category: "archive", kind: "test", source: "app", status: "failed",
                                  title: "Testing password=hunter2.7z", startedAt: nil, finishedAt: nil)
        #expect(r.title.contains("hunter2") == false)
    }

    @Test func encryptedSourceTitleDropsEntryNames() {
        let r = AITaskRecord.make(id: "t", category: "archive", kind: "rename", source: "app", status: "succeeded",
                                  title: "Renaming “client-secrets.env” → “prod.env”",
                                  startedAt: nil, finishedAt: nil, encryptedSource: true)
        #expect(!r.title.contains("client-secrets.env"))
        #expect(!r.title.contains("prod.env"))
        #expect(r.title.contains("encrypted"))
    }

    @Test func durationNeverNegative() {
        let r = AITaskRecord.make(id: "t", category: "x", kind: "x", source: "app", status: "x", title: "x",
                                  startedAt: Date(timeIntervalSince1970: 100),
                                  finishedAt: Date(timeIntervalSince1970: 50))
        #expect(r.durationSeconds == 0)
    }

    @Test func cleanTaskHasNoDiagnosticTags() {
        let r = sample(status: "succeeded", failure: nil, raw: "Everything is Ok")
        #expect(r.diagnostics.tags.isEmpty)
        #expect(r.diagnostics.failureMessage == nil)
    }
}

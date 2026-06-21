//
//  ReleaseRunRecord.swift
//  SimpleZip
//
//  0.4.4 F3:发布助手的步骤记录。每步(打包 / 检查 / 校验文件)记录 状态 / 耗时 / 失败原因,
//  Codable —— 进任务 transferLog、将来进 Release Ledger(#2)。纯 Core,SwiftPM 可测。
//

import Foundation

/// 发布流水线里一个步骤的结果。`.szs` 签名是交互式步骤(refreshOnSuccess 里转 sheet),
/// 不进步骤引擎 —— 它没有可记录的时长与无人值守语义。
nonisolated struct ReleaseRunStep: Codable, Equatable {
    enum StepID: String, Codable, CaseIterable {
        case createArchive
        case inspect
        case checksums
        /// #4:写 release-manifest.json(可选步)。
        case manifest

        /// 解码容错:新版本的新步骤被旧版本读到时降级,不废掉整条记录。
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = StepID(rawValue: raw) ?? .createArchive
        }
    }

    enum Status: String, Codable {
        case succeeded
        case failed
        case skipped

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .failed
        }
    }

    let id: StepID
    let status: Status
    let durationSeconds: TimeInterval
    let failureMessage: String?

    /// 「3.2 s」/「245 ms」/「2 min 5 s」—— 活动中心步骤行的耗时展示。
    var formattedDuration: String {
        if durationSeconds < 1 {
            return String(format: "%.0f ms", durationSeconds * 1000)
        }
        if durationSeconds < 60 {
            return String(format: "%.1f s", durationSeconds)
        }
        let minutes = Int(durationSeconds / 60)
        let seconds = Int(durationSeconds.truncatingRemainder(dividingBy: 60))
        return "\(minutes) min \(seconds) s"
    }
}

/// 步骤记录器:`perform` 包住一段既有顺序代码,计时 + 记成功/失败;`recordSkipped` 给被
/// 跳过的步骤留痕(续跑时产物还在 → createArchive 记 skipped,报告里仍能看到完整步骤序列)。
final class ReleaseStepRecorder {
    private(set) var steps: [ReleaseRunStep] = []

    func perform<T>(_ id: ReleaseRunStep.StepID, _ body: () async throws -> T) async throws -> T {
        let start = Date()
        do {
            let result = try await body()
            steps.append(ReleaseRunStep(
                id: id, status: .succeeded,
                durationSeconds: Date().timeIntervalSince(start), failureMessage: nil
            ))
            return result
        } catch {
            steps.append(ReleaseRunStep(
                id: id, status: .failed,
                durationSeconds: Date().timeIntervalSince(start),
                failureMessage: error.localizedDescription
            ))
            throw error
        }
    }

    func recordSkipped(_ id: ReleaseRunStep.StepID) {
        steps.append(ReleaseRunStep(id: id, status: .skipped, durationSeconds: 0, failureMessage: nil))
    }
}

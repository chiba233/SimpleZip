//
//  PerfSignpost.swift
//  SimpleZip
//
//  0.4.4 #9:Instruments 级性能打点(os_signpost / OSSignposter)。
//
//  **零行为影响、零用户可见** —— 仅供开发期用 Instruments 的 "Points of Interest" 轨道排性能。
//  category 用 "PointsOfInterest" 让区间落在该轨道。OSSignposter 自 macOS 12 起可用,部署目标 13 满足,
//  无需 @available。命中点:后端子进程等待、列目录、安全扫描、比较、发布检查、空间分析、图标解码。
//
//  用法:能用单个闭包包住的 → `PerfSignpost.interval("name") { … }`;
//  跨多步、不便单闭包的(如子进程 run→喂stdin→读输出→wait)→ `let s = begin(…); defer { end(…, s) }`。
//

import Foundation
import os

/// `nonisolated`:app target 默认 MainActor 隔离,但打点要从后台线程(子进程等待、图标栅格化、
/// nonisolated Core 分析)同步调用,绝不能隐式 hop 到主 actor。标 nonisolated 让两个 target 里都无隔离。
nonisolated enum PerfSignpost {
    private static let signposter = OSSignposter(subsystem: "com.simplezip.perf", category: "PointsOfInterest")

    /// 同步区间。`name` 必须是字面量(signpost API 要求 StaticString)。
    @inline(__always)
    static func interval<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try work()
    }

    /// async 区间。
    @inline(__always)
    static func interval<T>(_ name: StaticString, _ work: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try await work()
    }

    /// 手动配对。把返回的 state 交给 `end`(配 `defer` 用,确保所有出口都收口)。
    @inline(__always)
    static func begin(_ name: StaticString) -> OSSignpostIntervalState { signposter.beginInterval(name) }

    @inline(__always)
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) { signposter.endInterval(name, state) }
}

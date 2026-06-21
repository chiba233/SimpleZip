//
//  PathHealthCheck.swift
//  SimpleZip
//
//  0.4.4 #42:持久化路径的健康检查。工作区预设(源 / 输出目录)、发布账本(产物路径)跨重启后,
//  目录可能被移动 / 删除、产物可能被清掉。这里把每条路径分成「可访问 / 不存在 / 无读取权限」三态,
//  让用户一眼看出哪条记录已经失效。
//
//  **范围说明(诚实)**:本 app **非沙盒**,有完整磁盘访问(受系统 TCC 约束),不依赖 security-scoped
//  bookmark —— 因此「bookmark 失效 / 一键重新授权」这套在非沙盒下并不适用。能做、也是真有用的是
//  「路径还在不在 / 能不能读」这层检查;真正的 bookmark 重授权要等 app 沙盒化(远期)再说。
//

import Foundation

nonisolated enum PathHealthCheck {
    enum Status: String, Codable, Equatable {
        case accessible   // 存在且可读
        case missing      // 路径不存在(被移动 / 删除 / 改名)
        case unreadable   // 存在但当前不可读(权限 / TCC 未授予该位置)
    }

    static func classify(_ path: String) -> Status {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return .missing }
        return fileManager.isReadableFile(atPath: path) ? .accessible : .unreadable
    }

    /// 一条被检查的持久化路径。`source` 是人类可读来源(如「工作区预设『发布』· 输出目录」)。
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let source: String
        let path: String
        let status: Status

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.source == rhs.source && lhs.path == rhs.path && lhs.status == rhs.status
        }
    }

    /// 分类一组 `(source, path)`,**有问题的排前面**(missing / unreadable 在前,accessible 在后),
    /// 同档按来源名稳定排序 —— 用户最关心的失效项一眼可见。
    static func report(_ items: [(source: String, path: String)]) -> [Entry] {
        items
            .map { Entry(source: $0.source, path: $0.path, status: classify($0.path)) }
            .sorted { lhs, rhs in
                let lhsOK = lhs.status == .accessible
                let rhsOK = rhs.status == .accessible
                if lhsOK != rhsOK { return !lhsOK }          // 有问题的在前
                return lhs.source.localizedStandardCompare(rhs.source) == .orderedAscending
            }
    }
}

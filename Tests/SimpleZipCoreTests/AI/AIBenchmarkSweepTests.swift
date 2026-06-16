//
//  AIBenchmarkSweepTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80: 全 AI 组件基准扫测 + 真实 plist 数据验证。
//  ①-⑨ 使用高真实感合成数据（覆盖参数边界）；⑩ 直接用
//  ~/Library/Preferences/yumeka.SimpleZip-in-mac.plist 提取的真实候选。
//  输出全部数字，供 docs/AI-BENCHMARK-REPORT.md 汇总用。
//

import Foundation
import Testing
@testable import SimpleZipCore

// MARK: - 时间基准（确定性，不取 wall-clock）

private let T0 = Date(timeIntervalSinceReferenceDate: 0)
private func T(_ daysAgo: Double) -> Date { T0.addingTimeInterval(-daysAgo * 86_400) }

// MARK: - 候选工厂

private func ref(_ kind: AIContextSourceRef.Kind, _ id: String) -> AIContextSourceRef {
    .init(kind: kind, id: id)
}

private func nc(_ id: String,
                _ kind: AIVirtualNode.Kind,
                _ name: String,
                refs: [AIContextSourceRef] = [],
                roles: [String] = [],
                signals: [String] = [],
                tasks: [String] = [],
                archives: [String] = [],
                tokens: [String] = []) -> AIVirtualNodeCandidate {
    let r = refs.isEmpty ? [AIContextSourceRef(kind: kind == .task ? .task : (kind == .report ? .report : .archive), id: id)] : refs
    return AIVirtualNodeCandidate(id: id, kind: kind, displayName: name,
                                  sourceRefs: r, roleTags: roles,
                                  relatedTaskIDs: tasks, relatedArchiveIDs: archives,
                                  semanticTokens: tokens, scoreSignals: signals)
}

// MARK: - 合成候选池 33 个（SimpleZip 0.4.5 发布工作流）

private let releasePool: [AIVirtualNodeCandidate] = [
    // ── 归档 (8) ──
    nc("arch-arm64-dmg",    .archive, "SimpleZip-0.4.5-macos-arm64.dmg",
       roles: ["release-artifact", "installer-package"],
       signals: ["project-token", "source-ref-match", "recent-interaction"],
       tokens: ["simplezip", "release", "arm64", "dmg"]),
    nc("arch-x86-dmg",     .archive, "SimpleZip-0.4.5-macos-x86_64.dmg",
       roles: ["release-artifact", "installer-package"],
       signals: ["project-token", "source-ref-match", "recent-interaction"],
       tokens: ["simplezip", "release", "x86", "dmg"]),
    nc("arch-source-tar",  .archive, "SimpleZip-0.4.5-source.tar.gz",
       roles: ["source-archive", "source-package"],
       signals: ["project-token", "source-ref-match", "recent"],
       tokens: ["simplezip", "source", "tarball"]),
    nc("arch-0.4.4-dmg",   .archive, "SimpleZip-0.4.4-macos.dmg",
       roles: ["release-artifact"],
       signals: ["project-token", "same-parent"],
       tokens: ["simplezip", "release", "old"]),
    nc("arch-0.4.3-bak",   .archive, "SimpleZip-0.4.3-backup.zip",
       roles: ["backup-package"],
       signals: ["same-parent", "repeated"],
       tokens: ["simplezip", "backup"]),
    nc("arch-photos",      .archive, "Photos-2024-vacation.zip",
       signals: ["succeeded"],
       tokens: ["photos", "vacation"]),
    nc("arch-music",       .archive, "old-music-collection.tar.gz",
       tokens: ["music", "collection"]),
    nc("arch-rand-pkg",    .archive, "random-package.dmg",
       tokens: ["package"]),

    // ── 归档内条目 (2) ──
    nc("entry-plan-swift", .archiveEntry, "SimpleZip/Core/AI/AIVirtualFolderPlan.swift",
       refs: [ref(.archiveEntry, "entry-plan-swift")],
       roles: ["source-archive"],
       signals: ["project-token", "same-parent"],
       archives: ["arch-source-tar"],
       tokens: ["simplezip", "swift", "ai"]),
    nc("entry-changelog",  .archiveEntry, "SimpleZip/CHANGELOG.md",
       refs: [ref(.archiveEntry, "entry-changelog")],
       roles: ["documentation"],
       signals: ["document", "same-parent"],
       archives: ["arch-source-tar"],
       tokens: ["changelog", "documentation"]),

    // ── 哈希任务 (6) → 应被折叠 ──
    nc("task-hash-arm64", .task, "SHA-256: arm64.dmg",
       refs: [ref(.task, "task-hash-arm64")],
       roles: ["task-summary"],
       signals: ["succeeded", "recent"],
       tasks: ["task-hash-arm64"],
       archives: ["arch-arm64-dmg"],
       tokens: ["hash", "sha256", "checksum"]),
    nc("task-hash-x86",   .task, "SHA-256: x86_64.dmg",
       refs: [ref(.task, "task-hash-x86")],
       signals: ["succeeded", "recent"],
       archives: ["arch-x86-dmg"],
       tokens: ["hash", "sha256"]),
    nc("task-hash-src",   .task, "SHA-256: source.tar.gz",
       refs: [ref(.task, "task-hash-src")],
       signals: ["succeeded", "recent"],
       archives: ["arch-source-tar"],
       tokens: ["hash", "sha256"]),
    nc("task-hash-0.4.4", .task, "SHA-256: 0.4.4.dmg",
       refs: [ref(.task, "task-hash-0.4.4")],
       signals: ["succeeded", "repeated"],
       archives: ["arch-0.4.4-dmg"],
       tokens: ["hash", "checksum"]),
    nc("task-hash-bak",   .task, "SHA-256: 0.4.3-backup.zip",
       refs: [ref(.task, "task-hash-bak")],
       signals: ["succeeded", "repeated"],
       archives: ["arch-0.4.3-bak"],
       tokens: ["hash", "md5"]),
    nc("task-hash-photos",.task, "SHA-256: vacation.zip",
       refs: [ref(.task, "task-hash-photos")],
       signals: ["succeeded", "repeated"],
       archives: ["arch-photos"],
       tokens: ["hash", "crc"]),

    // ── 签名任务 (3) ──
    nc("task-sign-arm64", .task, "GPG sign: arm64.dmg",
       refs: [ref(.task, "task-sign-arm64")],
       signals: ["succeeded", "recent-interaction", "project-token"],
       archives: ["arch-arm64-dmg"],
       tokens: ["sign", "gpg", "signature"]),
    nc("task-sign-x86",  .task, "GPG sign: x86_64.dmg",
       refs: [ref(.task, "task-sign-x86")],
       signals: ["succeeded", "recent-interaction"],
       archives: ["arch-x86-dmg"],
       tokens: ["sign", "gpg"]),
    nc("task-sign-src",  .task, "GPG sign: source.tar.gz",
       refs: [ref(.task, "task-sign-src")],
       signals: ["succeeded", "recent"],
       archives: ["arch-source-tar"],
       tokens: ["sign", "clearsign"]),

    // ── 完整性测试任务 (4) ──
    nc("task-test-arm64-FAIL", .task, "Integrity test: arm64.dmg [FAILED]",
       refs: [ref(.task, "task-test-arm64-FAIL")],
       signals: ["failed", "recent-interaction", "project-token"],
       archives: ["arch-arm64-dmg"],
       tokens: ["test", "integrity", "validate"]),
    nc("task-test-x86",  .task, "Integrity test: x86_64.dmg",
       refs: [ref(.task, "task-test-x86")],
       signals: ["succeeded"],
       archives: ["arch-x86-dmg"],
       tokens: ["test", "integrity"]),
    nc("task-test-src",  .task, "Integrity test: source.tar.gz",
       refs: [ref(.task, "task-test-src")],
       signals: ["succeeded"],
       archives: ["arch-source-tar"],
       tokens: ["verify", "integrity"]),
    nc("task-test-0.4.4",.task, "Integrity test: 0.4.4.dmg",
       refs: [ref(.task, "task-test-0.4.4")],
       signals: ["succeeded", "repeated"],
       archives: ["arch-0.4.4-dmg"],
       tokens: ["test", "validate"]),

    // ── 转换任务 (2) ──
    nc("task-conv-dmg",  .task, "Convert dmg → zip",
       refs: [ref(.task, "task-conv-dmg")],
       signals: ["succeeded", "recent"],
       archives: ["arch-arm64-dmg"],
       tokens: ["convert", "transform"]),
    nc("task-conv-tar",  .task, "Convert tar.gz → zip",
       refs: [ref(.task, "task-conv-tar")],
       signals: ["succeeded"],
       archives: ["arch-source-tar"],
       tokens: ["convert", "migrate"]),

    // ── 报告 (2) ──
    nc("rpt-release",    .report, "Release check · v0.4.5",
       refs: [ref(.report, "rpt-release")],
       signals: ["source-ref-match", "project-token", "recent-interaction"],
       tokens: ["release", "check", "simplezip"]),
    nc("rpt-test",       .report, "Archive integrity report · v0.4.5",
       refs: [ref(.report, "rpt-test")],
       signals: ["source-ref-match", "recent"],
       tokens: ["integrity", "report"]),

    // ── 文件 (5) ──
    nc("file-sha256sums", .file, "SHA256SUMS",
       refs: [ref(.file, "file-sha256sums")],
       signals: ["document", "project-token", "source-ref-match"],
       tokens: ["sha256", "checksum", "release"]),
    nc("file-changelog",  .file, "CHANGELOG.md",
       refs: [ref(.file, "file-changelog")],
       signals: ["document", "project-token"],
       tokens: ["changelog", "release"]),
    nc("file-security",   .file, "SECURITY.md",
       refs: [ref(.file, "file-security")],
       signals: ["document"],
       tokens: ["security"]),
    nc("file-readme",     .file, "README.md",
       refs: [ref(.file, "file-readme")],
       signals: ["document"],
       tokens: ["readme"]),
    nc("file-noise",      .file, "random-download.pkg",
       refs: [ref(.file, "file-noise")],
       tokens: ["package"]),
]

private let releaseStrongTokens = ["simplezip", "release", "0.4.5", "sign", "integrity"]

// MARK: - 真实工作区数据（来自 plist，4 个，全部 relevanceScore=0.6667）
// 基准时间：Date(timeIntervalSinceReferenceDate: 803295000) ≈ 2026-06-16

private let PLIST_REF = Date(timeIntervalSinceReferenceDate: 803295000)

private let realWorkspaces: [AIWorkspace] = [
    // title=前端配置与文件操作 opens=6 dwell=1266s rel=0.6667 lastOpen≈0.02d前
    AIWorkspace(id: UUID(uuidString: "7EDDCDAC-7FDD-CF3F-80DD-D0D281DDD265")!,
                origin: .recommended, title: "前端配置与文件操作",
                queryPlan: AIWorkspaceQueryPlan(), iconSystemName: "sparkles",
                pinned: false, generatedAt: Date(timeIntervalSinceReferenceDate: 803290884),
                lastOpenedAt: Date(timeIntervalSinceReferenceDate: 803293166),
                negativeFeedbackCount: 0, openCount: 6, relevanceScore: 0.6667,
                totalDwellSeconds: 1266),
    // title=智能卡读卡器项目 opens=6 dwell=747s rel=0.6667 lastOpen≈0.04d前
    AIWorkspace(id: UUID(uuidString: "CB5E989A-CC5E-9A2D-C95E-9574CA5E9707")!,
                origin: .recommended, title: "智能卡读卡器项目(A)",
                queryPlan: AIWorkspaceQueryPlan(), iconSystemName: "sparkles",
                pinned: false, generatedAt: Date(timeIntervalSinceReferenceDate: 803290884),
                lastOpenedAt: Date(timeIntervalSinceReferenceDate: 803291245),
                negativeFeedbackCount: 0, openCount: 6, relevanceScore: 0.6667,
                totalDwellSeconds: 747),
    // title=智能卡读卡器项目(重复!) opens=3 dwell=6s rel=0.6667 lastOpen≈0.02d前
    AIWorkspace(id: UUID(uuidString: "F2AF4AEA-F3AF-4C7D-F0AF-47C4F1AF4957")!,
                origin: .recommended, title: "智能卡读卡器项目(B)",
                queryPlan: AIWorkspaceQueryPlan(), iconSystemName: "sparkles",
                pinned: false, generatedAt: Date(timeIntervalSinceReferenceDate: 803290884),
                lastOpenedAt: Date(timeIntervalSinceReferenceDate: 803293163),
                negativeFeedbackCount: 0, openCount: 3, relevanceScore: 0.6667,
                totalDwellSeconds: 6),
    // title=身份配置与文档 opens=8 dwell=444s rel=0.6667 lastOpen≈0.02d前
    AIWorkspace(id: UUID(uuidString: "FFCFEDB7-FECF-EC24-01CF-F0DD00CFEF4A")!,
                origin: .recommended, title: "身份配置与文档",
                queryPlan: AIWorkspaceQueryPlan(), iconSystemName: "sparkles",
                pinned: false, generatedAt: Date(timeIntervalSinceReferenceDate: 803290884),
                lastOpenedAt: Date(timeIntervalSinceReferenceDate: 803293164),
                negativeFeedbackCount: 0, openCount: 8, relevanceScore: 0.6667,
                totalDwellSeconds: 444),
]

// MARK: - 真实活动任务候选（activityHistory 100条 采样30条）
// 种类: test=34, delete=24, hash=20, compress=6, undo=5, create=4, extract=3, move=2, compare=1, redo=1

private let realTaskPool: [AIVirtualNodeCandidate] = [
    // hash flood: 9 条哈希任务 → 应触发折叠（任务标题模式"的哈希"高度重复）
    nc("task-636b9917", .task, "正在计算 Cherry_KC_1000_SC_Z.txt 的哈希",
       refs: [ref(.task, "task-636b9917")], roles: ["hash-result"],
       signals: ["succeeded", "recent", "integrity"], tokens: ["hash", "readers"]),
    nc("task-20e9d8a4", .task, "正在计算 tsup.config.ts 的哈希",
       refs: [ref(.task, "task-20e9d8a4")], roles: ["hash-result"],
       signals: ["succeeded", "recent", "integrity"], tokens: ["hash", "config"]),
    nc("task-8309ac33", .task, "正在计算 config.h.in~ 的哈希",
       refs: [ref(.task, "task-8309ac33")], roles: ["hash-result"],
       signals: ["succeeded", "recent", "integrity"], tokens: ["hash", "config"]),
    nc("task-d5d95fd2", .task, "正在计算 Identiv_uTrust_3701_F_CL_Reader.txt 的哈希",
       refs: [ref(.task, "task-d5d95fd2")], roles: ["hash-result"],
       signals: ["succeeded", "recent", "integrity"], tokens: ["hash", "readers"]),
    nc("task-b945e447", .task, "正在计算 scardcontrol-PCSCv2part10.o 的哈希",
       refs: [ref(.task, "task-b945e447")], roles: ["hash-result"],
       signals: ["succeeded", "recent", "integrity"], tokens: ["hash", "scardcontrol"]),
    nc("task-38550c92", .task, "正在计算 scardcontrol-PCSCv2part10.o 的哈希",
       refs: [ref(.task, "task-38550c92")], roles: ["hash-result"],
       signals: ["succeeded", "recent", "integrity"], tokens: ["hash", "scardcontrol"]),
    nc("task-d92418b3", .task, "正在计算 HID_Global_veriCLASS_Reader.txt 的哈希",
       refs: [ref(.task, "task-d92418b3")], roles: ["hash-result"],
       signals: ["succeeded", "recent", "integrity"], tokens: ["hash", "readers"]),
    nc("task-215b67fd", .task, "正在计算 create_Info_plist.pl 的哈希",
       refs: [ref(.task, "task-215b67fd")], roles: ["hash-result"],
       signals: ["succeeded", "recent", "integrity"], tokens: ["hash", "create"]),
    nc("task-5e70fa67", .task, "正在计算 AGENTS.md 的哈希",
       refs: [ref(.task, "task-5e70fa67")], roles: ["hash-result"],
       signals: ["succeeded", "recent", "integrity"], tokens: ["hash"]),
    // compare: 1 条失败
    nc("task-22b91bd3", .task, "正在比较 … 与 ……",
       refs: [ref(.task, "task-22b91bd3")], roles: ["compare-result"],
       signals: ["failed", "recent", "compare"], tokens: ["compare"]),
    // test: 6 条
    nc("task-365289ba", .task, "正在检查 未命名.zip",
       refs: [ref(.task, "task-365289ba")], roles: ["test-result"],
       signals: ["succeeded", "test", "integrity"], tokens: ["test", "zip"]),
    nc("task-185d3a91", .task, "正在扫描重复归档：siz及szs测试文件",
       refs: [ref(.task, "task-185d3a91")], roles: ["test-result"],
       signals: ["succeeded", "test"], tokens: ["test", "scan", "archive"]),
    nc("task-c6636593", .task, "正在检查 simplezip-tar-zst-clean.tar.zst",
       refs: [ref(.task, "task-c6636593")], roles: ["test-result"],
       signals: ["succeeded", "test", "integrity"], tokens: ["simplezip", "test", "zip"]),
    nc("task-ae8c68f0", .task, "正在分析空间：simplezip-tar-zst.tar.zst",
       refs: [ref(.task, "task-ae8c68f0")], roles: ["test-result"],
       signals: ["succeeded", "test"], tokens: ["simplezip", "test", "zip"]),
    nc("task-26754bef", .task, "正在检查 SimpleZip-0.4.3-unsigned.dmg",
       refs: [ref(.task, "task-26754bef")], roles: ["test-result"],
       signals: ["succeeded", "test", "integrity"], tokens: ["simplezip", "dmg", "test"]),
    nc("task-7fed637b", .task, "正在体检 9 个归档",
       refs: [ref(.task, "task-7fed637b")], roles: ["test-result"],
       signals: ["succeeded", "test"], tokens: ["test", "archive"]),
    // extract: 2 条
    nc("task-86baece9", .task, "KeepingYouAwake-1.6.8.zip",
       refs: [ref(.task, "task-86baece9")], roles: ["extract-result"],
       signals: ["succeeded", "extract"], tokens: ["extract", "zip"]),
    nc("task-25bb16f4", .task, "logs_71068000183.zip",
       refs: [ref(.task, "task-25bb16f4")], roles: ["extract-result"],
       signals: ["succeeded", "extract"], tokens: ["extract", "zip"]),
    // hash (later): 3 条更旧的
    nc("task-48dddfb0", .task, "正在计算 simplezip-zst-test.txt.zst 的哈希",
       refs: [ref(.task, "task-48dddfb0")], roles: ["hash-result"],
       signals: ["succeeded", "integrity"], tokens: ["hash", "simplezip", "zip"]),
    nc("task-93b7c401", .task, "simplezip verify SHA256SUMS",
       refs: [ref(.task, "task-93b7c401")], roles: ["hash-result"],
       signals: ["succeeded", "integrity"], tokens: ["sha256", "simplezip", "hash"]),
    nc("task-94fa-hash", .task, "正在为 1 个文件生成 SHA256SUMS",
       refs: [ref(.task, "task-94fa-hash")], roles: ["hash-result"],
       signals: ["succeeded", "integrity"], tokens: ["sha256", "hash"]),
    // compress: 2 条
    nc("task-d786c8b1", .task, "正在创建 SimpleZip-Preferences-2026-06-13.zip",
       refs: [ref(.task, "task-d786c8b1")], roles: ["compress-result"],
       signals: ["succeeded", "compress"], tokens: ["simplezip", "zip", "compress"]),
    nc("task-d42c4be7", .task, "正在创建 minecraft.zip",
       refs: [ref(.task, "task-d42c4be7")], roles: ["compress-result"],
       signals: ["cancelled", "compress"], tokens: ["zip", "compress"]),
    // delete: 4 条
    nc("task-20bed34e", .task, "删除 1 项",
       refs: [ref(.task, "task-20bed34e")], roles: ["delete-result"],
       signals: ["succeeded", "delete"], tokens: ["delete"]),
    nc("task-ac1690a8", .task, "删除 1 项",
       refs: [ref(.task, "task-ac1690a8")], roles: ["delete-result"],
       signals: ["succeeded", "delete"], tokens: ["delete"]),
    nc("task-2a931d39", .task, "删除 40 项",
       refs: [ref(.task, "task-2a931d39")], roles: ["delete-result"],
       signals: ["succeeded", "delete"], tokens: ["delete"]),
    nc("task-3cb60dfe", .task, "删除 8 项",
       refs: [ref(.task, "task-3cb60dfe")], roles: ["delete-result"],
       signals: ["succeeded", "delete"], tokens: ["delete"]),
    // create / undo / misc
    nc("task-6f2d6e40", .task, "新建文件夹",
       refs: [ref(.task, "task-6f2d6e40")], roles: ["create-result"],
       signals: ["succeeded", "create"], tokens: ["create"]),
    nc("task-823f0ac9", .task, "已撤销：删除",
       refs: [ref(.task, "task-823f0ac9")], roles: ["undo-result"],
       signals: ["succeeded", "undoredo"], tokens: ["undo", "delete"]),
    nc("task-3caa7c34", .task, "发布助手：未命名文件夹.zip",
       refs: [ref(.task, "task-3caa7c34")], roles: ["create-result"],
       signals: ["succeeded", "create"], tokens: ["create", "zip"]),
]

// MARK: - 真实文件候选（fileMemoryIndex 1124条 按角色采样 25条）
// 角色分布: document=695(62%), source=93(8%), config=48(4%), media=42(4%), archive=35(3%), installer=3(<1%)

private let realFilePool: [AIVirtualNodeCandidate] = [
    // archive role (3条)
    nc("file-r001", .file, "未命名文件夹.szs",
       refs: [ref(.file, "file-r001")], roles: ["archive"],
       signals: ["loc-desktop"], tokens: ["szs", "desktop"]),
    nc("file-r002", .file, "篡改版szs.szs",
       refs: [ref(.file, "file-r002")], roles: ["archive"],
       signals: ["loc-desktop"], tokens: ["szs", "archive"]),
    nc("file-r003", .file, "minecraft-crash-info.zip",
       refs: [ref(.file, "file-r003")], roles: ["archive"],
       signals: ["loc-documents"], tokens: ["zip", "minecraft", "crash"]),
    // installer (3条)
    nc("file-r004", .file, "SimpleZip-0.4.3-unsigned.dmg",
       refs: [ref(.file, "file-r004")], roles: ["installer"],
       signals: ["loc-downloads"], tokens: ["simplezip", "dmg", "installer", "downloads"]),
    nc("file-r005", .file, "SimpleZip-0.4.2-unsigned.dmg",
       refs: [ref(.file, "file-r005")], roles: ["installer"],
       signals: ["loc-downloads"], tokens: ["simplezip", "dmg", "downloads"]),
    nc("file-r006", .file, "Keka-1.6.5.dmg",
       refs: [ref(.file, "file-r006")], roles: ["installer"],
       signals: ["loc-downloads"], tokens: ["keka", "dmg", "downloads"]),
    // source (5条)
    nc("file-r007", .file, "utils.c",
       refs: [ref(.file, "file-r007")], roles: ["source"],
       signals: ["loc-documents"], tokens: ["source", "utils", "src"]),
    nc("file-r008", .file, "misc.h",
       refs: [ref(.file, "file-r008")], roles: ["source"],
       signals: ["loc-documents"], tokens: ["source", "misc", "src"]),
    nc("file-r009", .file, "tsup.config.ts",
       refs: [ref(.file, "file-r009")], roles: ["source"],
       signals: ["loc-documents"], tokens: ["source", "config", "typescript"]),
    nc("file-r010", .file, "mainResourceAssertions.ts",
       refs: [ref(.file, "file-r010")], roles: ["source"],
       signals: ["loc-documents"], tokens: ["source", "test", "typescript"]),
    nc("file-r011", .file, "utils.h",
       refs: [ref(.file, "file-r011")], roles: ["source"],
       signals: ["loc-documents"], tokens: ["source", "utils", "src"]),
    // config (3条)
    nc("file-r012", .file, "package.json",
       refs: [ref(.file, "file-r012")], roles: ["config"],
       signals: ["loc-documents"], tokens: ["config", "json", "package"]),
    nc("file-r013", .file, "tsconfig.json",
       refs: [ref(.file, "file-r013")], roles: ["config"],
       signals: ["loc-documents"], tokens: ["config", "json", "typescript"]),
    nc("file-r014", .file, ".eslintrc.json",
       refs: [ref(.file, "file-r014")], roles: ["config"],
       signals: ["loc-documents"], tokens: ["config", "json", "eslint"]),
    // media (3条)
    nc("file-r015", .file, "127307860_p0.jpg",
       refs: [ref(.file, "file-r015")], roles: ["media"],
       signals: ["loc-documents"], tokens: ["media", "jpg", "image"]),
    nc("file-r016", .file, "8.png",
       refs: [ref(.file, "file-r016")], roles: ["media"],
       signals: ["loc-documents"], tokens: ["media", "png", "image"]),
    nc("file-r017", .file, "124509589_p0.png",
       refs: [ref(.file, "file-r017")], roles: ["media"],
       signals: ["loc-documents"], tokens: ["media", "png", "image"]),
    // document (8条 — 真实占比 62%)
    nc("file-r018", .file, "README.md",
       refs: [ref(.file, "file-r018")], roles: ["document"],
       signals: ["loc-documents"], tokens: ["document", "readme", "markdown"]),
    nc("file-r019", .file, "CHANGELOG.md",
       refs: [ref(.file, "file-r019")], roles: ["document"],
       signals: ["loc-documents"], tokens: ["document", "changelog", "simplezip"]),
    nc("file-r020", .file, "Regula_RFID_Reader.txt",
       refs: [ref(.file, "file-r020")], roles: ["document"],
       signals: ["loc-documents"], tokens: ["document", "readers", "rfid"]),
    nc("file-r021", .file, "Cherry_KC_1000_SC_Z.txt",
       refs: [ref(.file, "file-r021")], roles: ["document"],
       signals: ["loc-documents"], tokens: ["document", "readers", "cherry"]),
    nc("file-r022", .file, "GemPCTwin.txt",
       refs: [ref(.file, "file-r022")], roles: ["document"],
       signals: ["loc-documents"], tokens: ["document", "readers"]),
    nc("file-r023", .file, "Fujitsu_Smartcard_Reader_D323.txt",
       refs: [ref(.file, "file-r023")], roles: ["document"],
       signals: ["loc-documents"], tokens: ["document", "readers", "smartcard"]),
    nc("file-r024", .file, "HID_Global_veriCLASS_Reader.txt",
       refs: [ref(.file, "file-r024")], roles: ["document"],
       signals: ["loc-documents"], tokens: ["document", "readers", "hid"]),
    nc("file-r025", .file, "Identiv_uTrust_3701_F_CL_Reader.txt",
       refs: [ref(.file, "file-r025")], roles: ["document"],
       signals: ["loc-documents"], tokens: ["document", "readers", "identiv"]),
]

// 合并真实候选池
private let realPool: [AIVirtualNodeCandidate] = realTaskPool + realFilePool

// MARK: - 合成工作区

private let epoch = T0

private func ws(_ id: String, _ title: String,
                origin: AIWorkspace.Origin = .recommended,
                relevance: Double, opens: Int, dwellSec: Int,
                lastOpenDays: Double?, negFeedback: Int = 0,
                pinned: Bool = false) -> AIWorkspace {
    AIWorkspace(
        id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", abs(id.hashValue % 999999999999)))") ?? UUID(),
        origin: origin,
        title: title,
        queryPlan: AIWorkspaceQueryPlan(),
        iconSystemName: "folder",
        pinned: pinned,
        generatedAt: T(30),
        lastOpenedAt: lastOpenDays.map { T($0) },
        negativeFeedbackCount: negFeedback,
        openCount: opens,
        relevanceScore: relevance,
        totalDwellSeconds: dwellSec)
}

private let syntheticWorkspaces: [AIWorkspace] = [
    ws("A", "SimpleZip 发布准备",  relevance: 0.92, opens: 14, dwellSec: 4200, lastOpenDays: 0.5),
    ws("B", "旧版本归档",          relevance: 0.35, opens: 4,  dwellSec: 720,  lastOpenDays: 28),
    ws("C", "被反馈 2 次的主题",   relevance: 0.78, opens: 7,  dwellSec: 1800, lastOpenDays: 3, negFeedback: 2),
    ws("D", "新发现主题",          relevance: 0.65, opens: 1,  dwellSec: 90,   lastOpenDays: 0.8),
    ws("E", "低相关度陈旧",        relevance: 0.18, opens: 2,  dwellSec: 50,   lastOpenDays: 75),
    ws("F", "用户自建-从不用",  origin: .userCreated, relevance: 0, opens: 0, dwellSec: 0, lastOpenDays: nil),
    ws("G", "已固定置顶",          relevance: 0.4,  opens: 1,  dwellSec: 60,   lastOpenDays: 7, pinned: true),
]

// MARK: - 启动目录候选

private func sc(_ id: String, _ alias: String, visits: Int, dwell: Int,
                recency: Int, neg: Int = 0) -> AIStartupCandidate {
    AIStartupCandidate(sourceRef: ref(.folder, id), locationKind: "documents",
                       displayAlias: alias, visitsInSameBucket: visits,
                       medianDwellSeconds: dwell, recencyDays: recency, negativeSignalCount: neg)
}

private let startupCandidates: [AIStartupCandidate] = [
    sc("s1", "~/Documents/SimpleZip",  visits: 9,  dwell: 1800, recency: 1),
    sc("s2", "~/Downloads",            visits: 6,  dwell: 90,   recency: 2),
    sc("s3", "~/Projects/old-app",     visits: 3,  dwell: 600,  recency: 18),
    sc("s4", "~/Desktop",              visits: 7,  dwell: 60,   recency: 3, neg: 2),
    sc("s5", "~/Documents/photos",     visits: 1,  dwell: 300,  recency: 0),
    sc("s6", "~/Archives/2022",        visits: 11, dwell: 900,  recency: 40),
]

// MARK: - 动作卡候选

private let actionCandidates: [AIActionCandidate] = [
    AIActionCandidate(id: "testArchive",      safety: .safe),
    AIActionCandidate(id: "calculateHash",    safety: AISuggestionSafety(requiresConfirmation: true)),
    AIActionCandidate(id: "inspectRelease",   safety: AISuggestionSafety(requiresConfirmation: true)),
    AIActionCandidate(id: "convertArchive",   safety: AISuggestionSafety(requiresConfirmation: true)),
    AIActionCandidate(id: "createArchive",    safety: AISuggestionSafety(requiresConfirmation: true)),
]

private let actionUsage: [AIActionUsageSignal] = [
    AIActionUsageSignal(actionID: "testArchive",    clicked: 5, completed: 4, dismissed: 0, failed: 0),
    AIActionUsageSignal(actionID: "calculateHash",  clicked: 8, completed: 7, dismissed: 0, failed: 1),
    AIActionUsageSignal(actionID: "inspectRelease", clicked: 3, completed: 1, dismissed: 2, failed: 0),
    AIActionUsageSignal(actionID: "convertArchive", clicked: 2, completed: 0, dismissed: 4, failed: 1),
    AIActionUsageSignal(actionID: "createArchive",  clicked: 0, completed: 0, dismissed: 0, failed: 0),
]

// MARK: - 语义标签候选

private let tagCandidates: [AISemanticTagCandidate] = [
    AISemanticTagCandidate(tag: .releaseArtifact,    deterministicScore: 0.88),
    AISemanticTagCandidate(tag: .sourceArchive,      deterministicScore: 0.72),
    AISemanticTagCandidate(tag: .signedContainer,    deterministicScore: 0.65),
    AISemanticTagCandidate(tag: .backup,             deterministicScore: 0.40),
    AISemanticTagCandidate(tag: .documentation,      deterministicScore: 0.30),
]

// MARK: - 主题指纹（用于抑制测试）

private let fpRelease = AIWorkspaceThemeFingerprint(
    themeTokens: ["simplezip", "release", "dmg", "sign"],
    sourceRefHashes: ["h1", "h2", "h3"],
    dominantRoleTags: ["release-artifact", "signed-container"],
    locationKinds: ["documents", "downloads"])

private let fpSimilar = AIWorkspaceThemeFingerprint(
    themeTokens: ["simplezip", "release", "dmg"],
    sourceRefHashes: ["h1", "h2"],
    dominantRoleTags: ["release-artifact"],
    locationKinds: ["documents"])

private let fpUnrelated = AIWorkspaceThemeFingerprint(
    themeTokens: ["photos", "vacation", "jpg"],
    sourceRefHashes: ["h9", "h10"],
    dominantRoleTags: ["media-bundle"],
    locationKinds: ["pictures"])

// 真实抑制指纹（来自 plist，12 条）
private let fpRealUndoRedo = AIWorkspaceThemeFingerprint(
    themeTokens: ["fileoperation", "task", "undoredo", "删除", "已撤销"],
    sourceRefHashes: ["r001", "r002", "r003"],
    dominantRoleTags: ["fileoperation", "task", "undoredo"],
    locationKinds: ["desktop"])

private let fpRealMove = AIWorkspaceThemeFingerprint(
    themeTokens: ["fileoperation", "task", "移动"],
    sourceRefHashes: ["m001", "m002"],
    dominantRoleTags: ["fileoperation", "task"],
    locationKinds: ["desktop"])

private let fpRealHashDesktop = AIWorkspaceThemeFingerprint(
    themeTokens: ["desktop", "fileoperation", "task", "正在计算", "的哈希"],
    sourceRefHashes: ["d001", "d002", "d003", "d004"],
    dominantRoleTags: ["fileoperation", "task"],
    locationKinds: ["desktop"])

// MARK: - 打印工具

private func header(_ s: String) { print("\n=== \(s) ===") }
private func pad(_ s: String, _ w: Int) -> String {
    let count = s.unicodeScalars.count
    return count >= w ? s : s + String(repeating: " ", count: w - count)
}
private func row(_ label: String, _ value: String) { print("  \(pad(label, 36)) \(value)") }
private func row(_ label: String, _ value: Double)  { row(label, String(format: "%.4f", value)) }
private func row(_ label: String, _ value: Int)     { row(label, "\(value)") }
private func sep() { print("  " + String(repeating: "-", count: 50)) }

// MARK: - ════════════════════════════════════════════
//  SUITE
// ════════════════════════════════════════════════════

@Suite struct AIBenchmarkSweepTests {

    // MARK: ① Preparer — 多场景多参数

    @Test func benchmarkPreparer() {
        header("① AIVirtualFolderModelInputPreparer")

        struct Scenario {
            let name: String
            let candidates: [AIVirtualNodeCandidate]
            let strong: [String]
            let maxCandidates: Int
        }

        let scenarios: [Scenario] = [
            Scenario(name: "全量发布工作流  maxCand=28", candidates: releasePool, strong: releaseStrongTokens, maxCandidates: 28),
            Scenario(name: "全量发布工作流  maxCand=20", candidates: releasePool, strong: releaseStrongTokens, maxCandidates: 20),
            Scenario(name: "全量发布工作流  maxCand=14", candidates: releasePool, strong: releaseStrongTokens, maxCandidates: 14),
            Scenario(name: "全量发布工作流  maxCand=35", candidates: releasePool, strong: releaseStrongTokens, maxCandidates: 35),
            Scenario(name: "弱强信号 maxCand=28",        candidates: releasePool, strong: ["simplezip"], maxCandidates: 28),
            Scenario(name: "空强信号 maxCand=28",        candidates: releasePool, strong: [], maxCandidates: 28),
            Scenario(name: "纯归档无任务 maxCand=28",
                     candidates: releasePool.filter { $0.kind != .task },
                     strong: releaseStrongTokens, maxCandidates: 28),
            Scenario(name: "噪声主导 maxCand=28",
                     candidates: Array(releasePool.filter {
                         ["arch-photos","arch-music","arch-rand-pkg","file-noise","entry-changelog","entry-plan-swift","file-readme","file-security"].contains($0.id) }),
                     strong: releaseStrongTokens, maxCandidates: 28),
        ]

        print("\n  场景名                                 in  sup out  H   N  L  cov")
        print("  " + String(repeating: "─", count: 75))
        for sc in scenarios {
            let (_, m) = AIVirtualFolderModelInputPreparer.prepareWithMetrics(
                candidates: sc.candidates, strongTokens: sc.strong, maxCandidates: sc.maxCandidates)
            let h = m.tierCounts["high"] ?? 0
            let n = m.tierCounts["normal"] ?? 0
            let l = m.tierCounts["low"] ?? 0
            print("  \(pad(sc.name, 38)) \(String(format: "%3d %3d %3d %3d %3d %2d  %.2f", m.inputCount, m.suppressedCount, m.outputCount, h, n, l, m.strongTokenCoverage))")
        }

        let (_, baseline) = AIVirtualFolderModelInputPreparer.prepareWithMetrics(
            candidates: releasePool, strongTokens: releaseStrongTokens, maxCandidates: 28)
        #expect(baseline.strongTokenCoverage >= 0.5, "发布场景强信号覆盖率不达预期")
        #expect(baseline.suppressedCount >= 6, "哈希任务应至少抑制 6 条")

        header("① Preparer — 基准详情(maxCand=28, 全量)")
        row("inputCount",           baseline.inputCount)
        row("suppressedCount",      baseline.suppressedCount)
        row("outputCount",          baseline.outputCount)
        row("strongTokenCoverage",  baseline.strongTokenCoverage)
        row("tier[high]",           baseline.tierCounts["high"] ?? 0)
        row("tier[normal]",         baseline.tierCounts["normal"] ?? 0)
        row("tier[low]",            baseline.tierCounts["low"] ?? 0)
        for (k, v) in baseline.kindCounts.sorted(by: { $0.key < $1.key }) {
            row("kind[\(k)]", v)
        }
    }

    // MARK: ② Workspace Ranking — 当前参数 + 参数扫描

    @Test func benchmarkWorkspaceRanking() {
        header("② AIWorkspaceRanking — 当前参数")

        let wR = AIWorkspaceRanking.wRelevance
        let wF = AIWorkspaceRanking.wFrequency
        let wD = AIWorkspaceRanking.wDwell
        let wRec = AIWorkspaceRanking.wRecency
        let pen = AIWorkspaceRanking.feedbackPenalty
        let ub  = AIWorkspaceRanking.userBaseline
        let rHL = AIWorkspaceRanking.recencyHalfLifeDays

        print("\n  当前参数: wRelevance=\(wR) wFrequency=\(wF) wDwell=\(wD) wRecency=\(wRec) feedbackPenalty=\(pen) userBaseline=\(ub) recencyHL=\(rHL)d")
        print("\n  工作区名                               得分")
        print("  " + String(repeating: "─", count: 50))

        let ranked = AIWorkspaceRanking.rank(syntheticWorkspaces, now: T0)
        for ws in ranked {
            let s = AIWorkspaceRanking.score(ws, now: T0)
            print("  \(pad(ws.title, 38)) \(String(format: "%.4f%@", s, ws.pinned ? "  [pinned]" : ""))")
        }

        // 参数扫描
        struct WSProfile {
            let label: String
            let relevance: Double; let opens: Int; let dwellSec: Int
            let lastOpenDays: Double?; let negFeedback: Int
            let isUserCreated: Bool; let isPinned: Bool
        }
        let profiles: [WSProfile] = [
            WSProfile(label: "A-发布工作区(优)",    relevance: 0.92, opens: 14, dwellSec: 4200, lastOpenDays: 0.5, negFeedback: 0, isUserCreated: false, isPinned: false),
            WSProfile(label: "B-旧版陈旧(差)",      relevance: 0.35, opens: 4,  dwellSec: 720,  lastOpenDays: 28,  negFeedback: 0, isUserCreated: false, isPinned: false),
            WSProfile(label: "C-被排斥(负反馈×2)",  relevance: 0.78, opens: 7,  dwellSec: 1800, lastOpenDays: 3,   negFeedback: 2, isUserCreated: false, isPinned: false),
            WSProfile(label: "D-新发现(良)",         relevance: 0.65, opens: 1,  dwellSec: 90,   lastOpenDays: 0.8, negFeedback: 0, isUserCreated: false, isPinned: false),
            WSProfile(label: "E-低相关极旧(劣)",    relevance: 0.18, opens: 2,  dwellSec: 50,   lastOpenDays: 75,  negFeedback: 0, isUserCreated: false, isPinned: false),
        ]

        func sweepScore(p: WSProfile, wR: Double, wF: Double, wD: Double, wRec: Double,
                        ub: Double, pen: Double, dwellCap: Double, recHL: Double) -> Double {
            if p.isPinned { return 1000 }
            var s = wR * max(0, min(1, p.relevance))
            s += wF * log2(Double(max(0, p.opens)) + 1)
            s += wD * min(1.0, Double(p.dwellSec) / dwellCap)
            if let d = p.lastOpenDays { s += wRec * pow(0.5, d / recHL) }
            if p.isUserCreated { s += ub }
            s -= pen * Double(max(0, p.negFeedback))
            return s
        }

        struct ParamSet {
            let label: String
            let wR, wF, wD, wRec, ub, pen, dwellCap, recHL: Double
        }
        let paramSets: [ParamSet] = [
            ParamSet(label: "当前值",      wR: 5.0, wF: 1.5, wD: 2.0, wRec: 2.5, ub: 2.5, pen: 3.0, dwellCap: 1800, recHL: 7.0),
            ParamSet(label: "强相关重权",  wR: 6.0, wF: 1.0, wD: 1.5, wRec: 2.0, ub: 2.0, pen: 3.0, dwellCap: 1800, recHL: 7.0),
            ParamSet(label: "衰减加速",    wR: 5.0, wF: 1.5, wD: 2.0, wRec: 2.5, ub: 2.5, pen: 3.0, dwellCap: 1800, recHL: 3.5),
            ParamSet(label: "惩罚封顶",    wR: 5.0, wF: 1.5, wD: 2.0, wRec: 2.5, ub: 2.5, pen: 2.0, dwellCap: 1800, recHL: 7.0),
            ParamSet(label: "频率削弱",    wR: 5.0, wF: 0.8, wD: 2.5, wRec: 2.5, ub: 2.5, pen: 3.0, dwellCap: 3600, recHL: 7.0),
            ParamSet(label: "停留拉长上限",wR: 5.0, wF: 1.5, wD: 2.5, wRec: 2.5, ub: 2.5, pen: 3.0, dwellCap: 3600, recHL: 7.0),
        ]

        header("② WorkspaceRanking — 参数扫描（A优 vs E劣 的分差）")
        print("  " + pad("参数组", 20) + "  A优    E劣    分差")
        print("  " + String(repeating: "─", count: 50))
        for ps in paramSets {
            let sA = sweepScore(p: profiles[0], wR: ps.wR, wF: ps.wF, wD: ps.wD, wRec: ps.wRec, ub: ps.ub, pen: ps.pen, dwellCap: ps.dwellCap, recHL: ps.recHL)
            let sE = sweepScore(p: profiles[4], wR: ps.wR, wF: ps.wF, wD: ps.wD, wRec: ps.wRec, ub: ps.ub, pen: ps.pen, dwellCap: ps.dwellCap, recHL: ps.recHL)
            print("  \(pad(ps.label, 20))  \(String(format: "%5.2f  %5.2f  %5.2f", sA, sE, sA - sE))")
        }

        header("② WorkspaceRanking — 负反馈惩罚曲线（C工作区 relevance=0.78）")
        print("  feedbackCount   score(pen=3.0)  score(pen=2.0)  score(pen=1.5)")
        for n in [0, 1, 2, 3, 4, 5] {
            let p1 = sweepScore(p: WSProfile(label: "", relevance: 0.78, opens: 7, dwellSec: 1800, lastOpenDays: 3, negFeedback: n, isUserCreated: false, isPinned: false),
                                wR: 5, wF: 1.5, wD: 2, wRec: 2.5, ub: 2.5, pen: 3.0, dwellCap: 1800, recHL: 7)
            let p2 = sweepScore(p: WSProfile(label: "", relevance: 0.78, opens: 7, dwellSec: 1800, lastOpenDays: 3, negFeedback: n, isUserCreated: false, isPinned: false),
                                wR: 5, wF: 1.5, wD: 2, wRec: 2.5, ub: 2.5, pen: 2.0, dwellCap: 1800, recHL: 7)
            let p3 = sweepScore(p: WSProfile(label: "", relevance: 0.78, opens: 7, dwellSec: 1800, lastOpenDays: 3, negFeedback: n, isUserCreated: false, isPinned: false),
                                wR: 5, wF: 1.5, wD: 2, wRec: 2.5, ub: 2.5, pen: 1.5, dwellCap: 1800, recHL: 7)
            print(String(format: "  %-16d  %5.2f           %5.2f           %5.2f", n, p1, p2, p3))
        }

        header("② WorkspaceRanking — 最近度衰减曲线（A工作区 relevance=0.92）")
        print("  天数    wRec=2.5/HL=7   wRec=2.5/HL=14  wRec=3.0/HL=7")
        for d in [0.0, 1, 3, 7, 14, 21, 30, 60] {
            let base = WSProfile(label: "", relevance: 0.92, opens: 14, dwellSec: 4200, lastOpenDays: d, negFeedback: 0, isUserCreated: false, isPinned: false)
            let v1 = sweepScore(p: base, wR: 5, wF: 1.5, wD: 2, wRec: 2.5, ub: 2.5, pen: 3, dwellCap: 1800, recHL: 7)
            let v2 = sweepScore(p: base, wR: 5, wF: 1.5, wD: 2, wRec: 2.5, ub: 2.5, pen: 3, dwellCap: 1800, recHL: 14)
            let v3 = sweepScore(p: base, wR: 5, wF: 1.5, wD: 2, wRec: 3.0, ub: 2.5, pen: 3, dwellCap: 1800, recHL: 7)
            print(String(format: "  %-6.0f  %5.2f           %5.2f           %5.2f", d, v1, v2, v3))
        }
    }

    // MARK: ③ Startup Ranker — 参数扫描

    @Test func benchmarkStartupRanker() {
        header("③ AIStartupDirectoryRanker — 当前参数排名")

        let ranked = AIStartupDirectoryRanker.rank(startupCandidates)
        print("\n  别名                         visits  dwell  recency  neg   score")
        print("  " + String(repeating: "─", count: 68))
        for rc in ranked {
            let c = rc.candidate
            print("  \(pad(c.displayAlias, 28))  \(String(format: "%3d    %4d   %3d      %2d   %.4f", c.visitsInSameBucket, c.medianDwellSeconds, c.recencyDays, c.negativeSignalCount, rc.score))")
        }

        let best = AIStartupDirectoryRanker.bestMatch(startupCandidates)
        print("\n  bestMatch: \(best?.displayAlias ?? "nil (低于 minScore=4.0)")")

        func score(visits: Int, dwell: Int, recency: Int, neg: Int,
                   dwellCap: Double, recSlope: Double, negPen: Double) -> Double {
            let v = Double(visits)
            let d = min(1.0, Double(dwell) / dwellCap)
            let r = max(0.0, 1.0 - recSlope * Double(recency))
            let p = negPen * Double(neg)
            return v + d + r - p
        }

        header("③ StartupRanker — 参数扫描（6 候选排名稳定性）")
        struct SParam { let label: String; let dwellCap, recSlope, negPen: Double }
        let sparams: [SParam] = [
            SParam(label: "当前 dwellCap=600s slope=0.10 pen=2.0",  dwellCap: 600,  recSlope: 0.10, negPen: 2.0),
            SParam(label: "dwellCap=300s slope=0.10 pen=2.0",       dwellCap: 300,  recSlope: 0.10, negPen: 2.0),
            SParam(label: "dwellCap=1200s slope=0.10 pen=2.0",      dwellCap: 1200, recSlope: 0.10, negPen: 2.0),
            SParam(label: "dwellCap=600s slope=0.05 pen=2.0",       dwellCap: 600,  recSlope: 0.05, negPen: 2.0),
            SParam(label: "dwellCap=600s slope=0.15 pen=2.0",       dwellCap: 600,  recSlope: 0.15, negPen: 2.0),
            SParam(label: "dwellCap=600s slope=0.10 pen=3.0",       dwellCap: 600,  recSlope: 0.10, negPen: 3.0),
            SParam(label: "指数衰减 dwellCap=600s recHL=10d pen=2.0",dwellCap: 600,  recSlope: -1,   negPen: 2.0),
        ]

        let candProfiles: [(String, Int, Int, Int, Int)] = [
            ("SimpleZip工程",   9,  1800, 1, 0),
            ("Downloads",       6,  90,   2, 0),
            ("old-app(陈)",     3,  600, 18, 0),
            ("Desktop(被踩)",   7,  60,   3, 2),
            ("photos(1次)",     1,  300,  0, 0),
            ("Archive2022(旧)", 11, 900, 40, 0),
        ]

        print("\n  参数组                                SimpleZip   Down  old  Desk  photo  Arch22")
        print("  " + String(repeating: "─", count: 80))
        for sp in sparams {
            var vals: [String] = []
            for (_, v, d, r, n) in candProfiles {
                let s: Double
                if sp.recSlope < 0 {
                    let dw = min(1.0, Double(d) / sp.dwellCap)
                    let rec = pow(0.5, Double(r) / 10.0)
                    s = Double(v) + dw + rec - sp.negPen * Double(n)
                } else {
                    s = score(visits: v, dwell: d, recency: r, neg: n,
                              dwellCap: sp.dwellCap, recSlope: sp.recSlope, negPen: sp.negPen)
                }
                vals.append(String(format: "%5.2f", s))
            }
            print("  " + pad(sp.label, 42) + "  " + vals.joined(separator: "  "))
        }

        header("③ StartupRanker — minScore 阈值灵敏度")
        for ms in [3.0, 4.0, 5.0, 6.0] {
            let b = AIStartupDirectoryRanker.bestMatch(startupCandidates, minScore: ms)
            print(String(format: "  minScore=%.1f  bestMatch=%@", ms, b?.displayAlias ?? "nil"))
        }
    }

    // MARK: ④ Action Card Ranker — 参数扫描

    @Test func benchmarkActionCards() {
        header("④ AINextActionRanker — 当前参数排名")

        let cards = AINextActionRanker.rank(candidates: actionCandidates, usage: actionUsage, limit: 5)
        print("\n  actionID               score   reasons")
        print("  " + String(repeating: "─", count: 65))
        for c in cards {
            print("  " + pad(c.actionID, 22) + "  " + String(format: "%.4f", c.score) + "  " + c.reasons.joined(separator: ","))
        }

        func cardScore(index: Int, completed: Int, clicked: Int, dismissed: Int, failed: Int,
                       baseDec: Double, compBoost: Double, clickBoost: Double,
                       dismissPen: Double, failPen: Double, ceiling: Double, floor: Double) -> Double {
            let base = max(0.1, 1.0 - baseDec * Double(index))
            var u = compBoost * Double(completed) + clickBoost * Double(clicked)
                  - dismissPen * Double(dismissed) - failPen * Double(failed)
            u = min(ceiling, max(floor, u))
            return base + u
        }

        struct AParam {
            let label: String
            let baseDec, compBoost, clickBoost, dismissPen, failPen, ceiling, floor: Double
        }
        let aparams: [AParam] = [
            AParam(label: "当前 baseDec=0.08 comp=0.15 clk=0.05 dis=-0.10 fail=-0.08 ceil=0.6 fl=-0.5",
                   baseDec: 0.08, compBoost: 0.15, clickBoost: 0.05, dismissPen: 0.10, failPen: 0.08, ceiling: 0.6, floor: -0.5),
            AParam(label: "baseDec=0.05 comp=0.15(减缓基础衰减)",
                   baseDec: 0.05, compBoost: 0.15, clickBoost: 0.05, dismissPen: 0.10, failPen: 0.08, ceiling: 0.6, floor: -0.5),
            AParam(label: "compBoost=0.20(强化完成奖励)",
                   baseDec: 0.08, compBoost: 0.20, clickBoost: 0.05, dismissPen: 0.10, failPen: 0.08, ceiling: 0.8, floor: -0.5),
            AParam(label: "dismissPen=0.15(加强忽略惩罚)",
                   baseDec: 0.08, compBoost: 0.15, clickBoost: 0.05, dismissPen: 0.15, failPen: 0.12, ceiling: 0.6, floor: -0.6),
            AParam(label: "ceiling=0.8 floor=-0.6(拓宽范围)",
                   baseDec: 0.08, compBoost: 0.15, clickBoost: 0.05, dismissPen: 0.10, failPen: 0.08, ceiling: 0.8, floor: -0.6),
        ]

        let aUsageData: [(String, Int, Int, Int, Int, Int)] = [
            ("testArchive",    0, 5, 4, 0, 0),
            ("calculateHash",  1, 8, 7, 0, 1),
            ("inspectRelease", 2, 3, 1, 2, 0),
            ("convertArchive", 3, 2, 0, 4, 1),
            ("createArchive",  4, 0, 0, 0, 0),
        ]

        header("④ ActionCards — 参数扫描（各动作得分）")
        print("  " + pad("参数组", 52) + "  test  hash  inspect  convert  create")
        print("  " + String(repeating: "─", count: 80))
        for ap in aparams {
            var vals: [String] = []
            for (_, idx, clk, comp, dis, fail) in aUsageData {
                let s = cardScore(index: idx, completed: comp, clicked: clk,
                                  dismissed: dis, failed: fail,
                                  baseDec: ap.baseDec, compBoost: ap.compBoost,
                                  clickBoost: ap.clickBoost, dismissPen: ap.dismissPen,
                                  failPen: ap.failPen, ceiling: ap.ceiling, floor: ap.floor)
                vals.append(String(format: "%.2f", s))
            }
            print("  " + pad(String(ap.label.prefix(51)), 52) + "  " + vals.joined(separator: "  "))
        }

        header("④ ActionCards — test(优) vs convert(劣) 分差扫描")
        print("  " + pad("参数组", 52) + "  分差")
        print("  " + String(repeating: "─", count: 65))
        for ap in aparams {
            let sT = cardScore(index: 0, completed: 4, clicked: 5, dismissed: 0, failed: 0,
                               baseDec: ap.baseDec, compBoost: ap.compBoost, clickBoost: ap.clickBoost,
                               dismissPen: ap.dismissPen, failPen: ap.failPen, ceiling: ap.ceiling, floor: ap.floor)
            let sC = cardScore(index: 3, completed: 0, clicked: 2, dismissed: 4, failed: 1,
                               baseDec: ap.baseDec, compBoost: ap.compBoost, clickBoost: ap.clickBoost,
                               dismissPen: ap.dismissPen, failPen: ap.failPen, ceiling: ap.ceiling, floor: ap.floor)
            print("  \(pad(String(ap.label.prefix(51)), 52))  \(String(format: "%.4f", sT - sC))")
        }
    }

    // MARK: ⑤ SemanticTag Ranker — 正负反馈扫描

    @Test func benchmarkSemanticTagRanker() {
        header("⑤ AISemanticTagRanker — 当前参数排名（无反馈）")
        let baseRanked = AISemanticTagRanker.rank(tagCandidates)
        print("\n  tag                    score")
        print("  " + String(repeating: "─", count: 40))
        for c in baseRanked {
            print("  \(pad(c.tag.rawValue, 22))  \(String(format: "%.4f", c.deterministicScore))")
        }

        func effectiveScore(score: Double, negHits: Int, posHits: Int,
                            decayPerNeg: Double, boostPerPos: Double,
                            negCap: Int, posCap: Int) -> Double {
            let n = min(max(negHits, 0), negCap)
            let p = min(max(posHits, 0), posCap)
            return score - decayPerNeg * Double(n) + boostPerPos * Double(p)
        }

        struct TPParam {
            let label: String; let decPerNeg, boostPerPos: Double; let negCap, posCap: Int
        }
        let tparams: [TPParam] = [
            TPParam(label: "当前 decNeg=0.15 boostPos=0.10 negCap=5 posCap=5",
                    decPerNeg: 0.15, boostPerPos: 0.10, negCap: 5, posCap: 5),
            TPParam(label: "decNeg=0.20 boostPos=0.10(加强负衰减)",
                    decPerNeg: 0.20, boostPerPos: 0.10, negCap: 5, posCap: 5),
            TPParam(label: "decNeg=0.15 boostPos=0.15(正负对称)",
                    decPerNeg: 0.15, boostPerPos: 0.15, negCap: 5, posCap: 5),
            TPParam(label: "negCap=3 posCap=3(收紧)",
                    decPerNeg: 0.15, boostPerPos: 0.10, negCap: 3, posCap: 3),
        ]

        header("⑤ SemanticTag — releaseArtifact(0.88) 负反馈降权曲线")
        print("  " + pad("参数组", 42) + "  neg=0  neg=1  neg=2  neg=3  neg=5")
        print("  " + String(repeating: "─", count: 80))
        for tp in tparams {
            var vals: [String] = []
            for neg in [0, 1, 2, 3, 5] {
                let s = effectiveScore(score: 0.88, negHits: neg, posHits: 0,
                                       decayPerNeg: tp.decPerNeg, boostPerPos: tp.boostPerPos,
                                       negCap: tp.negCap, posCap: tp.posCap)
                vals.append(String(format: "%.3f", s))
            }
            print("  " + pad(String(tp.label.prefix(41)), 42) + "  " + vals.joined(separator: "  "))
        }

        header("⑤ SemanticTag — backup(0.40) 正反馈提升曲线")
        print("  " + pad("参数组", 42) + "  pos=0  pos=1  pos=2  pos=3  pos=5")
        print("  " + String(repeating: "─", count: 80))
        for tp in tparams {
            var vals: [String] = []
            for pos in [0, 1, 2, 3, 5] {
                let s = effectiveScore(score: 0.40, negHits: 0, posHits: pos,
                                       decayPerNeg: tp.decPerNeg, boostPerPos: tp.boostPerPos,
                                       negCap: tp.negCap, posCap: tp.posCap)
                vals.append(String(format: "%.3f", s))
            }
            print("  \(pad(String(tp.label.prefix(41)), 42))  \(vals.joined(separator: "  "))")
        }

        header("⑤ SemanticTag — 交叉场景：releaseArtifact(neg×3) vs backup(pos×3)")
        for tp in tparams {
            let ra = effectiveScore(score: 0.88, negHits: 3, posHits: 0,
                                    decayPerNeg: tp.decPerNeg, boostPerPos: tp.boostPerPos,
                                    negCap: tp.negCap, posCap: tp.posCap)
            let bk = effectiveScore(score: 0.40, negHits: 0, posHits: 3,
                                    decayPerNeg: tp.decPerNeg, boostPerPos: tp.boostPerPos,
                                    negCap: tp.negCap, posCap: tp.posCap)
            print("  " + pad(String(tp.label.prefix(41)), 42) + "  " + String(format: "releaseArtifact=%.3f  backup=%.3f", ra, bk) + "  " + (ra > bk ? "releaseArtifact↑" : "backup↑"))
        }
    }

    // MARK: ⑥ Theme Suppression — 衰减曲线 + 相似度矩阵

    @Test func benchmarkThemeSuppression() {
        header("⑥ AIThemeSuppressionPolicy — 衰减曲线")

        print("\n  (first dismiss → weight over time)")
        print("  " + pad("天数", 10) + "  " + [1,2,3].map { "count=\($0)" }.joined(separator: "        "))
        print("  " + String(repeating: "─", count: 65))

        for dayVal in [0.0, 1, 3, 7, 14, 21, 30, 60, 90] {
            let now = T0.addingTimeInterval(dayVal * 86_400)
            var vals: [String] = []
            for cnt in [1, 2, 3] {
                let rec = AIThemeDismissalRecord(
                    fingerprint: fpRelease,
                    firstDismissedAt: T0, lastDismissedAt: T0, dismissCount: cnt)
                let w = AIThemeSuppressionPolicy.weight(of: rec, now: now)
                vals.append(String(format: "%7.4f", w))
            }
            print(String(format: "  %-10.0f  %@", dayVal, vals.joined(separator: "  ")))
        }

        print(String(format: "\n  穿越 resurfaceFloor(%.2f) 的天数：",
                     AIThemeSuppressionPolicy.resurfaceFloor))
        for cnt in [1, 2, 3] {
            let rec = AIThemeDismissalRecord(fingerprint: fpRelease, firstDismissedAt: T0, lastDismissedAt: T0, dismissCount: cnt)
            var crossDay = 0
            for d in stride(from: 0.0, through: 365, by: 1) {
                let now = T0.addingTimeInterval(d * 86_400)
                if AIThemeSuppressionPolicy.weight(of: rec, now: now) < AIThemeSuppressionPolicy.resurfaceFloor {
                    crossDay = Int(d); break
                }
            }
            print(String(format: "    count=%d → 约 %d 天后重新浮现", cnt, crossDay))
        }

        header("⑥ ThemeSuppression — 相似度矩阵")
        let fps: [(String, AIWorkspaceThemeFingerprint)] = [
            ("fpRelease", fpRelease), ("fpSimilar", fpSimilar), ("fpUnrelated", fpUnrelated),
        ]
        print("  " + pad("", 12) + "  " + fps.map { String($0.0.prefix(10)) }.joined(separator: "  "))
        for (na, fa) in fps {
            var rowVals: [String] = []
            for (_, fb) in fps {
                rowVals.append(String(format: "%-10.4f", AIThemeSuppressionPolicy.similarity(fa, fb)))
            }
            print("  " + pad(na, 12) + "  " + rowVals.joined(separator: "  "))
        }

        header("⑥ ThemeSuppression — matchThreshold 灵敏度（fpRelease vs fpSimilar sim=?）")
        let sim = AIThemeSuppressionPolicy.similarity(fpRelease, fpSimilar)
        print(String(format: "  fpRelease↔fpSimilar similarity = %.4f", sim))
        for th in [0.30, 0.40, 0.50, 0.60, 0.70] {
            print(String(format: "  threshold=%.2f → 两指纹%@匹配", th, sim >= th ? "" : " 不"))
        }
    }

    // MARK: ⑦ LearningStore — 反馈衰减曲线

    @Test func benchmarkLearningStore() {
        header("⑦ AIWorkspaceLearningStore — 反馈衰减曲线")

        let wsID = UUID()
        let halfLife = AIWorkspaceLearningStore.feedbackHalfLifeDays

        print("\n  信号加 -4.0（强不喜欢），时间衰减（halfLife=\(Int(halfLife))天）")
        print("  " + pad("天数", 8) + "  rawAffinity  weightedAffinity  isStronglyDisliked")
        print("  " + String(repeating: "─", count: 60))
        let sNeg = AIWorkspaceLearningStore().recording(wsID, signals: ["release-artifact"], by: -4.0, at: T0)
        for d in [0.0, 7, 14, 21, 30, 45, 60, 90] {
            let now = T0.addingTimeInterval(d * 86_400)
            let raw = sNeg.affinity(wsID, signals: ["release-artifact"])
            let w   = sNeg.weightedAffinity(wsID, signals: ["release-artifact"], now: now)
            let dis = sNeg.isStronglyDisliked(wsID, signals: ["release-artifact"], now: now)
            print(String(format: "  %-8.0f  %.4f       %.4f             %@", d, raw, w, dis ? "true" : "false"))
        }

        header("⑦ LearningStore — 正向反馈叠加")
        print("\n  重复 +1.0 信号，验证 cap 和多信号叠加")
        var acc = AIWorkspaceLearningStore()
        for i in 1...7 {
            acc = acc.reinforcing(wsID, signals: ["source-archive", "release-artifact"], by: 1.0)
            let af = acc.affinity(wsID, signals: ["source-archive", "release-artifact"])
            print(String(format: "  round %d: affinity(2-signal)=%.2f", i, af))
        }

        header("⑦ LearningStore — halfLife 参数对收敛影响")
        let sigNeg4 = AIWorkspaceLearningStore().recording(wsID, signals: ["x"], by: -4.0, at: T0)
        print("  " + pad("天数", 8) + "  HL=30d  HL=14d  HL=60d")
        for d in [0.0, 7, 14, 30, 60, 90] {
            let w30 = sigNeg4.affinity(wsID, signals: ["x"]) * pow(0.5, d / 30.0)
            let w14 = sigNeg4.affinity(wsID, signals: ["x"]) * pow(0.5, d / 14.0)
            let w60 = sigNeg4.affinity(wsID, signals: ["x"]) * pow(0.5, d / 60.0)
            print(String(format: "  %-8.0f  %.3f    %.3f    %.3f", d, w30, w14, w60))
        }
    }

    // MARK: ⑧ ThemeEngine — 聚类质量

    @Test func benchmarkThemeEngine() {
        header("⑧ AIWorkspaceThemeEngine — 聚类质量（发布工作流池 33候选）")

        let themes = AIWorkspaceThemeEngine.discoverThemes(
            from: releasePool, attention: AIAttentionContext(), now: T0)

        print("\n  发现主题数: \(themes.count)")
        print("  " + pad("titleSeed", 36) + "  signals  tokens")
        print("  " + String(repeating: "─", count: 60))
        for th in themes {
            print("  " + pad(String(th.titleSeed.prefix(35)), 36) + "  " + String(format: "%-7d", th.scoreSignals.count) + "  " + th.themeTokens.prefix(5).joined(separator: ","))
        }

        header("⑧ ThemeEngine — tokenOverlapThreshold 灵敏度")
        for thr in [0.20, 0.25, 0.30, 0.34, 0.40, 0.50] {
            let t = AIWorkspaceThemeEngine.discoverThemes(
                from: releasePool, attention: AIAttentionContext(), now: T0,
                tokenOverlapThreshold: thr)
            print(String(format: "  threshold=%.2f → %d 主题", thr, t.count))
        }

        header("⑧ ThemeEngine — minClusterSize 灵敏度")
        for sz in [2, 3, 4, 5] {
            let t = AIWorkspaceThemeEngine.discoverThemes(
                from: releasePool, attention: AIAttentionContext(), now: T0,
                minClusterSize: sz)
            print(String(format: "  minClusterSize=%d → %d 主题", sz, t.count))
        }

        header("⑧ ThemeEngine — maxTokenBucket 灵敏度")
        for mb in [20, 40, 80, 120] {
            let t = AIWorkspaceThemeEngine.discoverThemes(
                from: releasePool, attention: AIAttentionContext(), now: T0,
                maxTokenBucket: mb)
            print(String(format: "  maxTokenBucket=%d → %d 主题", mb, t.count))
        }
    }

    // MARK: ⑨ 综合质量评分（合成数据汇总）

    @Test func benchmarkQualitySummary() {
        header("⑨ 综合质量汇总（合成数据，当前参数）")

        let (_, m) = AIVirtualFolderModelInputPreparer.prepareWithMetrics(
            candidates: releasePool, strongTokens: releaseStrongTokens, maxCandidates: 28)
        let coverageOK = m.strongTokenCoverage >= 0.75
        print(String(format: "  Preparer strongTokenCoverage=%.2f  %@", m.strongTokenCoverage,
                     coverageOK ? "✓ ≥0.75" : "✗ <0.75"))

        let sA = AIWorkspaceRanking.score(syntheticWorkspaces[0], now: T0)
        let sE = AIWorkspaceRanking.score(syntheticWorkspaces[4], now: T0)
        let gapOK = (sA - sE) >= 8.0
        print(String(format: "  WorkspaceRanking A优=%.2f E劣=%.2f gap=%.2f  %@",
                     sA, sE, sA - sE, gapOK ? "✓ ≥8.0" : "✗ <8.0"))

        let best = AIStartupDirectoryRanker.bestMatch(startupCandidates)
        let bmOK = best?.displayAlias == "~/Documents/SimpleZip"
        print("  StartupRanker bestMatch=\(best?.displayAlias ?? "nil")  \(bmOK ? "✓" : "✗ 应为 ~/Documents/SimpleZip")")

        let rec1 = AIThemeDismissalRecord(fingerprint: fpRelease, firstDismissedAt: T0, lastDismissedAt: T0, dismissCount: 1)
        let w7 = AIThemeSuppressionPolicy.weight(of: rec1, now: T0.addingTimeInterval(7 * 86_400))
        let hlOK = abs(w7 - 0.3) < 0.05
        print(String(format: "  ThemeSuppression weight@7d=%.4f  %@", w7, hlOK ? "✓ ≈0.30" : "✗ 偏离预期"))

        let lsID = UUID()
        let lsRec = AIWorkspaceLearningStore().recording(lsID, signals: ["x"], by: -4.0, at: T0)
        let ws30 = lsRec.weightedAffinity(lsID, signals: ["x"], now: T0.addingTimeInterval(30 * 86_400))
        let lsOK = abs(ws30 - (-2.0)) < 0.1
        print(String(format: "  LearningStore weightedAffinity@30d=%.4f  %@",
                     ws30, lsOK ? "✓ ≈-2.0" : "✗ 衰减异常"))

        let cards = AINextActionRanker.rank(candidates: actionCandidates, usage: actionUsage, limit: 5)
        let topAction = cards.first?.actionID ?? "?"
        let acOK = (topAction == "testArchive" || topAction == "calculateHash")
        print("  ActionCard top=\(topAction)  \(acOK ? "✓" : "✗ 预期 testArchive 或 calculateHash")")
    }

    // MARK: ⑩ 真实 plist 数据基准

    @Test func benchmarkRealData() {
        header("⑩ 真实数据基准 — 来自 yumeka.SimpleZip-in-mac.plist")

        // ─── ⑩-A 真实工作区排名 ─────────────────────────────────────────────
        header("⑩-A 真实工作区排名（4 个，评分时间=PLIST_REF）")
        print("\n  【关键发现】所有工作区 relevanceScore = 0.6667（2/3 均值），wRelevance=5.0 贡献完全相同 3.33 分")
        print("  区分度 100% 来自 openCount / dwell / recency 三项\n")

        let realRanked = AIWorkspaceRanking.rank(realWorkspaces, now: PLIST_REF)
        let scores = realWorkspaces.map { AIWorkspaceRanking.score($0, now: PLIST_REF) }
        let scoreMin = scores.min() ?? 0
        let scoreMax = scores.max() ?? 0

        print("  " + pad("title", 30) + "  opens  dwell    lastOpen   score")
        print("  " + String(repeating: "─", count: 70))
        for ws in realRanked {
            let s = AIWorkspaceRanking.score(ws, now: PLIST_REF)
            let daysAgo = ws.lastOpenedAt.map {
                PLIST_REF.timeIntervalSince($0) / 86_400
            } ?? -1
            print("  \(pad(String(ws.title.prefix(29)), 30))  \(String(format: "%5d  %5ds   %.2fd前     %.4f", ws.openCount, ws.totalDwellSeconds, daysAgo, s))")
        }
        print(String(format: "\n  得分范围: %.2f ~ %.2f  分差: %.2f", scoreMin, scoreMax, scoreMax - scoreMin))
        print(String(format: "  注：wRelevance*0.6667 = %.4f（固定贡献）", 5.0 * 0.6667))

        // 如果 relevanceScore 能区分（假设 0.3-0.9 分布），得分差将如何变化
        print("\n  【模拟】若 relevanceScore 能区分（0.30~0.92），当前参数下分差扩展为：")
        let relSimScores: [(String, Double)] = [
            ("rel=0.92 (高强主题)", 5.0 * 0.92),
            ("rel=0.67 (当前均值)", 5.0 * 0.67),
            ("rel=0.35 (弱主题)",   5.0 * 0.35),
            ("rel=0.10 (几乎无关)", 5.0 * 0.10),
        ]
        for (label, contrib) in relSimScores {
            print("    \(pad(label, 28)) \(String(format: "wRelevance贡献=%.2f", contrib))")
        }

        // ─── ⑩-B 真实任务候选 Preparer ──────────────────────────────────────
        header("⑩-B 真实任务候选 Preparer（30条任务 + 25条文件 = 55候选）")

        let realStrongTokens = ["hash", "test", "integrity", "simplezip"]
        let (_, realMetrics) = AIVirtualFolderModelInputPreparer.prepareWithMetrics(
            candidates: realPool, strongTokens: realStrongTokens, maxCandidates: 28)

        row("inputCount (realPool)",    realMetrics.inputCount)
        row("suppressedCount",          realMetrics.suppressedCount)
        row("outputCount",              realMetrics.outputCount)
        row("strongTokenCoverage",      realMetrics.strongTokenCoverage)
        row("tier[high]",               realMetrics.tierCounts["high"] ?? 0)
        row("tier[normal]",             realMetrics.tierCounts["normal"] ?? 0)
        row("tier[low]",                realMetrics.tierCounts["low"] ?? 0)
        for (k, v) in realMetrics.kindCounts.sorted(by: { $0.key < $1.key }) {
            row("kind[\(k)]", v)
        }

        print("\n  真实 hash flood 场景（9条哈希 → 应折叠）:")
        let hashCandidates = realTaskPool.filter { $0.semanticTokens.contains("hash") }
        let (_, hashM) = AIVirtualFolderModelInputPreparer.prepareWithMetrics(
            candidates: hashCandidates, strongTokens: ["hash"], maxCandidates: 28)
        print(String(format: "    hash候选数=%d  折叠后=%d  suppressed=%d",
                     hashM.inputCount, hashM.outputCount, hashM.suppressedCount))

        // ─── ⑩-C 真实主题发现 ───────────────────────────────────────────────
        header("⑩-C 真实候选池主题发现（55候选，threshold=0.34）")

        let realThemes = AIWorkspaceThemeEngine.discoverThemes(
            from: realPool, attention: AIAttentionContext(), now: PLIST_REF)

        print("\n  发现主题数: \(realThemes.count)（真实数据，无合成场景偏向）")
        print("  " + pad("titleSeed", 36) + "  members  tokens")
        print("  " + String(repeating: "─", count: 65))
        for th in realThemes {
            print("  " + pad(String(th.titleSeed.prefix(35)), 36) + "  " + String(format: "%7d", th.scoreSignals.count) + "  " + th.themeTokens.prefix(5).joined(separator: ","))
        }

        // threshold sweep on real data
        print("\n  tokenOverlapThreshold 对真实数据的影响:")
        for thr in [0.20, 0.25, 0.30, 0.34, 0.40, 0.50] {
            let t = AIWorkspaceThemeEngine.discoverThemes(
                from: realPool, attention: AIAttentionContext(), now: PLIST_REF,
                tokenOverlapThreshold: thr)
            print(String(format: "    threshold=%.2f → %d 主题", thr, t.count))
        }

        // ─── ⑩-D 真实抑制记录（12条，均约0.42天前）─────────────────────────
        header("⑩-D 真实抑制记录衰减（真实指纹，timestamp=约0.42天前）")

        let suppressedAt = PLIST_REF.addingTimeInterval(-0.42 * 86_400)
        let realRecs: [(String, AIThemeDismissalRecord)] = [
            ("undo/redo操作主题 cnt=1",
             AIThemeDismissalRecord(fingerprint: fpRealUndoRedo,
                                    firstDismissedAt: suppressedAt,
                                    lastDismissedAt: suppressedAt,
                                    dismissCount: 1)),
            ("移动操作主题 cnt=2",
             AIThemeDismissalRecord(fingerprint: fpRealMove,
                                    firstDismissedAt: suppressedAt,
                                    lastDismissedAt: suppressedAt,
                                    dismissCount: 2)),
            ("Desktop哈希主题 cnt=1",
             AIThemeDismissalRecord(fingerprint: fpRealHashDesktop,
                                    firstDismissedAt: suppressedAt,
                                    lastDismissedAt: suppressedAt,
                                    dismissCount: 1)),
        ]

        print("  " + pad("记录", 28) + "  @0.42d   @1d    @3d    @7d    @14d   @30d")
        print("  " + String(repeating: "─", count: 75))
        for (label, rec) in realRecs {
            var vals: [String] = []
            for dayOffset in [0.42, 1.0, 3.0, 7.0, 14.0, 30.0] {
                let now = PLIST_REF.addingTimeInterval((dayOffset - 0.42) * 86_400)
                vals.append(String(format: "%.4f", AIThemeSuppressionPolicy.weight(of: rec, now: now)))
            }
            print("  " + pad(String(label.prefix(27)), 28) + "  " + vals.joined(separator: "  "))
        }

        // ─── ⑩-E 学习存储空白基线 ───────────────────────────────────────────
        header("⑩-E 学习存储（plist SimpleZip.ai.learning.v1 = {\"weights\":[]} 空）")
        print("  当前 learning store 为空，无真实反馈数据可测。")
        print("  模拟：若用户对 hash/test 任务做 -3 次不喜欢，对 simplezip 相关 +2 次喜欢：")

        let lsID1 = UUID()
        var lsSim = AIWorkspaceLearningStore()
        lsSim = lsSim.recording(lsID1, signals: ["hash", "integrity"], by: -1.0, at: suppressedAt)
        lsSim = lsSim.recording(lsID1, signals: ["hash", "integrity"], by: -1.0, at: PLIST_REF.addingTimeInterval(-0.3 * 86_400))
        lsSim = lsSim.recording(lsID1, signals: ["hash", "integrity"], by: -1.0, at: PLIST_REF.addingTimeInterval(-0.1 * 86_400))
        lsSim = lsSim.recording(lsID1, signals: ["simplezip", "installer"], by: 1.0, at: PLIST_REF.addingTimeInterval(-0.2 * 86_400))
        lsSim = lsSim.recording(lsID1, signals: ["simplezip", "installer"], by: 1.0, at: PLIST_REF.addingTimeInterval(-0.05 * 86_400))

        let rawHash = lsSim.affinity(lsID1, signals: ["hash", "integrity"])
        let rawSimplezip = lsSim.affinity(lsID1, signals: ["simplezip", "installer"])
        let wHash = lsSim.weightedAffinity(lsID1, signals: ["hash", "integrity"], now: PLIST_REF)
        let wSimplezip = lsSim.weightedAffinity(lsID1, signals: ["simplezip", "installer"], now: PLIST_REF)
        let isHashDisliked = lsSim.isStronglyDisliked(lsID1, signals: ["hash", "integrity"], now: PLIST_REF)

        print(String(format: "  hash+integrity:    raw=%.2f  weighted=%.4f  isStronglyDisliked=%@",
                     rawHash, wHash, isHashDisliked ? "true" : "false"))
        print(String(format: "  simplezip+install: raw=%.2f  weighted=%.4f",
                     rawSimplezip, wSimplezip))
        print(String(format: "  strongNegative阈值=%.1f  实际hash亲和=%.4f → %@排斥",
                     AIWorkspaceLearningStore.strongNegative, wHash,
                     isHashDisliked ? "已触发" : "未触发"))

        // ─── ⑩-F 文件角色分布评估 ──────────────────────────────────────────
        header("⑩-F 真实文件角色分布（fileMemoryIndex 1124条）")
        print("  角色分布（来自 plist 实测）:")
        let roleDist: [(String, Int, Double)] = [
            ("document",   695, 695.0/1124),
            ("source",      93, 93.0/1124),
            ("config",      48, 48.0/1124),
            ("media",       42, 42.0/1124),
            ("archive",     35, 35.0/1124),
            ("installer",    3, 3.0/1124),
            ("无角色(空)",  208, 208.0/1124),
        ]
        for (role, count, pct) in roleDist {
            let bar = String(repeating: "█", count: Int(pct * 40))
            print("  \(pad(role, 14)) \(String(format: "%4d (%4.1f%%)", count, pct*100)) \(bar)")
        }
        print("\n  【关键发现】62% 文件为纯 'document' 角色，信号区分度极低")
        print("  只有 3 个 installer 文件（占 0.27%），semantic tag 对 installer 召回率存在结构性风险")
    }

    // MARK: ⓪ benchmarkMetrics — 可解析指标输出（供 Python sweep 驱动读取）
    //
    //  输出格式：METRIC:key:value
    //  运行方式：swift test --filter AIBenchmarkSweepTests/benchmarkMetrics 2>&1 | grep METRIC
    //
    //  6 组件 × N 参数，每参数输出独立 METRIC 行；Python 驱动改参数→跑→grep→还原。
    @Test func benchmarkMetrics() {
        let now = T0  // 确定性时基

        // ─── A. WorkspaceRanking 辨别力 ──────────────────────────────────────
        // syntheticWorkspaces: A(rel=0.92,opens=14,dwell=4200,last=0.5d)
        //                      E(rel=0.18,opens=2 ,dwell=50  ,last=75d )
        let scores = syntheticWorkspaces.map { AIWorkspaceRanking.score($0, now: now) }
        // A=index 0, E=index 4（见 syntheticWorkspaces 顺序）
        let sA = scores[0]; let sE = scores[4]
        let wsHighLowGap = sA - sE          // 大→辨别力强
        print("METRIC:ws_high_low_gap:\(String(format: "%.4f", wsHighLowGap))")

        // 1 次负反馈是否把 A（rel=0.92）压到 C（rel=0.78,neg=0）以下？不应该。
        let wsA1neg = ws("A1neg", "测试-1负反馈", relevance: 0.92, opens: 14,
                         dwellSec: 4200, lastOpenDays: 0.5, negFeedback: 1)
        let wsC     = syntheticWorkspaces[2]   // C: rel=0.78, neg=2 but already penalized
        let wsD     = syntheticWorkspaces[3]   // D: rel=0.65, neg=0
        let sA1neg  = AIWorkspaceRanking.score(wsA1neg, now: now)
        let sD      = scores[3]
        // neg1_over_D: 1负反馈后 A 是否仍高于 D（rel=0.65）; 1=是(好) 0=否(说明单次踩过重)
        let neg1OverD = sA1neg > sD ? 1 : 0
        print("METRIC:ws_neg1_over_D:\(neg1OverD)")

        // feedbackPenalty 让 A 跌到 D 以下需要几次负反馈？
        var negToDemote = -1
        for n in 1...10 {
            let wAN = ws("AN", "测试", relevance: 0.92, opens: 14, dwellSec: 4200,
                         lastOpenDays: 0.5, negFeedback: n)
            if AIWorkspaceRanking.score(wAN, now: now) < sD { negToDemote = n; break }
        }
        print("METRIC:ws_neg_demote_at:\(negToDemote)")

        // ─── B. StartupRanker 新目录 vs 老目录 ───────────────────────────────
        // s1: ~/Documents/SimpleZip  visits=9  dwell=1800 recency=1d
        // s6: ~/Archives/2022        visits=11 dwell=900  recency=40d
        let sS1 = AIStartupDirectoryRanker.score(startupCandidates[0])
        let sS6 = AIStartupDirectoryRanker.score(startupCandidates[5])
        let startupCorrect = sS1 > sS6 ? 1 : 0   // 1=新目录赢(期望) 0=老目录赢(bug)
        let startupGap     = sS1 - sS6
        print("METRIC:startup_correct:\(startupCorrect)")
        print("METRIC:startup_gap:\(String(format: "%.4f", startupGap))")

        // 负分惩罚 s4(~/Desktop, neg=2) vs s1 比较
        let sS4 = AIStartupDirectoryRanker.score(startupCandidates[3])
        let negPenaltyEffect = sS1 - sS4   // 正=惩罚有效
        print("METRIC:startup_neg_penalty:\(String(format: "%.4f", negPenaltyEffect))")

        // ─── C. SemanticTagRanker 负反馈衰减 ──────────────────────────────────
        // tagCandidates: releaseArtifact=0.88, sourceArchive=0.72, signedContainer=0.65…
        let topTag = tagCandidates[0]   // releaseArtifact 0.88
        let secTag = tagCandidates[1]   // sourceArchive   0.72
        var tagDemoteAt = -1
        for n in 1...15 {
            let ranked = AISemanticTagRanker.rank(tagCandidates,
                                                  negativeFeedback: ["release-artifact": n])
            if ranked.first?.tag != .releaseArtifact { tagDemoteAt = n; break }
        }
        print("METRIC:tag_demote_at:\(tagDemoteAt)")

        // 正反馈把 sourceArchive(0.72) 提升到 releaseArtifact(0.88) 以上需要几次？
        var tagBoostAt = -1
        for n in 1...20 {
            let ranked = AISemanticTagRanker.rank(tagCandidates,
                                                  positiveFeedback: ["source-archive": n])
            if ranked.first?.tag == .sourceArchive { tagBoostAt = n; break }
        }
        print("METRIC:tag_boost_at:\(tagBoostAt)")
        _ = topTag; _ = secTag   // suppress unused warning

        // ─── D. ThemeSuppression 衰减天数 ────────────────────────────────────
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        let supRecord = AIThemeDismissalRecord(
            fingerprint: fpRelease,
            firstDismissedAt: epoch, lastDismissedAt: epoch, dismissCount: 1)
        var suppressDays = 999
        for d in 1...500 {
            let t = epoch.addingTimeInterval(Double(d) * 86_400)
            let w = AIThemeSuppressionPolicy.weight(of: supRecord, now: t)
            if w < AIThemeSuppressionPolicy.resurfaceFloor { suppressDays = d; break }
        }
        print("METRIC:suppress_resurface_days:\(suppressDays)")

        // 2 次 dismiss 衰减时间（halfLife×count 线性扩展）
        let supRecord2 = AIThemeDismissalRecord(
            fingerprint: fpRelease,
            firstDismissedAt: epoch, lastDismissedAt: epoch, dismissCount: 2)
        var suppressDays2 = 999
        for d in 1...1000 {
            let t = epoch.addingTimeInterval(Double(d) * 86_400)
            let w = AIThemeSuppressionPolicy.weight(of: supRecord2, now: t)
            if w < AIThemeSuppressionPolicy.resurfaceFloor { suppressDays2 = d; break }
        }
        print("METRIC:suppress_resurface_days_2x:\(suppressDays2)")

        // ─── E. LearningStore 衰减至中性天数 ─────────────────────────────────
        let wsID = UUID()
        var ls = AIWorkspaceLearningStore()
        ls = ls.recording(wsID, signals: ["hash", "test"], by: -4, at: epoch)
        var lsNeutralDays = 999
        for d in 1...730 {
            let t = epoch.addingTimeInterval(Double(d) * 86_400)
            let w = ls.weightedAffinity(wsID, signals: ["hash"], now: t)
            if w > AIWorkspaceLearningStore.strongNegative { lsNeutralDays = d; break }
        }
        print("METRIC:learn_neutral_days:\(lsNeutralDays)")

        // cap 层: -5（cap 值）的信号衰减到中性需要多久（测试 cap 有效性）
        var lsCap = AIWorkspaceLearningStore()
        lsCap = lsCap.recording(wsID, signals: ["archive"], by: -5, at: epoch)  // at cap
        var lsCapNeutralDays = 999
        for d in 1...730 {
            let t = epoch.addingTimeInterval(Double(d) * 86_400)
            let w = lsCap.weightedAffinity(wsID, signals: ["archive"], now: t)
            if w > AIWorkspaceLearningStore.strongNegative { lsCapNeutralDays = d; break }
        }
        print("METRIC:learn_cap_neutral_days:\(lsCapNeutralDays)")

        // ─── F. ThemeEngine 主题检测数 ────────────────────────────────────────
        // releasePool 33 件：已知有 release+sign 簇、source 簇，及散件
        let themes = AIWorkspaceThemeEngine.discoverThemes(from: releasePool, now: now)
        print("METRIC:theme_count:\(themes.count)")

        // 孤立件应不成主题：只放 5 个互无共享 token 的独立件
        let soloPool: [AIVirtualNodeCandidate] = [
            nc("solo1", .file, "readme.txt",    tokens: ["text", "readme"]),
            nc("solo2", .file, "icon.png",      tokens: ["image", "icon"]),
            nc("solo3", .file, "config.json",   tokens: ["config", "json"]),
            nc("solo4", .file, "log.txt",       tokens: ["log", "debug"]),
            nc("solo5", .file, "temp.dat",      tokens: ["temp", "cache"]),
        ]
        let soloThemes = AIWorkspaceThemeEngine.discoverThemes(from: soloPool, now: now)
        print("METRIC:theme_solo_count:\(soloThemes.count)")   // 期望 0

        // ─── G. AIVirtualFolderModelInputPreparer 专注律 ────────────────────
        // 主指标 preparer_coverage = strongTokenCoverage:候选输出里覆盖了多少「关键强 token」。
        // releaseStrongTokens = ["simplezip","release","0.4.5","sign","integrity"]
        // 不传 maxCandidates,让测试随 defaultMaxCandidates 静态变量走,sweep 时只改那个值。
        let (_, pm) = AIVirtualFolderModelInputPreparer.prepareWithMetrics(
            candidates: releasePool, strongTokens: releaseStrongTokens)
        print("METRIC:preparer_coverage:\(String(format: "%.4f", pm.strongTokenCoverage))")
        print("METRIC:preparer_tier_high:\(pm.tierCounts["high"] ?? 0)")
        print("METRIC:preparer_tier_normal:\(pm.tierCounts["normal"] ?? 0)")
        print("METRIC:preparer_tier_low:\(pm.tierCounts["low"] ?? 0)")
        print("METRIC:preparer_suppressed:\(pm.suppressedCount)")
        print("METRIC:preparer_output:\(pm.outputCount)")

        // prefix 上限测:构造 18 token 工作区,看截到 prefix(N) 后还剩几个。
        let manyPlan = AIWorkspaceQueryPlan(
            semanticTags: ["simplezip", "release", "arm64", "x86", "sign", "integrity",
                           "dmg", "changelog", "security", "backup"],
            taskTags: ["hash", "test", "compress", "validate"],
            keywords: ["0.4.5", "gpg", "sha256", "build"])
        let manyWS = AIWorkspace(
            id: UUID(uuidString: "00000000-0000-0000-FFFF-000000000001")!,
            origin: .recommended, title: "18-token-ws",
            queryPlan: manyPlan, iconSystemName: "sparkles", generatedAt: T0)
        let promptFact = AIWorkspacePromptFact(workspace: manyWS)
        print("METRIC:prompt_qtokens_count:\(promptFact.queryTokens.count)")
    }
}

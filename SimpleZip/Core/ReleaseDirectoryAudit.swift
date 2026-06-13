//
//  ReleaseDirectoryAudit.swift
//  SimpleZip
//
//  0.4.4 #11:发布目录完整性检查的纯逻辑层 —— 文件清点 / SHA256SUMS 覆盖与陈旧条目 /
//  VERIFY.md 引用 / 孤儿文件。全部纯函数,SwiftPM 可测。
//  跑哈希、解析 .szs、隔离验签等异步部分在 app 侧任务里做,结果同样落进 Finding。
//

import Foundation

nonisolated enum ReleaseDirectoryAudit {

    /// 目录清点:按发布目录的常见角色分类(只看文件名,不读内容)。
    struct Inventory: Equatable {
        var artifacts: [String] = []
        var checksumFiles: [String] = []
        var containers: [String] = []
        var publicKeys: [String] = []
        var verifyDocs: [String] = []
        var manifests: [String] = []
        var others: [String] = []
    }

    /// `isArchiveName`:归档判定由调用方注入(app 侧用 ArchiveService.isSupportedArchive 的扩展名集;
    /// 测试给个简单闭包)—— Core 不复制支持格式清单。
    static func classify(names: [String], isArchiveName: (String) -> Bool) -> Inventory {
        var inventory = Inventory()
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            if name.hasPrefix(".") { continue }   // 隐藏文件不参与发布审计
            let lowered = name.lowercased()
            if lowered.hasPrefix("sha256sums") {
                inventory.checksumFiles.append(name)
            } else if lowered.hasSuffix(".szs") || lowered.hasSuffix(".siz") {
                inventory.containers.append(name)
            } else if lowered.hasSuffix(".asc") {
                inventory.publicKeys.append(name)
            } else if lowered.hasPrefix("verify"), lowered.hasSuffix(".md") {
                inventory.verifyDocs.append(name)
            } else if lowered.hasPrefix("release-manifest"), lowered.hasSuffix(".json") {
                inventory.manifests.append(name)
            } else if isArchiveName(name) {
                inventory.artifacts.append(name)
            } else {
                inventory.others.append(name)
            }
        }
        return inventory
    }

    /// SHA256SUMS 条目 vs 目录产物:
    /// - `uncovered`:产物在目录里但校验文件没列(下载者无从校验);
    /// - `stale`:校验文件列了但目录里没有(改名/删除后忘更新)。
    static func checksumCoverage(
        entryNames: [String],
        artifacts: [String]
    ) -> (uncovered: [String], stale: [String]) {
        let entries = Set(entryNames)
        let present = Set(artifacts)
        let uncovered = artifacts.filter { !entries.contains($0) }
        let stale = entryNames.filter { !present.contains($0) }
        return (uncovered, stale)
    }

    /// 从 VERIFY.md 之类的文档里抽「看起来是文件名」的 token(字母数字._- 且带扩展名),
    /// 返回其中目录里**不存在**的 —— 文档引用了已改名/已删除的文件。
    /// 简单文本提取,不解析 Markdown;误报偏向保守(只看明确带扩展名的 token)。
    static func missingDocumentReferences(documentText: String, directoryNames: [String]) -> [String] {
        let present = Set(directoryNames)
        let pattern = #"[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9]{1,10}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(documentText.startIndex..<documentText.endIndex, in: documentText)
        var seen = Set<String>()
        var missing: [String] = []
        for match in regex.matches(in: documentText, range: range) {
            guard let tokenRange = Range(match.range, in: documentText) else { continue }
            let token = String(documentText[tokenRange])
            // 只认「有扩展名的文件名」;过滤纯版本号(1.2.3)与域名常见尾巴。
            let ext = (token as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, Int(ext) == nil else { continue }
            guard !["com", "org", "net", "io", "dev"].contains(ext) else { continue }
            guard !seen.contains(token) else { continue }
            seen.insert(token)
            if !present.contains(token) {
                missing.append(token)
            }
        }
        return missing
    }

    /// 孤儿文件:目录里既不是产物、也不是任何已知发布角色(校验/容器/公钥/文档/清单)的文件。
    /// 它们不一定是问题(README、changelog…),报 info 级让用户自己过目。
    static func orphans(in inventory: Inventory) -> [String] {
        inventory.others
    }
}

//
//  ArchiveContentSearch.swift
//  SimpleZip
//
//  队列 #11:归档内「内容搜索」。范围按用户拍板砍死:只搜文本类文件、单文件大小上限、
//  必须主动触发、解到临时安全区搜完即删;不碰 PDF、不 OCR、不读二进制。
//  这里是纯逻辑(候选判定 / 二进制嗅探 / 逐行匹配),SwiftPM 可测;
//  解包与临时目录生命周期在模型层(ArchiveBrowserModel)。
//

import Foundation

enum ArchiveContentSearch {

    /// 默认单文件大小上限(2 MB)。文本文件极少超过;超过的多半是日志/数据导出,代价不成比例。
    nonisolated static let defaultMaxFileBytes: Int64 = 2_000_000

    /// 「文本类」扩展名白名单 —— 宁可漏不可错:不在名单 = 不解不读。
    nonisolated static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "rst", "log", "csv", "tsv",
        "json", "xml", "yml", "yaml", "toml", "ini", "cfg", "conf", "plist", "properties",
        "html", "htm", "css", "js", "ts", "jsx", "tsx", "svg",
        "swift", "c", "h", "cpp", "hpp", "cc", "m", "mm", "java", "kt", "kts", "rs", "go",
        "py", "rb", "sh", "zsh", "bash", "pl", "php", "lua", "sql", "r",
        "tex", "bib", "gradle", "cmake", "make", "mk", "dockerfile", "gitignore", "editorconfig"
    ]

    /// 条目是否进入搜索范围:非目录、扩展名在白名单(或无扩展名但叫 Makefile/README 这类)、
    /// 大小已知且 ≤ 上限(未知大小 = 不读,宁可漏)。
    nonisolated static func isTextCandidate(_ item: ArchiveItem, maxBytes: Int64 = defaultMaxFileBytes) -> Bool {
        guard !item.isDirectory else { return false }
        guard let size = item.size, size >= 0, size <= maxBytes else { return false }
        let fileName = (item.name as NSString).lastPathComponent
        let ext = (fileName as NSString).pathExtension.lowercased()
        if textExtensions.contains(ext) { return true }
        if ext.isEmpty {
            let bareNames: Set<String> = ["makefile", "readme", "license", "changelog", "authors", "notice", "todo"]
            return bareNames.contains(fileName.lowercased())
        }
        return false
    }

    struct Match: Identifiable, Hashable {
        let id = UUID()
        let entryPath: String
        let lineNumber: Int
        let lineText: String

        nonisolated init(entryPath: String, lineNumber: Int, lineText: String) {
            self.entryPath = entryPath
            self.lineNumber = lineNumber
            self.lineText = lineText
        }
    }

    /// 在一个文件的数据里找 query(大小写不敏感),返回 (行号, 截断后的行文本)。
    /// 头部嗅探到 NUL = 当二进制跳过(白名单扩展名也可能装着二进制,如 .log 轮转压缩残骸)。
    /// 每文件最多 `perFileLimit` 条 —— 报告要可读,不是 grep 替代品。
    nonisolated static func matches(in data: Data, query: String, perFileLimit: Int = 20) -> [(lineNumber: Int, lineText: String)] {
        guard !query.isEmpty, !data.isEmpty else { return [] }
        if data.prefix(8192).contains(0) { return [] }
        let text = String(decoding: data, as: UTF8.self)
        var results: [(Int, String)] = []
        var lineNumber = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            guard line.range(of: query, options: [.caseInsensitive]) != nil else { continue }
            results.append((lineNumber, trimmedPreview(of: line)))
            if results.count >= perFileLimit { break }
        }
        return results
    }

    /// 行预览:去首尾空白,过长截到 200 字符(报告行不该横向爆炸)。
    private nonisolated static func trimmedPreview(of line: Substring) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= 200 { return trimmed }
        return String(trimmed.prefix(200)) + "…"
    }
}

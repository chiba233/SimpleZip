//
//  ArchiveService+Parsing.swift
//  SimpleZip
//
//  Created by Copilot on 2026/05/28.
//

import Foundation

extension ArchiveService {
    // nonisolated:纯字节解析(读 ZIP 尾部 + 解析 central directory),无 MainActor 状态 → 可在后台线程跑。
    // 关键:解压对话框 preflight 经 `Task.detached` 调它检测加密**方法**;若它是 MainActor 隔离,detached 会跳回
    // 主线程跑冻死 UI(用户报)。整条解析链(readZipCentralDirectory / zipAESDetection / Data.zip*)同标。
    // 只读尾部(EOCD + 中央目录),不读整个文件 —— 否则网络卷上会把整包全拖一遍(见 readZipCentralDirectory)。
    nonisolated static func detectZipEncryption(in archive: URL) -> ZipEncryptionDetection {
        guard archive.pathExtension.lowercased() == "zip" else {
            return .unknown
        }

        do {
            // 只读尾部拿中央目录,**绝不读整个文件**:网络卷上 `Data(contentsOf:.mappedIfSafe)` 会退化成把整包
            // (可能几 GB)全读一遍,只为探测加密。改为 FileHandle 读末尾找 EOCD → seek 到中央目录只读那一段,
            // 读量 = 中央目录大小(∝ 条目数),与文件大小无关。offset 相对该 chunk(从 0 起)。
            guard let directory = try readZipCentralDirectory(at: archive) else {
                return .unknown
            }

            var detectedMethods: Set<ZipEncryptionDetection> = []
            var offset = 0
            let endOffset = directory.count

            while offset + 46 <= endOffset, directory.zipUInt32(at: offset) == 0x02014b50 {
                let flags = directory.zipUInt16(at: offset + 8) ?? 0
                let fileNameLength = Int(directory.zipUInt16(at: offset + 28) ?? 0)
                let extraLength = Int(directory.zipUInt16(at: offset + 30) ?? 0)
                let commentLength = Int(directory.zipUInt16(at: offset + 32) ?? 0)
                let extraOffset = offset + 46 + fileNameLength
                let nextOffset = extraOffset + extraLength + commentLength
                guard nextOffset <= endOffset else {
                    break
                }

                if flags & 0x0001 == 0 {
                    detectedMethods.insert(.none)
                } else if let aesMethod = zipAESDetection(in: directory, offset: extraOffset, length: extraLength) {
                    detectedMethods.insert(aesMethod)
                } else {
                    detectedMethods.insert(.zipCrypto)
                }

                offset = nextOffset
            }

            let encryptedMethods = detectedMethods.filter { $0 != .none }
            if encryptedMethods.count > 1 {
                return .mixed
            }
            if let method = encryptedMethods.first {
                return method
            }
            return detectedMethods.contains(.none) ? .none : .unknown
        } catch {
            return .unknown
        }
    }

    nonisolated static func parseZipList(tarOutput: String, unzipOutput: String) -> [ArchiveItem] {
        var metadataByName: [String: ArchiveItem] = [:]
        for item in parseUnzipList(unzipOutput) {
            let key = normalizedEntryName(item.name)
            if metadataByName[key] == nil {
                metadataByName[key] = item
            }
        }

        return tarOutput
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { rawName in
                let name = decodeArchivePathEscapes(rawName)
                let isDirectory = name.hasSuffix("/")
                let metadata = metadataByName[normalizedEntryName(name)]
                return ArchiveItem(
                    name: name,
                    isDirectory: isDirectory,
                    size: isDirectory ? nil : metadata?.size,
                    modified: metadata?.modified,
                    sizeText: isDirectory ? "" : (metadata?.sizeText ?? ""),
                    modifiedText: metadata?.modifiedText ?? "",
                    method: isDirectory ? "" : "Deflate"
                )
            }
    }

    nonisolated static func parseUnzipList(_ output: String) -> [ArchiveItem] {
        // 整次 parse 复用一个 Calendar(手动解析日期,绕开逐条目新建 DateFormatter 的 ICU 冷启动)。
        let calendar = archiveDateCalendar()
        return output
            .split(separator: "\n")
            .compactMap { line -> ArchiveItem? in
                let text = String(line)
                guard text.range(of: #"^\s*\d+\s+\d{2}-\d{2}-\d{4}\s+\d{2}:\d{2}\s+.+$"#, options: .regularExpression) != nil else {
                    return nil
                }

                let parts = text.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count == 4 else { return nil }

                let name = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
                let size = Int64(parts[0]) ?? 0
                let isDirectory = name.hasSuffix("/")
                let modifiedText = "\(parts[1]) \(parts[2])"
                return ArchiveItem(
                    name: name,
                    isDirectory: isDirectory,
                    size: isDirectory ? nil : size,
                    modified: parseUnzipModified(modifiedText, calendar: calendar),
                    sizeText: isDirectory ? "" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                    modifiedText: modifiedText,
                    method: isDirectory ? "" : "Deflate"
                )
            }
    }

    /// 0.4.1 #114（**只读**；实测 bundled 7zz 不支持写注释参数,绝不瞎猜后端旗标）：
    /// 从 `l -slt` 输出抽**归档级**注释（头部块的 Comment；条目块的不算）。
    /// 7-Zip 对多行值用花括号形式：`Comment = `（空值行）后跟 `{`、内容若干行、`}`（实测 zip 注释如此输出）；
    /// 单行注释直接 `Comment = xxx`。只扫到条目分隔线 `----------` 为止 —— 之后是条目区。
    nonisolated static func parseArchiveHeaderComment(_ output: String) -> String {
        let lines = output
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("----------") { return "" }
            if line.hasPrefix("Comment =") {
                let inline = line.dropFirst("Comment =".count).trimmingCharacters(in: .whitespaces)
                if !inline.isEmpty { return inline }
                if index + 1 < lines.count, lines[index + 1] == "{" {
                    var body: [String] = []
                    var cursor = index + 2
                    while cursor < lines.count, lines[cursor] != "}" {
                        body.append(lines[cursor])
                        cursor += 1
                    }
                    return body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return ""
            }
            index += 1
        }
        return ""
    }

    /// zstd 单流的内层文件名合成 —— 与 7zz 解压产物命名**完全一致**(实测):
    /// `a.txt.zst → a.txt`、`sample.tar.zst → sample.tar`、`foo.tzst → foo.tar`。
    nonisolated static func singleStreamInnerName(forArchiveNamed archiveName: String) -> String {
        let ns = archiveName as NSString
        if ns.pathExtension.lowercased() == "tzst" {
            return ns.deletingPathExtension + ".tar"
        }
        let stem = ns.deletingPathExtension
        return stem.isEmpty ? archiveName : stem
    }

    /// 一次性解析整串 `7zz l -slt` 输出 → [ArchiveItem]。委托给增量 `SevenZipListStreamParser`(喂整串 + finish),
    /// 与逐 chunk 流式路径**完全同逻辑**(fixture 覆盖此入口)。流式路径见 `SevenZipBackend.list`:按 chunk 喂同一
    /// parser,**不再把整串原始输出 + 其 \r 副本同时压在内存里**(超大归档 OOM 的元凶之一)。
    nonisolated static func parseSevenZipList(_ output: String) -> [ArchiveItem] {
        let parser = SevenZipListStreamParser()
        parser.consume(output)
        return parser.finish()
    }

    /// 增量解析 `7zz l -slt` 输出。按 chunk 喂 `consume`、跨 chunk 用 `remainder` 接半行,`finish()` 收尾。
    /// **不持有整串输出**:逐 chunk 去 \r、逐块 flush,内存只留「当前块 values + 累积 rows + 有界头段缓冲」。
    /// 线程:由 BackendProcessRunner 的**单个**读取线程顺序喂 `consume`,`await` 返回后(读取已结束)才 `finish`
    /// —— 存在 happens-before,无并发访问,故 `@unchecked Sendable` 不加锁(逐行加锁对百万行不划算)。
    nonisolated final class SevenZipListStreamParser: @unchecked Sendable {
        private var rows: [ArchiveItem] = []
        private var values: [String: String] = [:]
        // 头块信息(zstd 单流合成内层名要用):Type + 归档文件名。
        private var headerType = ""
        private var headerArchiveName = ""
        // 跨 chunk 的半行缓存(上一块末尾未结束的行)。
        private var remainder = ""
        // 头注释(Comment,可能多行 `{ }`)在头段(`----------` 之前)。累积头段原文(有界)供 parseArchiveHeaderComment 提取。
        private var headerBuffer = ""
        private var headerDone = false
        // 整次 parse 复用一个 Calendar(见 archiveDateCalendar:手动解析绕开 DateFormatter 的 ICU 冷启动)。
        private let calendar = ArchiveService.archiveDateCalendar()

        /// 头段原文解析出的归档级注释(zip/rar 头部 Comment);无则空串。
        var headerComment: String { ArchiveService.parseArchiveHeaderComment(headerBuffer) }

        /// 喂入一段输出(可能在任意字节边界切开)。
        func consume(_ chunk: String) {
            // 逐 chunk 去 \r(PTY ONLCR 把 \n 变 \r\n;不整串复制),跨 chunk 用 remainder 接半行。
            let combined = remainder + chunk.replacingOccurrences(of: "\r", with: "")
            let segments = combined.components(separatedBy: "\n")
            remainder = segments.last ?? ""   // 最后一段可能是半行,留到下一块
            for line in segments.dropLast() {
                handleLine(line)
            }
        }

        /// 收尾:把残留半行当最后一行处理,再 flush 末块,返回全部条目。
        func finish() -> [ArchiveItem] {
            if !remainder.isEmpty {
                handleLine(remainder)
                remainder = ""
            }
            flush()
            return rows
        }

        private func handleLine(_ line: String) {
            // 头段累积(到 `----------` 止;有界防异常输出无限累积),供 headerComment 提取。
            if !headerDone {
                if line.hasPrefix("----------") {
                    headerDone = true
                } else if headerBuffer.utf8.count < 64_000 {
                    headerBuffer += line + "\n"
                }
            }
            if line.isEmpty {
                flush()
                return
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                values[parts[0]] = parts[1]
            }
        }

        private func flush() {
            guard let rawPath = values["Path"] else {
                // zstd 单流(0.4.3 实测):`-slt` 的条目块**没有 Path**,只有空的 Size/Packed Size 行
                // (gzip/xz 都带 Path,唯独 zstd 不带)。7zz 自己在普通 `l` 输出和解压时按
                // 「归档名去掉 .zst / .tzst → stem.tar」合成内层名 —— 这里照同一规则合成,
                // 否则 zst/tar.zst 打开永远是空列表。按名解选中条目实测可用(7zz 接受合成名)。
                if headerType == "zstd", !headerArchiveName.isEmpty,
                   values.keys.contains("Size") || values.keys.contains("Packed Size") {
                    let inner = ArchiveService.singleStreamInnerName(forArchiveNamed: headerArchiveName)
                    rows.append(
                        ArchiveItem(
                            name: inner,
                            isDirectory: false,
                            size: nil,
                            modified: nil,
                            sizeText: "",
                            modifiedText: "",
                            method: "zstd",
                            isEncrypted: false,
                            packedSize: nil,
                            packedSizeText: "",
                            crc: "",
                            created: nil,
                            createdText: "",
                            attributes: "",
                            accessed: nil,
                            accessedText: "",
                            hostOS: "",
                            characteristics: "",
                            symlinkTarget: "",
                            comment: ""
                        )
                    )
                }
                values.removeAll()
                return
            }
            let path = ArchiveService.decodeArchivePathEscapes(rawPath)
            guard path != "." else {
                values.removeAll()
                return
            }
            // 7zz l -slt 在列出条目之前会先输出 archive 自己的元信息块：
            // Path = <绝对路径>, Type = 7z, Physical Size = ..., Headers Size = ..., Method = LZMA2:12, Solid = +, Blocks = 1
            // 这一块带 Method 字段，会通过下面的 hasEntryMetadata 检查被当成条目，
            // 把 archive 的绝对路径当 entry 名报出去，再触发 ArchiveSafety 的「绝对路径」拦截。
            // 这里用 `Type` / `Physical Size` / `Headers Size` 三个只出现在头块的字段显式过滤掉。
            let isArchiveHeaderBlock = values["Type"] != nil
                || values["Physical Size"] != nil
                || values["Headers Size"] != nil
            guard !isArchiveHeaderBlock else {
                // 记下头块的 Type + 归档文件名 —— zstd 单流条目块没有 Path,合成内层名时要用。
                if let type = values["Type"] {
                    headerType = type
                    headerArchiveName = (path as NSString).lastPathComponent
                }
                values.removeAll()
                return
            }
            let hasEntryMetadata = values["Folder"] != nil
                || values["Attributes"] != nil
                || values["Modified"] != nil
                || values["CRC"] != nil
                || values["Method"] != nil
                || values["Encrypted"] != nil
            guard hasEntryMetadata else {
                values.removeAll()
                return
            }

            let size = Int64(values["Size"] ?? "") ?? 0
            // 目录判定：7zz 自己建的归档用 `Folder = +`；但别的工具 / 某些归档把目录标成 `Attributes = D…`
            // 而 `Folder = -`（或缺失）。只看 Folder 会把这种目录当成 0 字节文件 → 跟合成出来的同名文件夹并存，
            // 出现「幽灵文件」（一个文件夹 data/ + 一个 0KB 文件 data）。两个判据都认。
            let isDirectory = values["Folder"] == "+" || (values["Attributes"]?.hasPrefix("D") ?? false)
            let modifiedText = values["Modified"] ?? ""
            let packedSizeRaw = values["Packed Size"] ?? ""
            let packedSize = Int64(packedSizeRaw)
            let createdText = values["Created"] ?? ""
            let accessedText = values["Accessed"] ?? ""
            rows.append(
                ArchiveItem(
                    name: path,
                    isDirectory: isDirectory,
                    size: isDirectory ? nil : size,
                    modified: ArchiveService.parseSevenZipModified(modifiedText, calendar: calendar),
                    sizeText: isDirectory ? "" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                    modifiedText: modifiedText,
                    method: values["Method"] ?? "",
                    isEncrypted: values["Encrypted"] == "+" || ArchiveService.archiveMethodSuggestsEncryption(values["Method"] ?? ""),
                    packedSize: (isDirectory || packedSize == nil) ? nil : packedSize,
                    packedSizeText: (isDirectory || packedSize == nil)
                        ? ""
                        : ByteCountFormatter.string(fromByteCount: packedSize ?? 0, countStyle: .file),
                    crc: values["CRC"] ?? "",
                    created: ArchiveService.parseSevenZipModified(createdText, calendar: calendar),
                    createdText: createdText,
                    attributes: values["Attributes"] ?? "",
                    accessed: ArchiveService.parseSevenZipModified(accessedText, calendar: calendar),
                    accessedText: accessedText,
                    hostOS: values["Host OS"] ?? "",
                    characteristics: values["Characteristics"] ?? "",
                    symlinkTarget: values["Symbolic Link"] ?? "",
                    comment: values["Comment"] ?? ""
                )
            )
            values.removeAll()
        }
    }

    /// `zipEncryption` 非 nil 时(调用方已在打开时缓存了检测结果,见 ArchiveSession.detectedZipEncryption)直接用,
    /// **不再同步读 ZIP 中央目录**;为 nil 才回退到现场检测(保留旧行为给没有缓存的调用方,如测试 / Core 内部)。
    nonisolated static func archiveItemsSuggestPasswordRequirement(_ items: [ArchiveItem], in archive: URL, zipEncryption: ZipEncryptionDetection? = nil) -> Bool {
        if archive.pathExtension.lowercased() == "zip" {
            let detection = zipEncryption ?? detectZipEncryption(in: archive)
            return detection != .none && detection != .unknown
        }
        return items.contains { $0.isEncrypted || archiveMethodSuggestsEncryption($0.method) }
    }

    private nonisolated static func decodeArchivePathEscapes(_ text: String) -> String {
        guard text.contains("\\") else { return text }

        let characters = Array(text)
        var bytes: [UInt8] = []
        var index = 0

        while index < characters.count {
            if characters[index] == "\\", index + 3 < characters.count {
                let octalDigits = String(characters[(index + 1)...(index + 3)])
                if let value = UInt8(octalDigits, radix: 8) {
                    bytes.append(value)
                    index += 4
                    continue
                }

            }

            let scalar = characters[index].unicodeScalars.first!
            if scalar.value <= 0x7F {
                bytes.append(UInt8(scalar.value))
            } else {
                bytes.append(contentsOf: String(characters[index]).utf8)
            }
            index += 1
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    private nonisolated static func archiveMethodSuggestsEncryption(_ method: String) -> Bool {
        let normalized = method.lowercased()
        return normalized.contains("7zaes")
            || normalized.contains("zipcrypto")
            || normalized.contains("aes128")
            || normalized.contains("aes192")
            || normalized.contains("aes256")
            || normalized.contains("aes-128")
            || normalized.contains("aes-192")
            || normalized.contains("aes-256")
    }

    nonisolated static func parseSevenZipBenchmark(_ output: String, backendDescription: String, options: SevenZipBenchmarkOptions) -> SevenZipBenchmarkReport {
        let lines = output.split(separator: "\n").map(String.init)
        let compilerLine = lines.first { $0.hasPrefix("Compiler:") }
        let systemLine = lines.first { $0.contains("Darwin :") || $0.contains("Windows ") || $0.contains("Linux ") }
        let pageSizeLine = lines.first { $0.hasPrefix("PageSize:") }
        let ramSizeLine = lines.first { $0.hasPrefix("RAM size:") }
        let ramUsageLine = lines.first { $0.hasPrefix("RAM usage:") }
        let averageLine = lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Avr:") }
        let totalLine = lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Tot:") }
        let threadsLine = lines.first { $0.contains("# Benchmark threads:") }
        let cpuLine = cpuDescriptionLine(in: lines, after: pageSizeLine)
        let frequencySamples = lines.compactMap(parseFrequencySample)
        let dictionaryRows = lines.compactMap(parseBenchmarkDictionaryRow)
        let kernelTime = timeValue(in: lines, prefix: "Kernel  Time =")
        let userTime = timeValue(in: lines, prefix: "User    Time =")
        let processTime = timeValue(in: lines, prefix: "Process Time =")
        let globalTime = timeValue(in: lines, prefix: "Global  Time =")

        let averageValues = averageLine.map(integers(in:)) ?? []
        let totalValues = totalLine.map(integers(in:)) ?? []
        let threadValues = threadsLine.map(integers(in:)) ?? []
        let ramSizeValues = ramSizeLine.map(integers(in:)) ?? []
        let ramUsageValues = ramUsageLine.map(integers(in:)) ?? []

        let compressionAverage: SevenZipBenchmarkMetrics? = averageValues.count >= 8 ? SevenZipBenchmarkMetrics(
            speedKiBPerSecond: averageValues[0],
            usagePercent: averageValues[1],
            ratingMips: averageValues[2],
            usageRatingMips: averageValues[3]
        ) : nil

        let decompressionAverage: SevenZipBenchmarkMetrics? = averageValues.count >= 8 ? SevenZipBenchmarkMetrics(
            speedKiBPerSecond: averageValues[4],
            usagePercent: averageValues[5],
            ratingMips: averageValues[6],
            usageRatingMips: averageValues[7]
        ) : nil

        return SevenZipBenchmarkReport(
            backendDescription: backendDescription,
            options: options,
            compilerDescription: compilerLine,
            systemDescription: systemLine,
            cpuDescription: cpuLine,
            pageSizeText: pageSizeLine,
            ramUsageMB: ramUsageValues.first,
            ramSizeMB: ramSizeValues.first,
            hardwareThreads: ramSizeValues.count > 1 ? ramSizeValues[1] : nil,
            benchmarkThreads: threadValues.last,
            frequencySamples: frequencySamples,
            dictionaryRows: dictionaryRows,
            compressionAverage: compressionAverage,
            decompressionAverage: decompressionAverage,
            totalRatingMips: totalValues.last,
            totalUsagePercent: totalValues.first,
            kernelTimeSeconds: kernelTime,
            userTimeSeconds: userTime,
            processTimeSeconds: processTime,
            globalTimeSeconds: globalTime,
            output: output
        )
    }

    nonisolated static func expandedEntryNames(for entries: [ArchiveItem]) -> [String] {
        var normalizedNames: [String: String] = [:]
        for item in entries {
            if normalizedNames[item.name] == nil {
                normalizedNames[item.name] = normalizedEntryName(item.name)
            }
        }

        func isLeafDirectory(_ directory: ArchiveItem) -> Bool {
            let prefix = normalizedDirectoryPrefix(directory.name)
            return !entries.contains { child in
                guard child.name != directory.name else { return false }
                let normalizedName = normalizedNames[child.name] ?? normalizedEntryName(child.name)
                return normalizedName.hasPrefix(prefix)
            }
        }

        let names = entries.flatMap { item -> [String] in
            if item.isDirectory {
                let prefix = normalizedDirectoryPrefix(item.name)
                let descendants = entries.filter { child in
                    guard child.name != item.name else { return false }
                    let normalizedName = normalizedNames[child.name] ?? normalizedEntryName(child.name)
                    return normalizedName.hasPrefix(prefix)
                }

                let descendantFiles = descendants.filter { !$0.isDirectory }.map(\.name)
                let leafDirectories = descendants.filter { $0.isDirectory && isLeafDirectory($0) }.map(\.name)
                return descendantFiles + leafDirectories
            }
            return [item.name]
        }

        return Array(Set(names)).sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    nonisolated static func normalizedDirectoryPrefix(_ name: String) -> String {
        let normalized = normalizedEntryName(name)
        return normalized.hasSuffix("/") ? normalized : normalized + "/"
    }

    nonisolated static func normalizedEntryName(_ name: String) -> String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + (name.hasSuffix("/") ? "/" : "")
    }

    /// 只读 ZIP 尾部拿到**中央目录字节**:先读末尾(22 ~ 22+65535 字节,EOCD 所在范围)找 EOCD 签名,
    /// 从中拿到中央目录的绝对 offset + size,再 seek 过去只读那一段返回。**绝不读整个文件** —— 网络卷上
    /// `Data(contentsOf:.mappedIfSafe)` 会把整包(可能几 GB)全读一遍,只为探测加密。读量 = 中央目录大小
    /// (∝ 条目数)。ZIP64(offset/size 用 0xFFFFFFFF 标记、真值在 ZIP64 EOCD)按旧行为不支持 → 校验失败返回 nil。
    private nonisolated static func readZipCentralDirectory(at archive: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { return nil }

        // EOCD 在末尾 22 字节(无注释)~ 22 + 65535(最大注释)范围内;读这段尾巴从后往前找签名。
        let tailLength = Int(min(fileSize, UInt64(22 + 65_535)))
        try handle.seek(toOffset: fileSize - UInt64(tailLength))
        guard let tail = try handle.read(upToCount: tailLength), tail.count >= 22 else { return nil }

        var eocd = tail.count - 22
        while eocd >= 0 {
            if tail.zipUInt32(at: eocd) == 0x06054b50 {
                let size = Int(tail.zipUInt32(at: eocd + 12) ?? 0)
                let directoryOffset = Int(tail.zipUInt32(at: eocd + 16) ?? 0)
                guard size >= 0, directoryOffset >= 0,
                      UInt64(directoryOffset) + UInt64(size) <= fileSize else {
                    return nil
                }
                try handle.seek(toOffset: UInt64(directoryOffset))
                return try handle.read(upToCount: size)
            }
            eocd -= 1
        }
        return nil
    }

    private nonisolated static func zipAESDetection(in data: Data, offset: Int, length: Int) -> ZipEncryptionDetection? {
        var cursor = offset
        let endOffset = offset + length
        while cursor + 4 <= endOffset {
            let headerID = data.zipUInt16(at: cursor)
            let dataSize = Int(data.zipUInt16(at: cursor + 2) ?? 0)
            let fieldOffset = cursor + 4
            let nextOffset = fieldOffset + dataSize
            guard nextOffset <= endOffset else {
                return nil
            }

            if headerID == 0x9901, dataSize >= 7, let strength = data.zipByte(at: fieldOffset + 4) {
                switch strength {
                case 1:
                    return .aes128
                case 2:
                    return .aes192
                case 3:
                    return .aes256
                default:
                    return nil
                }
            }

            cursor = nextOffset
        }
        return nil
    }

    /// unzip `-l` 日期固定格式 "MM-dd-yyyy HH:mm"。手动抽整数 + 复用传入 Calendar,绕开 DateFormatter:
    /// 旧实现**每条目新建** DateFormatter,且首次 `date(from:)` 触发 ICU 加载 locale 符号表(冷启动极贵)。
    private nonisolated static func parseUnzipModified(_ text: String, calendar: Calendar) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let dateParts = parts[0].split(separator: "-")
        let timeParts = parts[1].split(separator: ":")
        guard dateParts.count == 3, timeParts.count >= 2,
              let month = Int(dateParts[0]), let day = Int(dateParts[1]), let year = Int(dateParts[2]),
              let hour = Int(timeParts[0]), let minute = Int(timeParts[1]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)
    }

    /// 归档日期解析用的 Calendar:格里高利历 + 系统当前时区(等价旧 DateFormatter 不设 timeZone 的默认行为)。
    /// **整次 parse 建一个、跨所有条目复用**。改用 `Calendar.date(from: 数值 DateComponents)` 而非 DateFormatter
    /// 字符串解析,从根上绕开 ICU 的 `DateFormatSymbols::loadArraysFromResources`(只有按「月/星期名」做文本
    /// 解析才需要它,纯数值组件不需要)—— 取样实证:大包打开里 DateFormatter 首次冷启动 ~294ms、逐条目累积
    /// 到 ~740ms,是「打开慢」的元凶。Calendar 是值类型,off-main 并发 parse 也安全。
    nonisolated static func archiveDateCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// 7zz `l -slt` 日期固定格式 "yyyy-MM-dd HH:mm:ss"(可带 ".小数秒",显示用不到→忽略整数秒之后的部分)。
    /// 手动抽整数 + 复用 Calendar(见 archiveDateCalendar),绕开 DateFormatter 的 ICU 冷启动。
    private nonisolated static func parseSevenZipModified(_ text: String, calendar: Calendar) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }   // created/accessed 常为空 → 免做无谓解析
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let dateParts = parts[0].split(separator: "-")
        let timeParts = parts[1].split(separator: ":")
        guard dateParts.count == 3, timeParts.count >= 3,
              let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2]),
              let hour = Int(timeParts[0]), let minute = Int(timeParts[1]) else { return nil }
        // 秒可能带小数(".SSS…") → 只取前导整数部分。
        guard let second = Int(timeParts[2].prefix(while: { $0.isNumber })) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)
    }

    /// ICU 正则编译代价不低，提为静态常量避免每次调用重新编译（pattern 是编译期字面量，try! 安全）。
    private nonisolated static let integerRegex = try! NSRegularExpression(pattern: #"\d+"#)
    private nonisolated static let timeValueRegex = try! NSRegularExpression(pattern: #"=\s*([0-9]+(?:\.[0-9]+)?)"#)

    private nonisolated static func integers(in line: String) -> [Int] {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return integerRegex.matches(in: line, range: range).compactMap { match in
            guard let numberRange = Range(match.range, in: line) else { return nil }
            return Int(String(line[numberRange]))
        }
    }

    private nonisolated static func parseBenchmarkDictionaryRow(_ line: String) -> SevenZipBenchmarkDictionaryRow? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^\d+:"# , options: .regularExpression) != nil else { return nil }
        let values = integers(in: trimmed)
        guard values.count >= 9 else { return nil }
        let compression = SevenZipBenchmarkMetrics(
            speedKiBPerSecond: values[1],
            usagePercent: values[2],
            ratingMips: values[3],
            usageRatingMips: values[4]
        )
        let decompression = SevenZipBenchmarkMetrics(
            speedKiBPerSecond: values[5],
            usagePercent: values[6],
            ratingMips: values[7],
            usageRatingMips: values[8]
        )
        return SevenZipBenchmarkDictionaryRow(dictionaryBits: values[0], compression: compression, decompression: decompression)
    }

    private nonisolated static func parseFrequencySample(_ line: String) -> SevenZipCPUFrequencySample? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("CPU Freq (MHz):"), let colonIndex = trimmed.firstIndex(of: ":") else { return nil }
        let label = String(trimmed[..<colonIndex])
        let values = String(trimmed[trimmed.index(after: colonIndex)...])
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !values.isEmpty else { return nil }
        return SevenZipCPUFrequencySample(threadLabel: label, readings: values)
    }

    private nonisolated static func cpuDescriptionLine(in lines: [String], after pageSizeLine: String?) -> String? {
        guard let pageSizeLine, let pageIndex = lines.firstIndex(of: pageSizeLine) else { return nil }
        return lines
            .dropFirst(pageIndex + 1)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private nonisolated static func timeValue(in lines: [String], prefix: String) -> Double? {
        guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard
            let match = timeValueRegex.firstMatch(in: line, range: range),
            let valueRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }
        return Double(line[valueRange])
    }

    // MARK: - 测试失败归类（0.4.2 批量测试）

    /// 把一次 `test` 失败的错误文本归类成用户能行动的桶 —— 批量测试汇总用。
    /// 启发式匹配 7zz / unzip 的英文诊断词（后端输出不本地化），匹配不上回落 `.other`。
    /// 顺序有意义：口令类词优先（加密包测试常同时报 CRC 错，根因是口令）。
    nonisolated static func classifyTestFailure(_ message: String) -> ArchiveTestFailureKind {
        let lower = message.lowercased()
        if lower.contains("wrong password")
            || lower.contains("incorrect password")
            || lower.contains("enter password")
            || lower.contains("cannot open encrypted")
            || lower.contains("password is required") {
            return .encrypted
        }
        if lower.contains("missing volume") || lower.contains("cannot find volume") {
            return .missingVolume
        }
        if lower.contains("cannot open the file as archive")
            || lower.contains("cannot open the file as [")
            || lower.contains("is not supported archive")
            || lower.contains("unsupported archive")
            || lower.contains("unsupported method")
            || lower.contains("unsupported feature") {
            return .unsupported
        }
        if lower.contains("crc failed")
            || lower.contains("data error")
            || lower.contains("headers error")
            || lower.contains("unexpected end of archive")
            || lower.contains("unexpected end of data")
            || lower.contains("unconfirmed start of archive")
            || lower.contains("there are some data after the end")
            || lower.contains("archive is broken") {
            return .corrupted
        }
        return .other
    }
}

/// 批量测试的失败桶。rawValue 直接拼 L10n key（`test.failure.<rawValue>`）。
enum ArchiveTestFailureKind: String, CaseIterable {
    case encrypted
    case missingVolume
    case corrupted
    case unsupported
    case other
}

private extension Data {
    nonisolated func zipByte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else {
            return nil
        }
        return self[startIndex + offset]
    }

    nonisolated func zipUInt16(at offset: Int) -> UInt16? {
        guard let byte0 = zipByte(at: offset),
              let byte1 = zipByte(at: offset + 1) else {
            return nil
        }
        return UInt16(byte0) | (UInt16(byte1) << 8)
    }

    nonisolated func zipUInt32(at offset: Int) -> UInt32? {
        guard let byte0 = zipByte(at: offset),
              let byte1 = zipByte(at: offset + 1),
              let byte2 = zipByte(at: offset + 2),
              let byte3 = zipByte(at: offset + 3) else {
            return nil
        }
        return UInt32(byte0) | (UInt32(byte1) << 8) | (UInt32(byte2) << 16) | (UInt32(byte3) << 24)
    }
}

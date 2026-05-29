//
//  ArchiveService+Parsing.swift
//  SimpleZip
//
//  Created by Copilot on 2026/05/28.
//

import Foundation

extension ArchiveService {
    static func detectZipEncryption(in archive: URL) -> ZipEncryptionDetection {
        guard archive.pathExtension.lowercased() == "zip" else {
            return .unknown
        }

        do {
            let data = try Data(contentsOf: archive, options: .mappedIfSafe)
            guard let centralDirectory = zipCentralDirectory(in: data) else {
                return .unknown
            }

            var detectedMethods: Set<ZipEncryptionDetection> = []
            var offset = centralDirectory.offset
            let endOffset = min(centralDirectory.offset + centralDirectory.size, data.count)

            while offset + 46 <= endOffset, data.zipUInt32(at: offset) == 0x02014b50 {
                let flags = data.zipUInt16(at: offset + 8) ?? 0
                let fileNameLength = Int(data.zipUInt16(at: offset + 28) ?? 0)
                let extraLength = Int(data.zipUInt16(at: offset + 30) ?? 0)
                let commentLength = Int(data.zipUInt16(at: offset + 32) ?? 0)
                let extraOffset = offset + 46 + fileNameLength
                let nextOffset = extraOffset + extraLength + commentLength
                guard nextOffset <= endOffset else {
                    break
                }

                if flags & 0x0001 == 0 {
                    detectedMethods.insert(.none)
                } else if let aesMethod = zipAESDetection(in: data, offset: extraOffset, length: extraLength) {
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

    static func parseZipList(tarOutput: String, unzipOutput: String) -> [ArchiveItem] {
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

    static func parseUnzipList(_ output: String) -> [ArchiveItem] {
        output
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
                    modified: parseUnzipModified(modifiedText),
                    sizeText: isDirectory ? "" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                    modifiedText: modifiedText,
                    method: isDirectory ? "" : "Deflate"
                )
            }
    }

    static func parseSevenZipList(_ output: String) -> [ArchiveItem] {
        // 当 list 走密码路径时（runWithPseudoTerminal），底层 PTY 在 macOS 默认 ONLCR
        // 状态下会把 7zz 输出里的每个 \n 转成 \r\n。下面按 \n 分行后每行末尾会留 \r：
        //   1) 含 \r 的「空白分隔行」(只有 "\r") 不再触发 flush()，多个条目的 values 互相覆盖；
        //   2) 即便最终能 flush 出来，Path / Method 这些 value 也带 \r 尾，触发 ArchiveSafety 误判。
        // 这里在解析前把所有 \r 剔除掉 —— 7z 输出里 \r 不会出现在文件名里（合法路径不允许）。
        let output = output.replacingOccurrences(of: "\r", with: "")
        var rows: [ArchiveItem] = []
        var values: [String: String] = [:]

        func flush() {
            guard let rawPath = values["Path"] else {
                values.removeAll()
                return
            }
            let path = decodeArchivePathEscapes(rawPath)
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
            let isDirectory = values["Folder"] == "+"
            let modifiedText = values["Modified"] ?? ""
            rows.append(
                ArchiveItem(
                    name: path,
                    isDirectory: isDirectory,
                    size: isDirectory ? nil : size,
                    modified: parseSevenZipModified(modifiedText),
                    sizeText: isDirectory ? "" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                    modifiedText: modifiedText,
                    method: values["Method"] ?? "",
                    isEncrypted: values["Encrypted"] == "+" || archiveMethodSuggestsEncryption(values["Method"] ?? "")
                )
            )
            values.removeAll()
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.isEmpty {
                flush()
                continue
            }

            let parts = text.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                values[parts[0]] = parts[1]
            }
        }

        flush()
        return rows
    }

    static func archiveItemsSuggestPasswordRequirement(_ items: [ArchiveItem], in archive: URL) -> Bool {
        if archive.pathExtension.lowercased() == "zip" {
            let detection = detectZipEncryption(in: archive)
            return detection != .none && detection != .unknown
        }
        return items.contains { $0.isEncrypted || archiveMethodSuggestsEncryption($0.method) }
    }

    private static func decodeArchivePathEscapes(_ text: String) -> String {
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

    private static func archiveMethodSuggestsEncryption(_ method: String) -> Bool {
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

    static func expandedEntryNames(for entries: [ArchiveItem]) -> [String] {
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

    static func normalizedDirectoryPrefix(_ name: String) -> String {
        let normalized = normalizedEntryName(name)
        return normalized.hasSuffix("/") ? normalized : normalized + "/"
    }

    static func normalizedEntryName(_ name: String) -> String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + (name.hasSuffix("/") ? "/" : "")
    }

    private static func zipCentralDirectory(in data: Data) -> (offset: Int, size: Int)? {
        guard data.count >= 22 else {
            return nil
        }

        let searchStart = max(0, data.count - 65_557)
        var offset = data.count - 22
        while offset >= searchStart {
            if data.zipUInt32(at: offset) == 0x06054b50 {
                let size = Int(data.zipUInt32(at: offset + 12) ?? 0)
                let directoryOffset = Int(data.zipUInt32(at: offset + 16) ?? 0)
                guard directoryOffset >= 0, size >= 0, directoryOffset + size <= data.count else {
                    return nil
                }
                return (directoryOffset, size)
            }
            offset -= 1
        }
        return nil
    }

    private static func zipAESDetection(in data: Data, offset: Int, length: Int) -> ZipEncryptionDetection? {
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

    private static func parseUnzipModified(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd-yyyy HH:mm"
        return formatter.date(from: text)
    }

    private static func parseSevenZipModified(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss.SSSSSS",
            "yyyy-MM-dd HH:mm:ss.SSSSSSS"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    private nonisolated static func integers(in line: String) -> [Int] {
        let pattern = #"\d+"#
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: line, range: range).compactMap { match in
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
        let pattern = #"=\s*([0-9]+(?:\.[0-9]+)?)"#
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(in: line, range: range),
            let valueRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }
        return Double(line[valueRange])
    }
}

private extension Data {
    func zipByte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else {
            return nil
        }
        return self[startIndex + offset]
    }

    func zipUInt16(at offset: Int) -> UInt16? {
        guard let byte0 = zipByte(at: offset),
              let byte1 = zipByte(at: offset + 1) else {
            return nil
        }
        return UInt16(byte0) | (UInt16(byte1) << 8)
    }

    func zipUInt32(at offset: Int) -> UInt32? {
        guard let byte0 = zipByte(at: offset),
              let byte1 = zipByte(at: offset + 1),
              let byte2 = zipByte(at: offset + 2),
              let byte3 = zipByte(at: offset + 3) else {
            return nil
        }
        return UInt32(byte0) | (UInt32(byte1) << 8) | (UInt32(byte2) << 16) | (UInt32(byte3) << 24)
    }
}

//
//  ArchiveOperationOptions.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Combine
import Foundation

/// 创建压缩包时可选择的格式。
enum ArchiveCreateFormat: String, CaseIterable, Identifiable {
    case zip
    case sevenZip = "7z"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zip:
            return "ZIP"
        case .sevenZip:
            return "7z"
        }
    }

    var pathExtension: String { rawValue }
}

/// 压缩等级。数值直接映射到 zip/7zz 的常用等级。
enum CompressionLevel: Int, CaseIterable, Identifiable {
    case store = 0
    case fast = 1
    case normal = 5
    case maximum = 9

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .store:
            return L10n.text("archive.level.store")
        case .fast:
            return L10n.text("archive.level.fast")
        case .normal:
            return L10n.text("archive.level.normal")
        case .maximum:
            return L10n.text("archive.level.maximum")
        }
    }
}

enum SevenZipCompressionMethod: String, CaseIterable, Identifiable {
    case automatic
    case lzma2
    case lzma
    case ppmd
    case bzip2
    case deflate
    case copy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return L10n.text("archive.7z.method.automatic")
        case .lzma2:
            return "LZMA2"
        case .lzma:
            return "LZMA"
        case .ppmd:
            return "PPMd"
        case .bzip2:
            return "BZip2"
        case .deflate:
            return "Deflate"
        case .copy:
            return L10n.text("archive.7z.method.copy")
        }
    }

    var argumentValue: String? {
        switch self {
        case .automatic:
            return nil
        case .lzma2:
            return "LZMA2"
        case .lzma:
            return "LZMA"
        case .ppmd:
            return "PPMd"
        case .bzip2:
            return "BZip2"
        case .deflate:
            return "Deflate"
        case .copy:
            return "Copy"
        }
    }
}

/// 创建压缩包时收集的选项。
struct ArchiveCreationOptions {
    var format: ArchiveCreateFormat = .zip
    var compressionLevel: CompressionLevel = .normal
    var password = ""
    var skipDSStore = true
    var skipHiddenFiles = true
    var customExcludes = ""
    var sevenZipMethod: SevenZipCompressionMethod = .automatic
    var sevenZipThreadCount = 0
    var sevenZipSolidArchive = true
    var sevenZipEncryptFileNames = true
    var sevenZipVolumeSize = ""
}

/// 创建压缩包的待确认请求。
struct ArchiveCreationRequest: Identifiable {
    let id = UUID()
    let sourceURLs: [URL]
    let directoryURL: URL
    var destinationURL: URL
    var options = ArchiveCreationOptions()
}

/// 整包解压的待确认请求。
struct ExtractArchiveRequest: Identifiable {
    let id = UUID()
    let archiveURL: URL
    var destinationURL: URL
    var password = ""
}

/// 选中解压时的目录处理方式。
enum ExtractPathMode: String, CaseIterable, Identifiable {
    case preserve
    case flatten

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preserve:
            return L10n.text("extract.path.preserve")
        case .flatten:
            return L10n.text("extract.path.flatten")
        }
    }
}

/// 选中解压的待确认请求。
struct ExtractSelectionRequest: Identifiable {
    let id = UUID()
    let archiveURL: URL
    let entries: [ArchiveItem]
    var destinationURL: URL
    var pathMode: ExtractPathMode = .preserve
    var password = ""
}

/// 压缩/解压过程中的进度信息。
struct ArchiveProgressState {
    var fraction: Double?
    var currentFile: String?
    var statusText: String?
}

struct SevenZipBenchmarkMetrics {
    let speedKiBPerSecond: Int
    let usagePercent: Int
    let ratingMips: Int
    let usageRatingMips: Int
}

struct SevenZipBenchmarkOptions {
    var dictionarySizeMB = 32
    var threadCount = 0
}

struct SevenZipBenchmarkRequest: Identifiable {
    let id = UUID()
    var options = SevenZipBenchmarkOptions()
}

@MainActor
final class SevenZipBenchmarkSession: ObservableObject, Identifiable {
    let id = UUID()
    let options: SevenZipBenchmarkOptions
    let startedAt = Date()
    @Published var finishedAt: Date?
    @Published var report: SevenZipBenchmarkReport?
    @Published var rawOutput = ""

    init(options: SevenZipBenchmarkOptions) {
        self.options = options
    }

    var isRunning: Bool {
        finishedAt == nil
    }
}

struct SevenZipBenchmarkDictionaryRow: Identifiable {
    let id = UUID()
    let dictionaryBits: Int
    let compression: SevenZipBenchmarkMetrics
    let decompression: SevenZipBenchmarkMetrics
}

struct SevenZipCPUFrequencySample: Identifiable {
    let id = UUID()
    let threadLabel: String
    let readings: [String]
}

struct SevenZipBenchmarkReport: Identifiable {
    let id = UUID()
    let backendDescription: String
    let options: SevenZipBenchmarkOptions
    let compilerDescription: String?
    let systemDescription: String?
    let cpuDescription: String?
    let pageSizeText: String?
    let ramUsageMB: Int?
    let ramSizeMB: Int?
    let hardwareThreads: Int?
    let benchmarkThreads: Int?
    let frequencySamples: [SevenZipCPUFrequencySample]
    let dictionaryRows: [SevenZipBenchmarkDictionaryRow]
    let compressionAverage: SevenZipBenchmarkMetrics?
    let decompressionAverage: SevenZipBenchmarkMetrics?
    let totalRatingMips: Int?
    let totalUsagePercent: Int?
    let kernelTimeSeconds: Double?
    let userTimeSeconds: Double?
    let processTimeSeconds: Double?
    let globalTimeSeconds: Double?
    let output: String
}

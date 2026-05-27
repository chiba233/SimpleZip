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
    case rar
    case tar
    case gzip = "gz"
    case tarGzip = "tgz"
    case bzip2 = "bz2"
    case xz

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zip:
            return "ZIP"
        case .sevenZip:
            return "7z"
        case .rar:
            return "RAR"
        case .tar:
            return "TAR"
        case .gzip:
            return "GZip"
        case .tarGzip:
            return "TAR.GZ"
        case .bzip2:
            return "BZip2"
        case .xz:
            return "XZ"
        }
    }

    var pathExtension: String { rawValue }

    var usesSevenZipAdvancedOptions: Bool {
        self == .sevenZip
    }

    var supportsPassword: Bool {
        switch self {
        case .zip, .sevenZip, .rar:
            return true
        case .tar, .gzip, .tarGzip, .bzip2, .xz:
            return false
        }
    }

    var supportsCompressionLevel: Bool {
        switch self {
        case .tar, .tarGzip:
            return false
        case .zip, .sevenZip, .rar, .gzip, .bzip2, .xz:
            return true
        }
    }

    var supportsExcludeRules: Bool {
        switch self {
        case .zip, .sevenZip, .tar, .tarGzip, .rar:
            return true
        case .gzip, .bzip2, .xz:
            return false
        }
    }

    var supportsVolumeSplitting: Bool {
        switch self {
        case .zip, .sevenZip, .rar:
            return true
        case .tar, .gzip, .tarGzip, .bzip2, .xz:
            return false
        }
    }

    var supportsUpdateMode: Bool {
        switch self {
        case .zip, .sevenZip, .rar:
            return true
        case .tar, .gzip, .tarGzip, .bzip2, .xz:
            return false
        }
    }

    var supportsSFX: Bool {
        switch self {
        case .sevenZip, .rar:
            return true
        case .zip, .tar, .gzip, .tarGzip, .bzip2, .xz:
            return false
        }
    }

    var supportsRawParameters: Bool {
        switch self {
        case .zip, .sevenZip, .rar:
            return true
        case .tar, .gzip, .tarGzip, .bzip2, .xz:
            return false
        }
    }

    var requiresSingleRegularFile: Bool {
        switch self {
        case .gzip, .bzip2, .xz:
            return true
        case .zip, .sevenZip, .rar, .tar, .tarGzip:
            return false
        }
    }
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

enum SevenZipPathMode: String, CaseIterable, Identifiable {
    case relative
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relative:
            return L10n.text("archive.7z.pathMode.relative")
        case .full:
            return L10n.text("archive.7z.pathMode.full")
        }
    }
}

enum SevenZipSolidBlockSize: String, CaseIterable, Identifiable {
    case automatic
    case size1m = "1m"
    case size4m = "4m"
    case size16m = "16m"
    case size64m = "64m"
    case size256m = "256m"
    case size1g = "1g"
    case size4g = "4g"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return L10n.text("archive.7z.method.automatic")
        case .size1m:
            return "1 MB"
        case .size4m:
            return "4 MB"
        case .size16m:
            return "16 MB"
        case .size64m:
            return "64 MB"
        case .size256m:
            return "256 MB"
        case .size1g:
            return "1 GB"
        case .size4g:
            return "4 GB"
        }
    }

    var argumentValue: String? {
        self == .automatic ? nil : rawValue
    }
}

enum ArchiveUpdateMode: String, CaseIterable, Identifiable {
    case addAndReplace
    case updateAndAdd
    case freshen
    case synchronize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .addAndReplace:
            return L10n.text("archive.updateMode.addAndReplace")
        case .updateAndAdd:
            return L10n.text("archive.updateMode.updateAndAdd")
        case .freshen:
            return L10n.text("archive.updateMode.freshen")
        case .synchronize:
            return L10n.text("archive.updateMode.synchronize")
        }
    }
}

enum ArchiveEncryptionMethod: String, CaseIterable, Identifiable {
    case zipCrypto
    case aes128
    case aes192
    case aes256

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zipCrypto:
            return L10n.text("archive.encryption.zipCrypto")
        case .aes128:
            return "AES-128"
        case .aes192:
            return "AES-192"
        case .aes256:
            return "AES-256"
        }
    }

    var zipArgumentValue: String {
        switch self {
        case .zipCrypto:
            return "ZipCrypto"
        case .aes128:
            return "AES128"
        case .aes192:
            return "AES192"
        case .aes256:
            return "AES256"
        }
    }
}

/// 创建压缩包时收集的选项。
struct ArchiveCreationOptions {
    var format: ArchiveCreateFormat = .zip
    var compressionLevel: CompressionLevel = .normal
    var password = ""
    var passwordConfirmation = ""
    var showPassword = false
    var showDetails = false
    var skipDSStore = true
    var skipHiddenFiles = false
    var customExcludes = ""
    var updateMode: ArchiveUpdateMode = .addAndReplace
    var createSFXArchive = false
    var rawParameters = ""
    var encryptionMethod: ArchiveEncryptionMethod = .aes256
    var sevenZipMethod: SevenZipCompressionMethod = .automatic
    var sevenZipDictionarySizeMB = 32
    var sevenZipWordSize = 32
    var sevenZipThreadCount = 0
    var sevenZipSolidArchive = true
    var sevenZipSolidBlockSize: SevenZipSolidBlockSize = .automatic
    var sevenZipEncryptFileNames = true
    var sevenZipVolumeSize = ""
    var sevenZipPathMode: SevenZipPathMode = .relative
    var sevenZipStoreSymbolicLinks = false
    var sevenZipStoreHardLinks = false
    var sevenZipCompressSharedFiles = false
    var sevenZipDeleteSourceFiles = false
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
    var zipDecryptionMethod: ArchiveDecryptionMethod = .automatic
    var detectedZipEncryption: ZipEncryptionDetection = .unknown
    var showDetails = false
}

/// ZIP 解密方式。实际 ZIP 文件会记录具体算法；选择项用于决定兼容解压路径。
enum ArchiveDecryptionMethod: String, CaseIterable, Identifiable {
    case automatic
    case zipCrypto
    case aes128
    case aes192
    case aes256

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return L10n.text("extract.decryption.automatic")
        case .zipCrypto:
            return L10n.text("archive.encryption.zipCrypto")
        case .aes128:
            return "AES-128"
        case .aes192:
            return "AES-192"
        case .aes256:
            return "AES-256"
        }
    }
}

/// 从 ZIP 元数据检测到的加密算法。
enum ZipEncryptionDetection: Hashable {
    case unknown
    case none
    case zipCrypto
    case aes128
    case aes192
    case aes256
    case mixed

    var title: String {
        switch self {
        case .unknown:
            return L10n.text("extract.decryption.unknown")
        case .none:
            return L10n.text("extract.decryption.none")
        case .zipCrypto:
            return L10n.text("archive.encryption.zipCrypto")
        case .aes128:
            return "AES-128"
        case .aes192:
            return "AES-192"
        case .aes256:
            return "AES-256"
        case .mixed:
            return L10n.text("extract.decryption.mixed")
        }
    }

    var autoDetectionText: String {
        L10n.format("extract.decryption.detected", title)
    }
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
    var zipDecryptionMethod: ArchiveDecryptionMethod = .automatic
    var detectedZipEncryption: ZipEncryptionDetection = .unknown
    var showDetails = false
}

/// 压缩/解压过程中的进度信息。
struct ArchiveProgressState {
    var fraction: Double?
    var currentFile: String?
    var statusText: String?
    var completedUnitCount: Int?
    var totalUnitCount: Int?
}

@MainActor
final class ArchiveOperationDetailsSession: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    let startedAt = Date()
    @Published var finishedAt: Date?
    @Published var rawOutput = ""

    init(title: String) {
        self.title = title
    }

    var isRunning: Bool {
        finishedAt == nil
    }

    func append(_ chunk: String) {
        rawOutput += chunk
    }
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

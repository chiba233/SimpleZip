//
//  FormatCapabilityMatrix.swift
//  SimpleZip
//
//  「格式能力矩阵」的**纯数据**——每种容器各自支持哪些操作（创建 / 解压 / 加密 / 头部加密 / 分卷 /
//  测试 / 注释）。设置里用它渲染一张对照表，帮用户（和我们自己）一眼看清各格式边界。
//
//  事实来源：7-Zip / RAR 家族的「创建侧」能力尽量复用 `ArchiveCreateFormat` 已有属性（不另立一份事实，
//  避免两处漂移），其余按各后端实际行为静态声明。RAR 创建是 `.conditional`——只有用户自己装了 rar 二进制才行。
//

import Foundation

/// 单格 capability 的三态。`.conditional` = 支持但有前置条件（如 RAR 创建需用户安装 rar）。
public enum CapabilityState: String, Hashable {
    case yes
    case no
    case conditional
}

/// 矩阵的一列（一种能力维度）。
public enum FormatCapabilityKind: String, CaseIterable, Identifiable {
    case create        // 创建 / 打包
    case extract       // 解压 / 打开
    case editEntries   // 打开后增 / 替换条目（拖入、归档内编辑写回）—— 仅 7zz 可写的 zip/7z
    case encrypt       // 加密（口令对称 或 GPG 公钥）
    case headerEncrypt // 头部 / 文件名加密
    case splitVolumes  // 分卷
    case test          // 完整性测试 / 验签
    case comment       // 归档注释

    public var id: String { rawValue }
}

/// 矩阵的一行（一种容器格式）。`displayName` 是格式专有名（不本地化）；能力按列给三态。
public struct FormatCapabilityRow: Identifiable, Hashable {
    public let id: String
    public let displayName: String
    public let create: CapabilityState
    public let extract: CapabilityState
    public let editEntries: CapabilityState
    public let encrypt: CapabilityState
    public let headerEncrypt: CapabilityState
    public let splitVolumes: CapabilityState
    public let test: CapabilityState
    public let comment: CapabilityState

    public func state(for kind: FormatCapabilityKind) -> CapabilityState {
        switch kind {
        case .create: return create
        case .extract: return extract
        case .editEntries: return editEntries
        case .encrypt: return encrypt
        case .headerEncrypt: return headerEncrypt
        case .splitVolumes: return splitVolumes
        case .test: return test
        case .comment: return comment
        }
    }
}

public enum FormatCapabilityMatrix {
    /// 把 `ArchiveCreateFormat` 的布尔能力翻成三态（创建侧用 RAR 的 `.conditional`）。
    private static func createState(_ format: ArchiveCreateFormat) -> CapabilityState {
        format == .rar ? .conditional : .yes
    }

    private static func encryptState(_ format: ArchiveCreateFormat) -> CapabilityState {
        format.supportsPassword ? .yes : .no
    }

    private static func splitState(_ format: ArchiveCreateFormat) -> CapabilityState {
        format.supportsVolumeSplitting ? .yes : .no
    }

    /// 「打开后增 / 替换条目」能力 —— 跟 `ArchiveService.supportsEntryUpdate` 同口径:仅 zip/7z(7zz 可写)。
    private static func editState(_ format: ArchiveCreateFormat) -> CapabilityState {
        (format == .zip || format == .sevenZip) ? .yes : .no
    }

    /// 全部行。7-Zip / RAR / TAR 家族 + DMG 走标准列；GPG / SIZ / SZS 是 SimpleZip 的容器，
    /// 「加密」列指它们的 GPG 加密、「测试」列指验签（密码学完整性校验）。
    public static var rows: [FormatCapabilityRow] {
        [
            standardRow(.zip,
                        extract: .yes, headerEncrypt: .no, test: .yes, comment: .yes),
            standardRow(.sevenZip,
                        extract: .yes, headerEncrypt: .yes, test: .yes, comment: .no),
            standardRow(.rar,
                        extract: .yes, headerEncrypt: .yes, test: .yes, comment: .yes),
            standardRow(.tar,
                        extract: .yes, headerEncrypt: .no, test: .yes, comment: .no),
            standardRow(.tarGzip,
                        extract: .yes, headerEncrypt: .no, test: .yes, comment: .no),
            // DMG：app 内创建（hdiutil）+ 挂载浏览；不做口令加密 / 分卷 / 注释 / 编辑。
            FormatCapabilityRow(id: "dmg", displayName: "DMG",
                                create: .yes, extract: .yes, editEntries: .no, encrypt: .no, headerEncrypt: .no,
                                splitVolumes: .no, test: .no, comment: .no),
            // XIP：Apple 签名归档（Xcode 分发用）。只读：可浏览（xar 容器）/ 解压（系统校验 Apple 签名）/
            // 测试（xar 校验和）；创建需 Apple 证书，不提供。
            FormatCapabilityRow(id: "xip", displayName: "XIP",
                                create: .no, extract: .yes, editEntries: .no, encrypt: .no, headerEncrypt: .no,
                                splitVolumes: .no, test: .yes, comment: .no),
            // .gpg：加密 = 创建、解密 = 打开；GPG 容器没有头部加密 / 分卷 / 注释 / 编辑概念。
            FormatCapabilityRow(id: "gpg", displayName: ".gpg",
                                create: .yes, extract: .yes, editEntries: .no, encrypt: .yes, headerEncrypt: .no,
                                splitVolumes: .no, test: .no, comment: .no),
            // .siz：签名容器（内层 archive + 签名 + 元数据）；测试 = 验签；可选 GPG 公钥加密内层。编辑会破坏签名 → 不开放。
            FormatCapabilityRow(id: "siz", displayName: ".siz",
                                create: .yes, extract: .yes, editEntries: .no, encrypt: .yes, headerEncrypt: .no,
                                splitVolumes: .no, test: .yes, comment: .no),
            // .szs：签名清单（clearsigned JSON）；测试 = 验签；可选把列出文件加密成 .gpg。编辑会破坏签名 → 不开放。
            FormatCapabilityRow(id: "szs", displayName: ".szs",
                                create: .yes, extract: .yes, editEntries: .no, encrypt: .yes, headerEncrypt: .no,
                                splitVolumes: .no, test: .yes, comment: .no),
        ]
    }

    /// 7-Zip / RAR / TAR 家族行：创建 / 加密 / 分卷复用 `ArchiveCreateFormat`，其余显式给。
    private static func standardRow(
        _ format: ArchiveCreateFormat,
        extract: CapabilityState,
        headerEncrypt: CapabilityState,
        test: CapabilityState,
        comment: CapabilityState
    ) -> FormatCapabilityRow {
        FormatCapabilityRow(
            id: format.rawValue,
            displayName: format.title,
            create: createState(format),
            extract: extract,
            editEntries: editState(format),
            encrypt: encryptState(format),
            headerEncrypt: headerEncrypt,
            splitVolumes: splitState(format),
            test: test,
            comment: comment
        )
    }
}

// MARK: - 转换保真度（0.4.2 #13）

/// 转换目标格式能**保留 / 支持**哪些语义 —— 7zz / hdiutil 实际行为的静态知识表。
/// 转换 = 解压 → 重打包：目标格式不支持的语义（如 tar 无加密、gz 无目录结构权限）在转换中丢失。
struct ConversionFidelity: Equatable {
    let preservesPermissions: Bool
    let preservesSymlinks: Bool
    let preservesModificationDates: Bool
    let supportsEncryption: Bool
    let supportsArchiveComment: Bool
    let supportsMultiVolume: Bool
}

extension ArchiveCreateFormat {
    /// 该格式作为**转换目标**时的保真度。
    var conversionFidelity: ConversionFidelity {
        switch self {
        case .zip:
            // 7zz 在 zip 的 unix 扩展属性里存权限 / 符号链接；注释（EOCD）可读可写；分卷可创建。
            return ConversionFidelity(preservesPermissions: true, preservesSymlinks: true, preservesModificationDates: true,
                                      supportsEncryption: true, supportsArchiveComment: true, supportsMultiVolume: true)
        case .sevenZip:
            return ConversionFidelity(preservesPermissions: true, preservesSymlinks: true, preservesModificationDates: true,
                                      supportsEncryption: true, supportsArchiveComment: false, supportsMultiVolume: true)
        case .rar:
            // rar 工具支持注释,但 SimpleZip 当前只读不写。
            return ConversionFidelity(preservesPermissions: true, preservesSymlinks: true, preservesModificationDates: true,
                                      supportsEncryption: true, supportsArchiveComment: true, supportsMultiVolume: true)
        case .tar, .tarGzip:
            return ConversionFidelity(preservesPermissions: true, preservesSymlinks: true, preservesModificationDates: true,
                                      supportsEncryption: false, supportsArchiveComment: false, supportsMultiVolume: false)
        case .gzip:
            // 单文件流：没有条目结构。gzip 头存一份 mtime。
            return ConversionFidelity(preservesPermissions: false, preservesSymlinks: false, preservesModificationDates: true,
                                      supportsEncryption: false, supportsArchiveComment: false, supportsMultiVolume: false)
        case .bzip2, .xz:
            return ConversionFidelity(preservesPermissions: false, preservesSymlinks: false, preservesModificationDates: false,
                                      supportsEncryption: false, supportsArchiveComment: false, supportsMultiVolume: false)
        case .dmg:
            // APFS/HFS+ 镜像：文件系统语义全保留；SimpleZip 不创建加密 DMG / 不分卷。
            return ConversionFidelity(preservesPermissions: true, preservesSymlinks: true, preservesModificationDates: true,
                                      supportsEncryption: false, supportsArchiveComment: false, supportsMultiVolume: false)
        }
    }
}

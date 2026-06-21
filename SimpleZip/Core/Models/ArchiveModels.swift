//
//  ArchiveModels.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation
import UniformTypeIdentifiers

/// 文件夹浏览模式下的一行文件或文件夹。
struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let displayName: String
    let isDirectory: Bool
    /// 是否是 macOS「包」（.app/.bundle 等）。**列目录时判定一次存下来** —— 以前排序比较器 /
    /// 表格每行 / 拖拽校验都现场 resolvingSymlinksInPath + LaunchServices 查询，大目录直接卡死
    ///（用户抓到 Task 卡在 _NSTransmutePathSlashes 里被 SIGTERM）。
    let isPackage: Bool
    let isSymbolicLink: Bool
    /// 符号链接目标路径（仅 `isSymbolicLink` 时非空）—— 可选「符号链接目标」列展示。本地文件的「访问时间」
    /// 已由现有「最近打开」列(contentAccessDate)覆盖，故文件浏览不再单列 Accessed。
    let symlinkTarget: String
    /// 是否算隐藏。判定方式由用户偏好 `hiddenDetectionMode` 决定：
    /// `.dotfilesOnly`（默认）仅看名字是否以 . 开头；`.macOSHidden` 再算上 macOS UF_HIDDEN 标志。
    /// 0.2.0：开启「显示隐藏文件」后，隐藏项不再平铺，而是收进默认折叠的「隐藏文件」分组节点。
    let isHidden: Bool
    let size: Int64?
    let modified: Date?
    let created: Date?
    let dateAdded: Date?
    let lastOpened: Date?
    let typeDescription: String
    let applicationName: String
    /// Unix 权限串（`-rw-r--r--` / `drwxr-xr-x` / `lrwxr-xr-x`）—— 可选「权限」列展示。取不到时为空。
    let permissions: String
    /// 属主用户名（取不到时退回数字 uid 字符串）—— 可选「属主」列展示。
    let owner: String

    nonisolated init(
        url: URL,
        name: String,
        displayName: String,
        isDirectory: Bool,
        isPackage: Bool = false,
        isSymbolicLink: Bool,
        symlinkTarget: String,
        isHidden: Bool,
        size: Int64?,
        modified: Date?,
        created: Date?,
        dateAdded: Date?,
        lastOpened: Date?,
        typeDescription: String,
        applicationName: String,
        permissions: String = "",
        owner: String = ""
    ) {
        self.url = url
        self.name = name
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.symlinkTarget = symlinkTarget
        self.isHidden = isHidden
        self.size = size
        self.modified = modified
        self.created = created
        self.dateAdded = dateAdded
        self.lastOpened = lastOpened
        self.typeDescription = typeDescription
        self.applicationName = applicationName
        self.permissions = permissions
        self.owner = owner
    }
}

/// 地址栏补全候选项。
struct LocationCompletion: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let displayName: String
    let path: String
}

/// 压缩包浏览模式下的一行归档内项目。
///
/// 0.1.10 起：除了基础 4 列（kind/size/modified/method）以外，再保留可选的 packedSize/CRC/created/attributes
/// —— 这些字段只有 7zz `-slt` 长格式才有，zip 后备路径和 DMG 后端会用 nil / "" 填空，UI 自然显示空。
// `nonisolated`:app target 默认 MainActor 隔离会把整个类型(连同合成的 Equatable / Hashable 一致性)
// 隔到主 actor;nonisolated 解析链(parseSevenZipList / parseZipList 等)用到这些一致性时就会触发
// 「main actor-isolated conformance … cannot be used in nonisolated context」。所有存储属性都是不可变
// Sendable `let`,显式 `nonisolated` + `Sendable` 让该类型彻底无隔离,合成一致性在任何上下文都可用。
nonisolated struct ArchiveItem: Identifiable, Hashable, Codable, Sendable {
    let id = UUID()

    /// Codable 排除 `id`(带初值的 let 不能解码;id 只是行标识,解码时新发一个即可)。
    /// 0.4.4:为比较报告随任务历史持久化(重启后详情仍可看)而加。
    private enum CodingKeys: String, CodingKey {
        case name, isDirectory, size, modified, sizeText, modifiedText, method, isEncrypted
        case packedSize, packedSizeText, crc, created, createdText, attributes
        case accessed, accessedText, hostOS, characteristics, symlinkTarget, comment
    }
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    let sizeText: String
    let modifiedText: String
    let method: String
    let isEncrypted: Bool
    let packedSize: Int64?
    let packedSizeText: String
    let crc: String
    let created: Date?
    let createdText: String
    let attributes: String
    // 0.3.2 起的可选列（对照官方 7-Zip GUI）。都来自 7zz `-slt` 长格式；zip 后备路径 / DMG 后端留空。
    let accessed: Date?
    let accessedText: String
    /// 主操作系统（`Host OS`）—— 归档由哪个系统创建（Unix / FAT / NTFS …）。
    let hostOS: String
    /// 特征（`Characteristics`）—— 7zz 报告的条目内部标志位串。
    let characteristics: String
    /// 符号链接目标（`Symbolic Link`）—— 条目是符号链接时其指向；非符号链接为空。
    let symlinkTarget: String
    /// 条目注释（zip 的 per-entry `Comment`）—— 没有注释的格式 / 条目为空。
    let comment: String

    // `nonisolated`:文件夹快照(ArchiveDiff.folderItems)等后台路径需要在非主 actor 构造条目。
    nonisolated init(
        name: String,
        isDirectory: Bool,
        size: Int64?,
        modified: Date?,
        sizeText: String,
        modifiedText: String,
        method: String,
        isEncrypted: Bool = false,
        packedSize: Int64? = nil,
        packedSizeText: String = "",
        crc: String = "",
        created: Date? = nil,
        createdText: String = "",
        attributes: String = "",
        accessed: Date? = nil,
        accessedText: String = "",
        hostOS: String = "",
        characteristics: String = "",
        symlinkTarget: String = "",
        comment: String = ""
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.sizeText = sizeText
        self.modifiedText = modifiedText
        self.method = method
        self.isEncrypted = isEncrypted
        self.packedSize = packedSize
        self.packedSizeText = packedSizeText
        self.crc = crc
        self.created = created
        self.createdText = createdText
        self.attributes = attributes
        self.accessed = accessed
        self.accessedText = accessedText
        self.hostOS = hostOS
        self.characteristics = characteristics
        self.symlinkTarget = symlinkTarget
        self.comment = comment
    }

    /// 列表里只展示当前层级的名称，完整路径继续保留在 name 中用于解压。
    nonisolated var displayName: String {
        let trimmedName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmedName.split(separator: "/").last.map(String.init) ?? name
    }

    nonisolated var typeDescription: String {
        if isDirectory {
            return L10n.text("type.folder")
        }
        let ext = URL(fileURLWithPath: displayName).pathExtension
        if let description = UTType(filenameExtension: ext)?.localizedDescription {
            return description
        }
        if !ext.isEmpty {
            return ext.uppercased()
        }
        return L10n.text("type.file")
    }
}

/// 主列表当前展示的是普通文件夹，还是某个压缩包的内容。
/// 0.4.5 #80:AI 系统工作区类别(白皮书工程补充一 MVP —— 第一版只做确定性系统工作区,不做用户 prompt 创建)。
/// 纯枚举;每类的候选由 `AISuggestionFolderView` 从现有索引(失败任务等)确定性派生,只读。
enum AISystemWorkspaceKind: String, Codable, Equatable, CaseIterable, Sendable {
    /// 「需要处理」—— 最近失败的任务等需要用户关注的项。
    case needsAttention
    /// 「发布与校验」—— 最近的检查 / 测试 / 哈希 / 对比类任务(发布前的验证动作)。
    case releaseAndVerify
    /// 「最近的归档」—— 最近打开过、已建立非加密内容索引的归档。
    case recentArchives

    var systemImage: String {
        switch self {
        case .needsAttention: return "exclamationmark.circle"
        case .releaseAndVerify: return "checkmark.seal"
        case .recentArchives: return "clock.arrow.circlepath"
        }
    }
}

enum BrowserMode: Equatable {
    case folder(URL)
    case archive(URL)
    case tag(String)
    /// 0.4.5 #80 #89:AI 建议虚拟工作区(只读;白皮书建议四)。关联值是工作区 `UUID`(动态工作区,App 侧
    /// `AIWorkspaceStore` 回查;系统工作区的 UUID 由 `AIWorkspaceStore.systemID(kind)` 确定性派生)。
    /// **不复用 FileTable、不伪造 FileItem**;动作只允许打开 / 定位 / 解释,绝不改文件。
    case aiWorkspace(UUID)
}

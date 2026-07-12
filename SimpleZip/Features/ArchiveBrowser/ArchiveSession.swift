//
//  ArchiveSession.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

/// 当前打开的压缩包内容 + 浏览路径 + 派生计算。
///
/// 设计动机：ArchiveBrowserModel 之前一个人持有「打开了哪个 zip」「在哪一层」
/// 「整个条目列表」「合成目录」「展开选中目录」这些全部状态，加起来 600 行。
/// 把它们汇聚到一个 session 后，model 只需要关心 UI 状态和命令路由，
/// 测试也能直接构造 session 验证合成目录 / lastExistingPath 这些纯逻辑。
///
/// 没有用 ObservableObject —— model 仍然通过自己的 @Published `archiveItems`
/// 把视图刷新挂在原本的反应链上，避免把 session 嵌进 SwiftUI 观察拓扑里牵涉
/// nested observation 的复杂度。
@MainActor
final class ArchiveSession {
    /// 后端返回的完整条目列表（包括目录和文件）。可能缺少中间目录占位项。
    private(set) var allItems: [ArchiveItem] = []

    /// 用户当前在压缩包内浏览到的子路径，根层为 ""。带末尾 / 表示「这是目录前缀」。
    private(set) var archivePath: String = ""

    /// 当前归档的 ZIP 加密类型。打开时(`loadArchive`)在后台 off-main 检测**一次**并缓存;非 ZIP / 尚未检测 = `.unknown`。
    ///
    /// 动机:`ArchiveService.detectZipEncryption` 同步读整个 ZIP 中央目录(`Data(contentsOf:)` → 内核 read),
    /// 大包要几秒。解压 / 测试 / 打开条目 / 弹密码框等多处过去**各自**在主 actor 上同步调它(有的甚至同一包读两遍
    /// —— 显式调用 + 经 `archiveItemsSuggestPasswordRequirement` 再读一次),逐次卡死主线程。归档打开期间加密类型
    /// 不变,这里缓存一次供所有点复用。
    private(set) var detectedZipEncryption: ZipEncryptionDetection = .unknown

    /// `itemsWithSyntheticDirectories()` 的缓存:只依赖 `allItems`,但导航(切目录)只改 `archivePath` 不改 items ——
    /// 旧实现每次 `currentChildren()` / `lastExistingPath()` 都重建一遍合成目录(逐条 split + 建字典,大包上很贵),
    /// 同一归档里逐层下钻就重复重建 N 次。缓存一次,`setItems` / `clearArchive` 时失效。
    private var syntheticItemsCache: [ArchiveItem]?

    // MARK: - 状态变更

    func setItems(_ items: [ArchiveItem]) {
        allItems = items
        syntheticItemsCache = nil
    }

    func setArchivePath(_ path: String) {
        archivePath = path
    }

    /// 打开归档后写入后台检测出的 ZIP 加密类型(见 `detectedZipEncryption`)。
    func setDetectedZipEncryption(_ detection: ZipEncryptionDetection) {
        detectedZipEncryption = detection
    }

    /// 离开压缩包模式时调用，重置内容和层级。
    /// 不影响 mode / mountedDiskImage —— 那些归调用方管理。
    func clearArchive() {
        allItems = []
        archivePath = ""
        detectedZipEncryption = .unknown
        syntheticItemsCache = nil
    }

    // MARK: - 派生视图

    /// 当前 `archivePath` 这一层应当展示的直接子项。
    ///
    /// 调用方（model）拿到结果后赋给自己的 @Published archiveItems，UI 自动刷新。
    func currentChildren() -> [ArchiveItem] {
        immediateChildren(from: syntheticItems(), in: archivePath)
    }

    /// 把一条选中项展开成「具体落地的条目集合」：
    /// - 文件：原样返回；
    /// - 目录：展开为所有子项（recursive flatten）；
    /// - 目录但没有任何子项：返回目录本身，避免被吞掉而无法解压空目录。
    func expand(_ item: ArchiveItem) -> [ArchiveItem] {
        guard item.isDirectory else { return [item] }

        let prefix = Self.normalizedDirectoryPrefix(item.name)
        let children = allItems.filter { child in
            let childName = Self.normalizedEntryName(child.name, isDirectory: child.isDirectory)
            return childName.hasPrefix(prefix) && childName != prefix
        }
        return children.isEmpty ? [item] : children
    }

    /// 批量展开，去重并按名字自然排序。
    /// 用户多选了「目录 + 目录里的某个文件」时，去重避免后端重复处理。
    /// 单次遍历 `allItems`:目录前缀先收集,子项名只归一化一次 —— 逐项调 `expand(_:)` 会对每个选中目录
    /// 全量过滤一遍条目、每遍都重新构造归一化名(万条目 × 多目录时是热点)。集合语义与逐项展开
    /// 完全一致:空目录保留自身、嵌套重复由 Set 去重。
    func expand(_ items: [ArchiveItem]) -> [ArchiveItem] {
        var expanded: [ArchiveItem] = []
        var directories: [(item: ArchiveItem, prefix: String, hasChild: Bool)] = []
        for item in items {
            if item.isDirectory {
                directories.append((item, Self.normalizedDirectoryPrefix(item.name), false))
            } else {
                expanded.append(item)
            }
        }
        if !directories.isEmpty {
            for child in allItems {
                let childName = Self.normalizedEntryName(child.name, isDirectory: child.isDirectory)
                for i in directories.indices
                where childName.hasPrefix(directories[i].prefix) && childName != directories[i].prefix {
                    expanded.append(child)
                    directories[i].hasChild = true
                }
            }
            for dir in directories where !dir.hasChild {
                expanded.append(dir.item)
            }
        }
        return Array(Set(expanded)).sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - 路径操作

    /// 给定 archive 内一个子路径，返回它的父路径（带尾 /）；根层返回 ""。
    func parentPath(of path: String) -> String {
        let components = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map(String.init)
        guard components.count > 1 else { return "" }
        return components.dropLast().joined(separator: "/") + "/"
    }

    /// 用户在地址栏粘贴了一个 archive 内路径，沿着已存在的目录尽量向下走。
    /// 中间任意一段缺失就停 —— 不假定可以创建新目录。
    func lastExistingPath(for path: String) -> String {
        let components = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map(String.init)
        guard !components.isEmpty else { return "" }

        var candidate = ""
        let directories = Set(
            syntheticItems()
                .filter(\.isDirectory)
                .map { Self.normalizedDirectoryPrefix($0.name) }
        )
        for component in components {
            let next = candidate + component + "/"
            if directories.contains(next) {
                candidate = next
            } else {
                break
            }
        }
        return candidate
    }

    // MARK: - 私有：合成目录 + 直接子项

    /// `itemsWithSyntheticDirectories()` 的带缓存入口(见 `syntheticItemsCache`)。同一归档内导航复用,不重建。
    private func syntheticItems() -> [ArchiveItem] {
        if let cached = syntheticItemsCache { return cached }
        let built = itemsWithSyntheticDirectories()
        syntheticItemsCache = built
        return built
    }

    /// 把 `allItems` 合并上推断出来的中间目录占位项。
    ///
    /// 7-Zip / unzip 输出有时只给文件路径不给中间目录，例如只输出 `a/b/c.txt`
    /// 而省略 `a/`、`a/b/`。这里按文件路径推出所有祖先目录，
    /// UI 上才能逐层下钻而不是直接从根跳到叶。
    private func itemsWithSyntheticDirectories() -> [ArchiveItem] {
        var itemsByName: [String: ArchiveItem] = [:]

        for item in allItems {
            let itemName = Self.normalizedEntryName(item.name, isDirectory: item.isDirectory)
            itemsByName[itemName] = item

            let components = itemName
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .split(separator: "/")
                .map(String.init)
            let directoryComponents = item.isDirectory ? components : Array(components.dropLast())

            var prefix = ""
            for component in directoryComponents {
                prefix += component + "/"
                if itemsByName[prefix] == nil {
                    itemsByName[prefix] = Self.syntheticDirectory(named: prefix)
                }
            }
        }

        return Array(itemsByName.values)
    }

    /// 给定全集 items + 路径 path，返回 path 下一级的直接子项。
    /// 把同一目录前缀多个文件折叠成一个合成目录条目。
    private func immediateChildren(from items: [ArchiveItem], in path: String) -> [ArchiveItem] {
        var childrenByName: [String: ArchiveItem] = [:]

        for item in items {
            let itemName = Self.normalizedEntryName(item.name, isDirectory: item.isDirectory)
            guard itemName.hasPrefix(path), itemName != path else { continue }

            let remainder = String(itemName.dropFirst(path.count))
            guard !remainder.isEmpty else { continue }

            if let slashIndex = remainder.firstIndex(of: "/") {
                let directoryName = path + remainder[..<slashIndex] + "/"
                if childrenByName[directoryName] == nil {
                    childrenByName[directoryName] = Self.syntheticDirectory(named: String(directoryName))
                }
            } else {
                childrenByName[itemName] = item
            }
        }

        // 目录优先 + 名称自然排序，与 Finder 习惯一致。
        return childrenByName.values.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    // MARK: - 纯静态辅助

    /// 归一化目录前缀。注意：这里和 `ArchiveService.normalizedDirectoryPrefix` 行为略有差异
    /// （这里强制按 isDirectory=true 处理输入，ArchiveService 那个直接看输入末尾的 /）。
    /// 为了避免误改 ArchiveService 的解析契约，二者保留各自实现。
    static func normalizedDirectoryPrefix(_ name: String) -> String {
        let normalized = normalizedEntryName(name, isDirectory: true)
        return normalized.hasSuffix("/") ? normalized : normalized + "/"
    }

    static func normalizedEntryName(_ name: String, isDirectory: Bool) -> String {
        let trimmedName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedName.isEmpty { return "" }
        return isDirectory ? trimmedName + "/" : trimmedName
    }

    static func syntheticDirectory(named name: String) -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: true, size: nil, modified: nil, sizeText: "", modifiedText: "", method: "")
    }
}

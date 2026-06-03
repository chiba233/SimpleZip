//
//  UniqueFileName.swift
//  SimpleZip
//
//  0.3.0 #86 阶段1：把「算一个不冲突的文件名」这类**纯 URL 计算**从 ArchiveBrowserModel 的文件操作里
//  抽到 Core（SwiftPM 可测）。原先「创建副本」和「创建符号链接」各写了一份结构完全一致的递增命名逻辑
//  （base+suffix → base+suffix 2 → …），只差后缀词和「是否已存在」的判定语义（`fileExists` 跟随符号链接，
//  符号链接场景要用 `lstat` 才能识别已有的失效链接）；这里合并成一个函数，存在性判定由调用方以闭包传入，
//  本地化后缀词也由调用方（app 层 L10n）传入 —— Core 这层不依赖 locale、纯逻辑、好测。
//

import Foundation

/// 文件名去重计算 —— 纯函数，不碰 model 状态、不直接判存在（存在性策略由调用方注入）。
public enum UniqueFileName {
    /// `base + suffix` 作为首选名，重名则递增 `base + "suffix 2"`、`base + "suffix 3"`…（编号从 2 起）。
    /// 保留 `url` 的目录与扩展名（扩展名非空时产物形如 `<stem>.<ext>`）。
    /// - Parameters:
    ///   - url: 原始项 URL（取其目录 / 扩展名 / 去扩展名后的基名）。
    ///   - suffix: 追加在基名后的后缀词（如本地化的「 副本」「 符号链接」，含调用方想要的前导空格）。
    ///   - exists: 判定某 URL 是否已被占用 —— 普通文件用 `fileExists`；符号链接用 `lstat`（`attributesOfItem`）
    ///     语义以识别失效链接。
    public static func suffixed(
        for url: URL,
        suffix: String,
        exists: (URL) -> Bool
    ) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        func candidate(_ tail: String) -> URL {
            let stem = base + tail
            let name = ext.isEmpty ? stem : "\(stem).\(ext)"
            return dir.appendingPathComponent(name)
        }
        var target = candidate(suffix)
        var n = 2
        while exists(target) {
            target = candidate("\(suffix) \(n)")
            n += 1
        }
        return target
    }

    /// `preferredName` 作为首选名，重名则在基名后补空格 + 编号：`Name 2`、`Name 3`…（编号从 2 起，无后缀词）。
    /// 保留 `preferredName` 的扩展名。用于「新建文件夹 / 新建文件」的去重命名。
    /// - Parameter exists: 判定某 URL 是否已被占用。
    public static func numbered(
        in folderURL: URL,
        preferredName: String,
        exists: (URL) -> Bool
    ) -> URL {
        let preferredURL = folderURL.appendingPathComponent(preferredName)
        guard exists(preferredURL) else { return preferredURL }

        let ext = preferredURL.pathExtension
        let base = ext.isEmpty ? preferredName : (preferredName as NSString).deletingPathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = folderURL.appendingPathComponent(name)
            if !exists(candidate) {
                return candidate
            }
            index += 1
        }
    }
}

//
//  ArchiveAssociationService.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

/// 设置页里展示的一种可关联压缩包格式。
struct ArchiveAssociation: Identifiable, Hashable {
    let fileExtension: String
    let title: String
    let contentTypes: [String]

    var id: String { fileExtension }

    /// 类别(0.4.3 用户拍板:文件关联按类分组、同类同色)。
    enum Category {
        case archive    // 常规压缩包 / 镜像
        case simpleZip  // SimpleZip 专属格式
        case volume     // 分卷

        var tint: Color {
            switch self {
            case .archive: return .blue
            case .simpleZip: return .green
            case .volume: return .orange
            }
        }
    }

    var category: Category {
        switch fileExtension {
        case "siz", "szs": return .simpleZip
        case "001", "z01", "r00": return .volume
        default: return .archive
        }
    }
}

/// 默认打开方式服务：通过 Launch Services 将压缩包格式关联到当前 App。
enum ArchiveAssociationService {
    static let supportedAssociations: [ArchiveAssociation] = [
        ArchiveAssociation(fileExtension: "zip", title: "ZIP Archive", contentTypes: contentTypes(for: "zip", fallback: ["com.pkware.zip-archive"])),
        ArchiveAssociation(fileExtension: "7z", title: "7-Zip Archive", contentTypes: contentTypes(for: "7z", fallback: ["org.7-zip.7-zip-archive"])),
        ArchiveAssociation(fileExtension: "tar", title: "TAR Archive", contentTypes: contentTypes(for: "tar", fallback: ["public.tar-archive"])),
        ArchiveAssociation(fileExtension: "gz", title: "GZip Archive", contentTypes: contentTypes(for: "gz", fallback: ["org.gnu.gnu-zip-archive"])),
        ArchiveAssociation(fileExtension: "tgz", title: "Compressed TAR Archive", contentTypes: contentTypes(for: "tgz", fallback: ["public.tar-archive", "org.gnu.gnu-zip-archive"])),
        ArchiveAssociation(fileExtension: "bz2", title: "BZip2 Archive", contentTypes: contentTypes(for: "bz2", fallback: ["public.bzip2-archive"])),
        ArchiveAssociation(fileExtension: "xz", title: "XZ Archive", contentTypes: contentTypes(for: "xz", fallback: ["org.tukaani.xz-archive"])),
        ArchiveAssociation(fileExtension: "rar", title: "RAR Archive", contentTypes: contentTypes(for: "rar", fallback: ["com.rarlab.rar-archive"])),
        ArchiveAssociation(fileExtension: "dmg", title: "DMG Disk Image", contentTypes: contentTypes(for: "dmg", fallback: ["com.apple.disk-image-udif"])),
        // XIP（Apple 签名归档,0.3.3 起支持浏览 / 解压 / 测试）。
        ArchiveAssociation(fileExtension: "xip", title: "XIP Archive", contentTypes: contentTypes(for: "xip", fallback: ["com.apple.xip-archive"])),
        // SimpleZip 自有的「带签名 tar 容器」格式 —— UTI 在 Info.plist 的 UTExportedTypeDeclarations 里声明。
        ArchiveAssociation(fileExtension: "siz", title: "SimpleZip Signed Container", contentTypes: contentTypes(for: "siz", fallback: ["com.simplezip.siz-archive"])),
        // SimpleZip 自有的签名清单格式（v0.1.9 起）。
        ArchiveAssociation(fileExtension: "szs", title: "SimpleZip Signed Manifest", contentTypes: contentTypes(for: "szs", fallback: ["com.simplezip.szs-manifest"])),
        ArchiveAssociation(
            fileExtension: "001",
            title: "Split Archive Volumes",
            contentTypes: contentTypes(
                for: ["001", "002", "003", "004", "005"],
                fallback: []
            )
        ),
        ArchiveAssociation(
            fileExtension: "z01",
            title: "Split ZIP Volumes",
            contentTypes: contentTypes(
                for: ["z01", "z02", "z03", "z04", "z05"],
                fallback: []
            )
        ),
        ArchiveAssociation(
            fileExtension: "r00",
            title: "RAR Part Volumes",
            contentTypes: contentTypes(
                for: ["r00", "r01", "r02", "r03", "r04"],
                fallback: []
            )
        )
    ]

    static func setAsDefaultForSupportedArchives() throws {
        for association in supportedAssociations {
            try setAsDefault(for: association)
        }

        NSWorkspace.shared.noteFileSystemChanged(Bundle.main.bundlePath)
    }

    static func setAsDefault(for association: ArchiveAssociation) throws {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw ArchiveError.commandFailed(L10n.text("error.missingBundleIdentifier"))
        }

        for type in association.contentTypes {
            let status = LSSetDefaultRoleHandlerForContentType(type as CFString, LSRolesMask.all, bundleIdentifier as CFString)
            guard status == noErr else {
                throw ArchiveError.commandFailed(L10n.format("error.defaultAppFailed", ".\(association.fileExtension)", Int(status)))
            }
        }

        NSWorkspace.shared.noteFileSystemChanged(Bundle.main.bundlePath)
    }

    static func isSimpleZipDefault(for association: ArchiveAssociation) -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        return association.contentTypes.allSatisfy { contentType in
            defaultBundleIdentifier(for: contentType) == bundleIdentifier
        }
    }

    static func currentDefaultAppName(for association: ArchiveAssociation) -> String {
        guard let primaryContentType = association.contentTypes.first,
              let bundleIdentifier = defaultBundleIdentifier(for: primaryContentType) else {
            return L10n.text("settings.association.noDefault")
        }

        if bundleIdentifier == Bundle.main.bundleIdentifier {
            return "SimpleZip"
        }

        return appName(for: bundleIdentifier) ?? bundleIdentifier
    }

    private static func contentTypes(for fileExtension: String, fallback: [String]) -> [String] {
        contentTypes(for: [fileExtension], fallback: fallback)
    }

    private static func contentTypes(for fileExtensions: [String], fallback: [String]) -> [String] {
        var identifiers = Set(fallback)

        for fileExtension in fileExtensions {
            if let type = UTType(filenameExtension: fileExtension) {
                let shouldUseDynamicType = fallback.isEmpty
                if shouldUseDynamicType || !type.identifier.hasPrefix("dyn.") {
                    identifiers.insert(type.identifier)
                }
            }
        }

        return identifiers.sorted()
    }

    private static func defaultBundleIdentifier(for contentType: String) -> String? {
        guard let handler = LSCopyDefaultRoleHandlerForContentType(contentType as CFString, LSRolesMask.all) else {
            return nil
        }
        return handler.takeRetainedValue() as String
    }

    private static func appName(for bundleIdentifier: String) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }

        if let bundle = Bundle(url: appURL) {
            if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !displayName.isEmpty {
                return displayName
            }
            if let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !bundleName.isEmpty {
                return bundleName
            }
        }

        return appURL.deletingPathExtension().lastPathComponent
    }
}

//
//  ArchiveAssociationService.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import CoreServices
import UniformTypeIdentifiers

/// 默认打开方式服务：通过 Launch Services 将压缩包格式关联到当前 App。
enum ArchiveAssociationService {
    static func setAsDefaultForSupportedArchives() throws {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw ArchiveError.commandFailed(L10n.text("error.missingBundleIdentifier"))
        }

        for type in supportedContentTypes {
            let status = LSSetDefaultRoleHandlerForContentType(type as CFString, LSRolesMask.all, bundleIdentifier as CFString)
            guard status == noErr else {
                throw ArchiveError.commandFailed(L10n.format("error.defaultAppFailed", type, Int(status)))
            }
        }

        NSWorkspace.shared.noteFileSystemChanged(Bundle.main.bundlePath)
    }

    private static var supportedContentTypes: [String] {
        var identifiers = Set<String>()

        for ext in ArchiveService.supportedExtensions {
            if let type = UTType(filenameExtension: ext) {
                identifiers.insert(type.identifier)
            }
        }

        identifiers.formUnion([
            "com.pkware.zip-archive",
            "org.7-zip.7-zip-archive",
            "public.tar-archive",
            "org.gnu.gnu-zip-archive",
            "public.archive"
        ])

        return identifiers.sorted()
    }
}

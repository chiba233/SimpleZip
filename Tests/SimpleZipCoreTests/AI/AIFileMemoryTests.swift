//
//  AIFileMemoryTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:文件 / 文件夹预索引模型 —— 类型分类 + 角色 + 推荐视角(工程补充七)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIFileMemoryTests {
    private let loc = AILocationContext(kind: .projectFolder, pathHash: "loc-1",
                                        folderNameTokens: ["simplezip", "release"])

    @Test func classifiesCommonFileTypes() {
        #expect(AIFileType.classify(fileName: "main.swift", isDirectory: false) == .sourceCode)
        #expect(AIFileType.classify(fileName: "README.md", isDirectory: false) == .markdown)
        #expect(AIFileType.classify(fileName: "config.yaml", isDirectory: false) == .config)
        #expect(AIFileType.classify(fileName: "SHA256SUMS", isDirectory: false) == .checksum)
        #expect(AIFileType.classify(fileName: "signature.asc", isDirectory: false) == .signature)
        #expect(AIFileType.classify(fileName: "release.7z", isDirectory: false) == .archive)
        #expect(AIFileType.classify(fileName: "SimpleZip.dmg", isDirectory: false) == .diskImage)
        #expect(AIFileType.classify(fileName: "SimpleZip.app", isDirectory: true) == .appBundle)
        #expect(AIFileType.classify(fileName: "Sources", isDirectory: true) == .folder)
        #expect(AIFileType.classify(fileName: "mystery.qux", isDirectory: false) == .unknown)
    }

    @Test func everyFileTypeHasStableToken() {
        for t in AIFileType.allCases { #expect(!t.rawValue.isEmpty) }
    }

    /// 长尾常见扩展名必须落到具体类型(source/config/media/binary/archive),不再掉进 `.unknown` 泛化桶 ——
    /// 这是「让 document/泛化信号进一步降低」的根:覆盖面越广,落进通用桶的文件越少,聚类结构越清晰。
    @Test func classifyCoversCommonModernExtensions() {
        // 现代 / web 源码 → source(不再 unknown,也绝不进 document)
        for name in ["App.vue", "Widget.svelte", "page.astro", "main.dart", "util.lua",
                     "schema.sql", "api.proto", "query.graphql", "index.html", "theme.scss",
                     "build.gradle", "Analysis.ipynb", "contract.sol", "deploy.sh"] {
            #expect(AIFileType.classify(fileName: name, isDirectory: false) == .sourceCode,
                    "\(name) 应识别为 source")
        }
        // TypeScript 仍归 source(不被 MPEG-TS 抢成 video)
        #expect(AIFileType.classify(fileName: "store.ts", isDirectory: false) == .sourceCode)
        // 锁文件 / 包清单 / dotfile / 基础设施配置 → config
        for name in ["Cargo.lock", "go.sum", "go.mod", ".editorconfig", "main.tf", "flake.nix",
                     "Info.entitlements", "build.xcconfig"] {
            #expect(AIFileType.classify(fileName: name, isDirectory: false) == .config,
                    "\(name) 应识别为 config")
        }
        // 媒体长尾 → image / video / audio
        #expect(AIFileType.classify(fileName: "logo.svg", isDirectory: false) == .image)
        #expect(AIFileType.classify(fileName: "icon.icns", isDirectory: false) == .image)
        #expect(AIFileType.classify(fileName: "clip.mpeg", isDirectory: false) == .video)
        #expect(AIFileType.classify(fileName: "song.opus", isDirectory: false) == .audio)
        // 二进制制品 / 安装包 → binary(正确类型,不当文本读)
        for name in ["Main.class", "module.pyc", "tool.deb", "setup.msi", "lib.swiftmodule"] {
            #expect(AIFileType.classify(fileName: name, isDirectory: false) == .binary,
                    "\(name) 应识别为 binary")
        }
        // 长尾归档 → archive
        #expect(AIFileType.classify(fileName: "data.lz4", isDirectory: false) == .archive)
        #expect(AIFileType.classify(fileName: "old.cpio", isDirectory: false) == .archive)
        // 目录型 bundle → package(不当普通文件夹)
        #expect(AIFileType.classify(fileName: "SimpleZip.xcodeproj", isDirectory: true) == .package)
        #expect(AIFileType.classify(fileName: "Photos.photoslibrary", isDirectory: true) == .package)
        // 这些常见扩展不该再产生空角色(掉进泛化桶)
        for name in ["App.vue", "logo.svg", "Cargo.lock", "clip.mpeg"] {
            #expect(!AIFileType.roleTags(fileName: name, isDirectory: false).isEmpty,
                    "\(name) 角色不应为空")
        }
    }

    @Test func recordRedactsSecretFileName() {
        let rec = AIFileMemoryRecord.make(fileName: "password=hunter2.txt", isDirectory: false,
                                          byteSize: 10, modifiedAt: nil, location: loc)
        #expect(!rec.fileName.contains("hunter2"))
        #expect(rec.type == .text)
    }

    @Test func recordCarriesRoleAndMarkerTags() {
        let rec = AIFileMemoryRecord.make(fileName: "Package.swift", isDirectory: false,
                                          byteSize: 100, modifiedAt: nil, location: loc)
        #expect(rec.roleTags == ["source"])
        #expect(rec.markerTags == ["package.swift"])
    }

    @Test func recordSplitsBroadDocumentRoleByFilenameSemantics() {
        let readme = AIFileMemoryRecord.make(fileName: "README.md", isDirectory: false,
                                             byteSize: 1, modifiedAt: nil, location: loc)
        let changelog = AIFileMemoryRecord.make(fileName: "CHANGELOG.md", isDirectory: false,
                                                byteSize: 1, modifiedAt: nil, location: loc)
        let checksums = AIFileMemoryRecord.make(fileName: "SHA256SUMS", isDirectory: false,
                                                byteSize: 1, modifiedAt: nil, location: loc)
        let readerSpec = AIFileMemoryRecord.make(fileName: "HID_Global_veriCLASS_Reader.txt",
                                                 isDirectory: false, byteSize: 1,
                                                 modifiedAt: nil, location: loc)

        #expect(readme.roleTags == ["project-doc"])
        #expect(changelog.roleTags == ["release-notes"])
        #expect(checksums.roleTags.contains("integrity-data"))
        #expect(readerSpec.roleTags == ["reference-data"])
    }

    @Test func roleSamplingCapsHighVolumeRolesPerDirectory() {
        var counts: [String: Int] = [:]
        let projectDocs = (0..<7).map { _ in
            AIFileRoleSamplingPolicy.reserve(["project-doc"], counts: &counts)
        }

        #expect(projectDocs.prefix(5).allSatisfy { $0 })
        #expect(projectDocs.suffix(2).allSatisfy { !$0 })
        #expect(AIFileRoleSamplingPolicy.reserve(["unknown-role"], counts: &counts))
    }

    @Test func folderProfileDetectsReleaseRole() {
        let files = [
            AIFileMemoryRecord.make(fileName: "SimpleZip.dmg", isDirectory: false, byteSize: 1, modifiedAt: nil, location: loc),
            AIFileMemoryRecord.make(fileName: "SHA256SUMS", isDirectory: false, byteSize: 1, modifiedAt: nil, location: loc),
            AIFileMemoryRecord.make(fileName: "signature.asc", isDirectory: false, byteSize: 1, modifiedAt: nil, location: loc)
        ]
        let profile = AIFolderProfile.derive(displayName: "release", location: loc, files: files)
        #expect(profile.roleTags.contains("release"))
        #expect(profile.roleTags.contains("signed"))
        #expect(profile.suggestedLenses.contains(AILens.release.rawValue))
        #expect(profile.suggestedLenses.contains(AILens.signing.rawValue))
        #expect(profile.markerFiles.contains("SHA256SUMS"))
    }

    @Test func folderProfileDetectsSourceRole() {
        let srcLoc = AILocationContext(kind: .projectFolder, pathHash: "loc-2", folderNameTokens: ["app"])
        let files = [
            AIFileMemoryRecord.make(fileName: "Package.swift", isDirectory: false, byteSize: 1, modifiedAt: nil, location: srcLoc),
            AIFileMemoryRecord.make(fileName: "main.swift", isDirectory: false, byteSize: 1, modifiedAt: nil, location: srcLoc)
        ]
        let profile = AIFolderProfile.derive(displayName: "app", location: srcLoc, files: files)
        #expect(profile.roleTags.contains("source"))
        #expect(profile.suggestedLenses.contains(AILens.source.rawValue))
    }

    @Test func folderProfileDetectsTestFromFolderTokens() {
        let testLoc = AILocationContext(kind: .desktop, pathHash: "loc-3", folderNameTokens: ["siz", "test"])
        let profile = AIFolderProfile.derive(displayName: "siz test", location: testLoc, files: [])
        #expect(profile.roleTags.contains("test"))
    }

    @Test func derivationIsDeterministic() {
        let files = [
            AIFileMemoryRecord.make(fileName: "a.swift", isDirectory: false, byteSize: 1, modifiedAt: nil, location: loc),
            AIFileMemoryRecord.make(fileName: "README.md", isDirectory: false, byteSize: 1, modifiedAt: nil, location: loc)
        ]
        #expect(AIFolderProfile.derive(displayName: "x", location: loc, files: files)
                == AIFolderProfile.derive(displayName: "x", location: loc, files: files))
    }

    @Test func recordRoundTripsThroughCodable() throws {
        let rec = AIFileMemoryRecord.make(fileName: "README.md", isDirectory: false,
                                          byteSize: 5, modifiedAt: Date(timeIntervalSince1970: 0), location: loc)
        let data = try JSONEncoder().encode(rec)
        #expect(try JSONDecoder().decode(AIFileMemoryRecord.self, from: data) == rec)
    }
}

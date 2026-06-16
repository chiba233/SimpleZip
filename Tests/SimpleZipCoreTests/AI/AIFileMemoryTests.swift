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

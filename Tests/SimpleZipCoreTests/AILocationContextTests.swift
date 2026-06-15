//
//  AILocationContextTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:位置类别 + 稳定路径哈希 + 目录名 token。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AILocationContextTests {
    private let home = "/Users/tester"

    @Test func classifiesStandardUserFolders() {
        #expect(AILocationClassifier.kind(forPath: "\(home)/Downloads/a", home: home) == .downloads)
        #expect(AILocationClassifier.kind(forPath: "\(home)/Desktop/b", home: home) == .desktop)
        #expect(AILocationClassifier.kind(forPath: "\(home)/Documents/c", home: home) == .documents)
    }

    @Test func classifiesExternalAndTemporary() {
        #expect(AILocationClassifier.kind(forPath: "/Volumes/USB/backup", home: home) == .externalDrive)
        #expect(AILocationClassifier.kind(forPath: "/private/var/folders/xy/T/SimpleZip-abc", home: home) == .temporaryWorkspace)
        #expect(AILocationClassifier.kind(forPath: "/tmp/scratch", home: home) == .temporaryWorkspace)
    }

    @Test func unknownFoldersAreOther() {
        #expect(AILocationClassifier.kind(forPath: "\(home)/Projects/app", home: home) == .other)
        #expect(AILocationClassifier.kind(forPath: "/opt/data", home: home) == .other)
    }

    @Test func refineUpgradesOtherToProjectFolderWithMarkers() {
        #expect(AILocationClassifier.refineKind(.other, folderEntryNames: ["Package.swift", "Sources"]) == .projectFolder)
        #expect(AILocationClassifier.refineKind(.other, folderEntryNames: ["README.md"]) == .projectFolder)
        #expect(AILocationClassifier.refineKind(.other, folderEntryNames: ["photo.jpg"]) == .other)
        // 非 .other 不被改写。
        #expect(AILocationClassifier.refineKind(.downloads, folderEntryNames: ["Package.swift"]) == .downloads)
    }

    @Test func pathHashIsStableAndPrefixed() {
        let a = AILocationClassifier.pathHash("\(home)/Desktop/test")
        let b = AILocationClassifier.pathHash("\(home)/Desktop/test")
        #expect(a == b)
        #expect(a.hasPrefix("loc-"))
        #expect(a != AILocationClassifier.pathHash("\(home)/Desktop/other"))
    }

    @Test func folderTokensTokenizeNameDroppingShortBits() {
        #expect(AILocationClassifier.folderNameTokens("\(home)/Desktop/siz 及 szs test") == ["siz", "szs", "test"])
        #expect(AILocationClassifier.folderNameTokens("/x/release-2026").contains("release"))
    }

    @Test func folderTokensKeepCJKRuns() {
        let tokens = AILocationClassifier.folderNameTokens("/x/测试文件")
        #expect(tokens.contains("测试文件"))
    }

    @Test func classifyProducesFullContext() {
        let ctx = AILocationClassifier.classify(directoryPath: "\(home)/Downloads/siz test", home: home)
        #expect(ctx.kind == .downloads)
        #expect(ctx.pathHash.hasPrefix("loc-"))
        #expect(ctx.folderNameTokens.contains("siz"))
    }
}

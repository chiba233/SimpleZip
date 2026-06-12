//
//  ReleaseNotesDraftTests.swift
//  SimpleZipCoreTests
//
//  0.4.4 #5:发布说明草稿 —— 段落取舍 / GPG 段三件齐 / 命令样板。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ReleaseNotesDraftTests {
    @Test func fullDraftCarriesAllSections() {
        let notes = ReleaseNotesDraft.make(.init(
            artifactName: "MyApp.zip",
            versionLabel: "1.2.0",
            sha256: "abc123",
            fileCount: 42,
            totalBytes: 1_048_576,
            testPassed: true,
            reproducible: true,
            wroteChecksums: true,
            signedContainerName: "MyApp.szs",
            publicKeyFileName: "PUBLIC_KEY.asc",
            fingerprint: "AABBCCDDEEFF00112233AABBCCDDEEFF00112233"
        ))
        #expect(notes.contains("# 1.2.0"))
        #expect(notes.contains("| `MyApp.zip` | `abc123` |"))
        #expect(notes.contains("shasum -a 256 MyApp.zip"))
        #expect(notes.contains("shasum -a 256 -c SHA256SUMS"))
        #expect(notes.contains("Release inspection passed (42 files,"))
        #expect(notes.contains("Reproducible build"))
        // GPG 段复用 SZSArchive.verifyInstructions(同源不二抄)。
        #expect(notes.contains("gpg --import PUBLIC_KEY.asc"))
        #expect(notes.contains("gpg --verify MyApp.szs"))
        #expect(notes.contains("AABB CCDD EEFF 0011 2233 AABB CCDD EEFF 0011 2233"))
    }

    @Test func gpgSectionRequiresAllThreeMaterials() {
        let notes = ReleaseNotesDraft.make(.init(
            artifactName: "a.zip",
            sha256: "x",
            signedContainerName: "a.szs",
            publicKeyFileName: nil,
            fingerprint: "FFEE"
        ))
        #expect(!notes.contains("gpg --import"))
        #expect(!notes.contains("gpg --verify"))
    }

    @Test func minimalDraftOmitsOptionalSections() {
        let notes = ReleaseNotesDraft.make(.init(artifactName: "tool.7z"))
        #expect(notes.contains("- `tool.7z`"))
        #expect(!notes.contains("SHA256SUMS"))
        #expect(!notes.contains("Release inspection"))
        #expect(!notes.contains("Reproducible"))
        #expect(!notes.hasPrefix("# "))   // 无版本 → 开头没有版本大标题(直接从 ## Downloads 起)
    }

    @Test func spacedNamesAreQuoted() {
        let notes = ReleaseNotesDraft.make(.init(artifactName: "My App.zip"))
        #expect(notes.contains("shasum -a 256 \"My App.zip\""))
    }

    @Test func failedInspectionDoesNotClaimPassed() {
        let notes = ReleaseNotesDraft.make(.init(artifactName: "a.zip", testPassed: false))
        #expect(!notes.contains("Release inspection passed"))
    }
}

//
//  AIPrivacyRedlineTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:**隐私红线整合断言**(路线图工程补充六「隐私指标:必须 100%」+ 补充八「安全测试样例」)。
//  这一套跨各派生层统一断言:口令 / token / 私钥 / 加密条目名 / 完整敏感路径**绝不**进入任何 AI 面向数据。
//  per-type 测试各自也覆盖,这里是集中的安全网 —— 任何一条挂了都视作红线事故。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIPrivacyRedlineTests {
    private func item(_ name: String, dir: Bool = false, enc: Bool = false) -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: dir, size: 0, modified: nil,
                    sizeText: "", modifiedText: "", method: "", isEncrypted: enc)
    }

    private func cached(_ name: String, dir: Bool = false, size: Int64? = nil)
        -> ArchiveListingCacheEntry.CachedEntry {
        ArchiveListingCacheEntry.CachedEntry(name: name, isDirectory: dir, size: size)
    }

    // 补充八:文件名里塞口令 —— 进 AI 前必须 redaction。
    @Test func passwordInFileNameIsRedacted() {
        #expect(!AISensitiveRedactor.redactFileNameSecrets("password=123456.txt").contains("123456"))
        // 正常名字不受影响。
        #expect(AISensitiveRedactor.redactFileNameSecrets("my-password-notes.txt") == "my-password-notes.txt")
        #expect(AISensitiveRedactor.redactFileNameSecrets("passwords.txt") == "passwords.txt")
    }

    // 补充八:后端参数 -pSECRET / 日志 passphrase / token —— 输出不得含明文。
    @Test func backendSecretsNeverSurvive() {
        #expect(!AISensitiveRedactor.redact("7zz x -pSECRET a.7z").contains("SECRET"))
        #expect(!AISensitiveRedactor.errorLines(from: "ERROR: bad passphrase: hunter2").contains { $0.contains("hunter2") })
        #expect(!AISensitiveRedactor.redact("token=abc.def.ghi").contains("abc.def.ghi"))
    }

    // 补充八:加密归档条目 secret/project.txt —— 不得出现在画像任何字段。
    @Test func encryptedEntryNeverInProfile() {
        let profile = ArchiveProfile.derive(from: [item("readme.md"), item("secret/project.txt", enc: true)])
        let flat = (profile.markerFiles + profile.semanticTags + profile.structure.topLevelNames
                    + profile.dominantExtensions.map(\.ext)).joined(separator: " ")
        #expect(!flat.contains("project.txt"))
        #expect(!flat.contains("secret"))
        #expect(profile.structure.encryptedEntryCount == 1)
    }

    // 补充八:头加密归档(无可见条目,只有计数)—— 不生成 entry samples,只记 encrypted omission。
    @Test func headerEncryptedArchiveYieldsCountOnly() {
        let entry = ArchiveListingCacheEntry(
            archivePath: "/x/locked.7z", archiveName: "locked.7z",
            recordedAt: Date(timeIntervalSince1970: 0), archiveByteSize: 0, archiveModified: nil,
            totalEntryCount: 40, encryptedEntryCount: 40, truncated: false, entries: [])
        let record = ArchiveMemoryIndex.derive(from: entry)
        #expect(record.samplePaths.isEmpty)
        #expect(record.largestFiles.isEmpty)
        #expect(record.entryStats.encryptedEntriesOmitted == 40)
        #expect(record.omissions.contains { $0.type == "encrypted_entry_names" && $0.count == 40 })
    }

    // 补充八:归档记忆记录里塞口令的条目名 —— samplePaths 必须脱敏。
    @Test func memoryRecordRedactsSecretEntryNames() {
        let entry = ArchiveListingCacheEntry(
            archivePath: "/x/dump.zip", archiveName: "dump.zip",
            recordedAt: Date(timeIntervalSince1970: 0), archiveByteSize: 0, archiveModified: nil,
            totalEntryCount: 1, encryptedEntryCount: 0, truncated: false,
            entries: [cached("creds/password=hunter2.txt")])
        let record = ArchiveMemoryIndex.derive(from: entry)
        #expect(!record.samplePaths.joined().contains("hunter2"))
    }

    // 长期学习不暴露完整磁盘路径:任务记录 / 归档记忆的 JSON 都不含敏感绝对路径。
    @Test func fullSensitivePathNeverInRecords() {
        let task = AITaskRecord.make(
            id: "t1", category: "archive", kind: "extract", source: "finder", status: "failed",
            title: "x", startedAt: nil, finishedAt: nil,
            archivePath: "/Users/secret/private/vault.zip", home: "/Users/secret")
        let taskJSON = try! task.jsonLine()
        #expect(!taskJSON.contains("/Users/secret/private"))
        #expect(!taskJSON.contains("secret/private"))

        let entry = ArchiveListingCacheEntry(
            archivePath: "/Users/secret/private/vault.zip", archiveName: "vault.zip",
            recordedAt: Date(timeIntervalSince1970: 0), archiveByteSize: 0, archiveModified: nil,
            totalEntryCount: 1, encryptedEntryCount: 0, truncated: false, entries: [cached("note.txt")])
        let recJSON = String(decoding: try! JSONEncoder().encode(ArchiveMemoryIndex.derive(from: entry, home: "/Users/secret")), as: UTF8.self)
        #expect(!recJSON.contains("/Users/secret/private"))
    }

    // 任务记录:失败消息里的口令必须脱敏。
    @Test func taskRecordRedactsFailureSecrets() {
        let task = AITaskRecord.make(
            id: "t2", category: "archive", kind: "create", source: "app", status: "failed",
            title: "x", startedAt: nil, finishedAt: nil,
            failureMessage: "gpg failed passphrase=hunter2", rawOutput: "passphrase=hunter2")
        #expect(task.diagnostics.failureMessage?.contains("hunter2") == false)
        #expect(task.diagnostics.errorLines.allSatisfy { !$0.contains("hunter2") })
    }

    // blockedSensitive 级别永不可组装(契约层防线)。
    @Test func blockedSensitiveIsNeverAssemblable() {
        #expect(AIPrivacyLevel.blockedSensitive.isAssemblable == false)
    }
}

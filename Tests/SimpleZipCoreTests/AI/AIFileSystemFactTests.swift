//
//  AIFileSystemFactTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:统一文件系统事实 + 可读性门控(白皮书「红线和数据权限」)。
//  重点验证:确定性组装、权限/敏感目录/临时解密/疑似密钥/用户排除五种内容门控、脱敏、目录形态。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIFileSystemFactTests {
    private let desktop = AILocationContext(kind: .desktop, pathHash: "loc-desk",
                                            folderNameTokens: ["desktop"])

    private func readableSwift(path: String = "/Users/yumeka/Desktop/main.swift") -> AIFileSystemFact {
        AIFileSystemFact.make(
            absolutePath: path, location: desktop, byteSize: 1234,
            posixMode: "rw-r--r--", currentUserCanRead: true, currentUserCanWrite: true,
            currentUserCanExecute: false, isDirectory: false)
    }

    // MARK: - 组装

    @Test func assemblesReadableSourceFile() {
        let fact = readableSwift()
        #expect(fact.sourceRef.kind == .file)
        #expect(fact.displayName == "main.swift")
        #expect(fact.fileExtension == "swift")
        #expect(fact.roleTags == ["source"])
        #expect(fact.contentReadableByAI)
        #expect(fact.contentEnrichmentAllowed)       // 源码可做内容增强
        #expect(fact.omissions.isEmpty)
        #expect(fact.pathHash.hasPrefix("fp-"))
        #expect(fact.parentPathHash.hasPrefix("fp-"))
        #expect(fact.pathHash != fact.parentPathHash)
    }

    @Test func directoryUsesFolderRefAndNoEnrichment() {
        let fact = AIFileSystemFact.make(
            absolutePath: "/Users/yumeka/Desktop/Sources", location: desktop,
            posixMode: "rwxr-xr-x", currentUserCanRead: true, currentUserCanWrite: true,
            currentUserCanExecute: true, isDirectory: true)
        #expect(fact.sourceRef.kind == .folder)
        #expect(fact.fileExtension == "")
        #expect(fact.isDirectory)
        #expect(!fact.contentEnrichmentAllowed)       // 目录不做内容增强
    }

    @Test func passesThroughOpenAppAndPermissionFacts() {
        let fact = AIFileSystemFact.make(
            absolutePath: "/Users/yumeka/Desktop/main.swift", location: desktop,
            ownerName: "yumeka", groupName: "staff", posixMode: "rw-r--r--",
            currentUserCanRead: true, currentUserCanWrite: true, currentUserCanExecute: false,
            isDirectory: false, defaultOpenAppBundleID: "com.microsoft.VSCode",
            defaultOpenAppName: "Visual Studio Code",
            availableOpenAppBundleIDs: ["com.microsoft.VSCode", "com.apple.dt.Xcode"],
            preferredWorkspaceOpenAppBundleID: "com.microsoft.VSCode")
        #expect(fact.ownerName == "yumeka")
        #expect(fact.groupName == "staff")
        #expect(fact.defaultOpenAppName == "Visual Studio Code")
        #expect(fact.availableOpenAppBundleIDs.count == 2)
        #expect(fact.preferredWorkspaceOpenAppBundleID == "com.microsoft.VSCode")
    }

    // MARK: - 确定性

    @Test func deterministicSameInputsEqual() {
        #expect(readableSwift() == readableSwift())
    }

    @Test func pathHashStableAndDistinct() {
        let a = readableSwift(path: "/Users/yumeka/Desktop/a.swift")
        let b = readableSwift(path: "/Users/yumeka/Desktop/a.swift")
        let c = readableSwift(path: "/Users/yumeka/Desktop/b.swift")
        #expect(a.pathHash == b.pathHash)
        #expect(a.pathHash != c.pathHash)
        #expect(a.parentPathHash == c.parentPathHash)   // 同目录 → 同父哈希
    }

    // MARK: - 可读性门控(五种)

    @Test func noReadPermissionBlocksContent() {
        let fact = AIFileSystemFact.make(
            absolutePath: "/Users/yumeka/Desktop/locked.txt", location: desktop,
            posixMode: "-w-------", currentUserCanRead: false, currentUserCanWrite: true,
            currentUserCanExecute: false, isDirectory: false)
        #expect(!fact.contentReadableByAI)
        #expect(!fact.contentEnrichmentAllowed)
        #expect(fact.omissions.contains { $0.type == "file_content" && $0.policy == "no_read_permission" })
        // 但低敏事实仍在:路径、权限、类型可用。
        #expect(fact.fileExtension == "txt")
    }

    @Test func sensitiveDirectoryBlocksContent() {
        let fact = AIFileSystemFact.make(
            absolutePath: "/Users/yumeka/.ssh/config", location: desktop,
            posixMode: "rw-------", currentUserCanRead: true, currentUserCanWrite: true,
            currentUserCanExecute: false, isDirectory: false)
        #expect(!fact.contentReadableByAI)
        #expect(fact.omissions.contains { $0.policy == "sensitive_directory" })
    }

    @Test func decryptTempBlocksContent() {
        let fact = AIFileSystemFact.make(
            absolutePath: "/private/var/folders/ab/SimpleZip-extract-XYZ/secret.txt", location: desktop,
            posixMode: "rw-r--r--", currentUserCanRead: true, currentUserCanWrite: true,
            currentUserCanExecute: false, isDirectory: false)
        #expect(!fact.contentReadableByAI)
        #expect(fact.omissions.contains { $0.policy == "decrypt_temp_directory" })
    }

    @Test func secretFilenameBlocksAndRedactsName() {
        let fact = AIFileSystemFact.make(
            absolutePath: "/Users/yumeka/Desktop/password=123456.txt", location: desktop,
            posixMode: "rw-r--r--", currentUserCanRead: true, currentUserCanWrite: true,
            currentUserCanExecute: false, isDirectory: false)
        #expect(!fact.contentReadableByAI)
        #expect(fact.omissions.contains { $0.policy == "sensitive_filename" })
        // 红线:疑似口令的文件名必须脱敏,绝不原样进 AI。
        #expect(!fact.displayName.contains("123456"))
        #expect(fact.displayName.contains("REDACTED"))
    }

    @Test func userExcludedBlocksContent() {
        let fact = AIFileSystemFact.make(
            absolutePath: "/Users/yumeka/Desktop/notes.md", location: desktop,
            posixMode: "rw-r--r--", currentUserCanRead: true, currentUserCanWrite: true,
            currentUserCanExecute: false, isDirectory: false, isExcludedFromAI: true)
        #expect(!fact.contentReadableByAI)
        #expect(fact.omissions.contains { $0.policy == "excluded_by_user" })
    }

    // MARK: - 策略单元

    @Test func looksLikeSecretMatchesKeyMaterial() {
        #expect(AIFileReadabilityPolicy.looksLikeSecret(fileName: "id_rsa"))
        #expect(AIFileReadabilityPolicy.looksLikeSecret(fileName: "server.key"))
        #expect(AIFileReadabilityPolicy.looksLikeSecret(fileName: "cert.pem"))
        #expect(AIFileReadabilityPolicy.looksLikeSecret(fileName: ".env"))
        #expect(AIFileReadabilityPolicy.looksLikeSecret(fileName: "vault.json"))
        #expect(AIFileReadabilityPolicy.looksLikeSecret(fileName: "backup.gpg"))
        #expect(!AIFileReadabilityPolicy.looksLikeSecret(fileName: "README.md"))
        #expect(!AIFileReadabilityPolicy.looksLikeSecret(fileName: "main.swift"))
    }

    @Test func enrichableOnlyForTextTypes() {
        #expect(AIFileReadabilityPolicy.enrichable(type: .markdown, contentReadable: true))
        #expect(AIFileReadabilityPolicy.enrichable(type: .sourceCode, contentReadable: true))
        #expect(AIFileReadabilityPolicy.enrichable(type: .checksum, contentReadable: true))
        #expect(!AIFileReadabilityPolicy.enrichable(type: .image, contentReadable: true))
        #expect(!AIFileReadabilityPolicy.enrichable(type: .archive, contentReadable: true))
        // 不可读时一律不增强。
        #expect(!AIFileReadabilityPolicy.enrichable(type: .markdown, contentReadable: false))
    }

    @Test func blockReasonOrderingPermissionFirst() {
        // 同时无权限且在敏感目录:权限优先。
        let r = AIFileReadabilityPolicy.blockReason(
            absolutePath: "/Users/yumeka/.ssh/id_rsa", fileName: "id_rsa",
            currentUserCanRead: false, isExcludedByUser: false)
        #expect(r == .noReadPermission)
    }
}

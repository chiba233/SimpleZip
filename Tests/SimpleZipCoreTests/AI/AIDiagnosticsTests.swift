//
//  AIDiagnosticsTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:失败诊断确定性分类 —— 用真实 7zz / gpg 诊断词断言标签。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIDiagnosticsTests {
    @Test func permissionDeniedFromSevenZipOutput() {
        let tags = AIDiagnosticsClassifier.classify(
            message: "ERROR: Can not create output directory : Permission denied")
        #expect(tags.contains(.permissionDenied))
    }

    @Test func crcFailureIsChecksumMismatch() {
        let tags = AIDiagnosticsClassifier.classify(message: "ERROR: CRC Failed : payload.bin")
        #expect(tags.contains(.checksumMismatch))
        #expect(!tags.contains(.corruptArchive)) // CRC 更具体,不再额外打 corrupt
    }

    @Test func dataErrorIsChecksumMismatch() {
        #expect(AIDiagnosticsClassifier.classify(message: "Data Error in encrypted file").contains(.checksumMismatch))
    }

    @Test func missingVolumeDetected() {
        #expect(AIDiagnosticsClassifier.classify(message: "Cannot find volume .002").contains(.missingVolume))
        #expect(AIDiagnosticsClassifier.classify(message: "Missing volume : archive.7z.003").contains(.missingVolume))
    }

    @Test func wrongPasswordIsNeedsPassword() {
        #expect(AIDiagnosticsClassifier.classify(message: "Wrong password?").contains(.needsPassword))
        #expect(AIDiagnosticsClassifier.classify(message: "Cannot open encrypted archive").contains(.needsPassword))
    }

    @Test func diskSpaceDetected() {
        #expect(AIDiagnosticsClassifier.classify(message: "write error: No space left on device").contains(.diskSpace))
    }

    @Test func unsupportedFormatDetected() {
        #expect(AIDiagnosticsClassifier.classify(message: "Cannot open the file as archive").contains(.unsupportedFormat))
        #expect(AIDiagnosticsClassifier.classify(message: "Unsupported method").contains(.unsupportedFormat))
    }

    @Test func corruptArchiveDetected() {
        #expect(AIDiagnosticsClassifier.classify(message: "Headers Error").contains(.corruptArchive))
        #expect(AIDiagnosticsClassifier.classify(message: "Unexpected end of archive").contains(.corruptArchive))
    }

    @Test func signatureProblemDetected() {
        #expect(AIDiagnosticsClassifier.classify(message: "BAD signature from key").contains(.signatureProblem))
        #expect(AIDiagnosticsClassifier.classify(message: "gpg: verification failed").contains(.signatureProblem))
    }

    @Test func cancelledDetected() {
        #expect(AIDiagnosticsClassifier.classify(message: "Operation was cancelled by the user").contains(.cancelledByUser))
        #expect(!AIDiagnosticsClassifier.classify(message: "using a cancellation token").contains(.cancelledByUser))
    }

    @Test func destinationConflictDetected() {
        #expect(AIDiagnosticsClassifier.classify(message: "file already exists").contains(.destinationConflict))
    }

    @Test func emptyAndCleanOutputsYieldNoTags() {
        #expect(AIDiagnosticsClassifier.classify(message: "").isEmpty)
        #expect(AIDiagnosticsClassifier.classify(message: "Everything is Ok").isEmpty)
    }

    @Test func usesErrorLinesToo() {
        let tags = AIDiagnosticsClassifier.classify(
            message: "Extraction failed.",
            errorLines: ["ERROR: Can not create output directory : Permission denied"])
        #expect(tags.contains(.permissionDenied))
    }

    @Test func uninterruptedDoesNotTagInterrupted() {
        // 审计 #13:整词匹配,"uninterrupted" 不该命中 interrupted。
        #expect(!AIDiagnosticsClassifier.classify(message: "ran uninterrupted to completion").contains(.interruptedPreviousSession))
        #expect(AIDiagnosticsClassifier.classify(message: "operation was interrupted").contains(.interruptedPreviousSession))
    }

    @Test func tagsAreDeduped() {
        let tags = AIDiagnosticsClassifier.classify(
            message: "Permission denied",
            errorLines: ["Permission denied", "Permission denied"])
        #expect(tags.filter { $0 == .permissionDenied }.count == 1)
    }

    @Test func devToolsPipelineRowsCoverAllSuggestionProductCounters() {
        let counts = AIDevToolsPipelineProductCounts(
            summary: 98, openWith: 45, urlOpen: 15, install: 3, activity: 0,
            archiveEntry: 17, archiveKind: 12, folderGroup: 89, organize: 1,
            inspect: 3, test: 0, hash: 0, security: 0, compress: 0, convert: 0,
            inlineResult: 1, workbenchChipRanking: 7,
            workbenchNeedsAttention: 2, workbenchFailureExplanation: 5,
            workbenchClusterChips: 4)
        let rows = AIDevToolsPipelineCatalog.rows(for: counts)
        #expect(rows.map(\.name) == [
            "摘要", "打开方式", "网页", "装App", "活动", "包内", "包定性", "文件组", "整理",
            "检测", "测试", "哈希", "安全", "压缩", "转换", "内联结果", "筛选排序",
            "需要处理解读", "失败解释", "真建议"
        ])
        #expect(rows.first(where: { $0.name == "打开方式" })?.cachedProductCount == 45)
        #expect(rows.first(where: { $0.name == "内联结果" })?.passName == nil)
        #expect(rows.first(where: { $0.name == "筛选排序" })?.cachedProductCount == 7)
        #expect(rows.first(where: { $0.name == "需要处理解读" })?.cachedProductCount == 2)
        #expect(rows.first(where: { $0.name == "失败解释" })?.cachedProductCount == 5)
        #expect(rows.first(where: { $0.name == "真建议" })?.cachedProductCount == 4)
    }
}

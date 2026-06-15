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

    @Test func tagsAreDeduped() {
        let tags = AIDiagnosticsClassifier.classify(
            message: "Permission denied",
            errorLines: ["Permission denied", "Permission denied"])
        #expect(tags.filter { $0 == .permissionDenied }.count == 1)
    }
}

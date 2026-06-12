//
//  ReleaseLedgerComparisonTests.swift
//  SimpleZipCoreTests
//
//  0.4.4 #3:账面对比 —— 差值 / 指纹 / junk 回潮 / 缺数据时的 nil 语义。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ReleaseLedgerComparisonTests {
    private func entry(
        bytes: Int64? = nil,
        files: Int? = nil,
        fingerprint: String? = nil,
        junk: Int? = nil
    ) -> ReleaseLedgerEntry {
        ReleaseLedgerEntry(
            date: Date(timeIntervalSince1970: 0),
            artifactPath: "/tmp/a.zip",
            versionLabel: "v",
            formatRawValue: "zip",
            sha256: nil,
            structuralFingerprint: fingerprint,
            reproducible: false,
            excludeJunk: false,
            inspectionRan: true,
            testPassed: true,
            suspiciousPathCount: 0,
            junkCount: junk,
            emptyDirectoryCount: 0,
            fileCount: files,
            totalBytes: bytes,
            wroteChecksums: false,
            signRequested: false,
            appVersion: "0.4.4",
            backendVersion: nil,
            steps: []
        )
    }

    @Test func deltasComputeWhenBothSidesPresent() {
        let comparison = ReleaseLedgerComparison.compare(
            old: entry(bytes: 1000, files: 10),
            new: entry(bytes: 1500, files: 8)
        )
        #expect(comparison.totalBytesDelta == 500)
        #expect(comparison.fileCountDelta == -2)
    }

    @Test func missingSidesYieldNilNotZero() {
        let comparison = ReleaseLedgerComparison.compare(
            old: entry(bytes: nil, files: nil, fingerprint: nil),
            new: entry(bytes: 1500, files: 8, fingerprint: "abc")
        )
        #expect(comparison.totalBytesDelta == nil)
        #expect(comparison.fileCountDelta == nil)
        #expect(comparison.fingerprintChanged == nil)
    }

    @Test func fingerprintComparison() {
        #expect(ReleaseLedgerComparison.compare(
            old: entry(fingerprint: "abc"), new: entry(fingerprint: "abc")
        ).fingerprintChanged == false)
        #expect(ReleaseLedgerComparison.compare(
            old: entry(fingerprint: "abc"), new: entry(fingerprint: "def")
        ).fingerprintChanged == true)
    }

    @Test func junkRegressionFiresOnlyOnZeroToPositive() {
        #expect(ReleaseLedgerComparison.compare(old: entry(junk: 0), new: entry(junk: 3)).junkRegression)
        #expect(!ReleaseLedgerComparison.compare(old: entry(junk: 2), new: entry(junk: 3)).junkRegression)
        #expect(!ReleaseLedgerComparison.compare(old: entry(junk: 0), new: entry(junk: 0)).junkRegression)
        // junk 没记录(检查关)按 0 处理:不报回潮。
        #expect(!ReleaseLedgerComparison.compare(old: entry(junk: nil), new: entry(junk: nil)).junkRegression)
    }
}

//
//  ArchiveSalvageTests.swift
//  SimpleZipCoreTests
//
//  0.4.4 #8:7zz 失败输出解析(纯文本进出)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ArchiveSalvageTests {
    @Test func parsesCRCAndDataErrorsAndSummary() {
        let output = """
        Extracting archive: /tmp/broken.zip

        ERROR: CRC Failed : docs/report.pdf
          0% 12 - photos/a.jpg
        ERROR: Data Error : photos/b.jpg
        ERROR: CRC Failed : docs/report.pdf

        Sub items Errors: 2

        Archives with Errors: 1
        """
        let result = ArchiveSalvage.parseFailures(fromBackendOutput: output)
        // 去重:同一条目重复报错只记一次。
        #expect(result.failedPaths == ["docs/report.pdf", "photos/b.jpg"])
        #expect(result.reportedErrorCount == 2)
    }

    @Test func pathsWithColonsSurvive() {
        let output = "ERROR: CRC Failed : weird : name/file.txt"
        let result = ArchiveSalvage.parseFailures(fromBackendOutput: output)
        // 取**第一个** " : " 之后整段 —— 路径自身的 " : " 保留。
        #expect(result.failedPaths == ["weird : name/file.txt"])
    }

    @Test func cleanOutputYieldsNothing() {
        let result = ArchiveSalvage.parseFailures(fromBackendOutput: "Everything is Ok\n")
        #expect(result.failedPaths.isEmpty)
        #expect(result.reportedErrorCount == nil)
    }
}

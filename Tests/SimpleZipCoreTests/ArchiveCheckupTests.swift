//
//  ArchiveCheckupTests.swift
//  SimpleZipCoreTests
//
//  0.4.4 #7:条目侧事实聚合(薄封装在已测现成件上)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ArchiveCheckupTests {
    @Test func entryFactsAggregateOverItems() {
        func item(_ name: String, encrypted: Bool = false) -> ArchiveItem {
            ArchiveItem(name: name, isDirectory: false, size: 1, modified: nil,
                        sizeText: "", modifiedText: "", method: "", isEncrypted: encrypted)
        }
        let facts = ArchiveCheckup.entryFacts(items: [
            item("normal.txt"),
            item("../escape.txt"),          // 可疑路径(路径逃逸)
            item(".DS_Store"),              // 垃圾
            item("__MACOSX/._x"),           // 垃圾
            item("secret.bin", encrypted: true)
        ])
        #expect(facts.suspiciousPathCount >= 1)
        #expect(facts.junkCount == 2)
        #expect(facts.encryptedCount == 1)
    }

    @Test func cleanItemsYieldZeroFacts() {
        let facts = ArchiveCheckup.entryFacts(items: [
            ArchiveItem(name: "docs/readme.md", isDirectory: false, size: 1, modified: nil,
                        sizeText: "", modifiedText: "", method: "")
        ])
        #expect(facts == ArchiveCheckup.EntryFacts(suspiciousPathCount: 0, junkCount: 0, encryptedCount: 0))
    }
}

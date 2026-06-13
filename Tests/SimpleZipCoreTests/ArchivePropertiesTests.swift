//
//  ArchivePropertiesTests.swift
//  SimpleZipCoreTests
//
//  0.4.4 #13:头部块解析 + 条目聚合。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ArchivePropertiesTests {
    @Test func parsesHeaderBlockOnly() {
        let output = """
        7-Zip (z) 24.09 (arm64)

        Listing archive: /tmp/sample.7z

        --
        Path = /tmp/sample.7z
        Type = 7z
        Physical Size = 12345
        Headers Size = 210
        Method = LZMA2:24
        Solid = +
        Blocks = 2
        Volumes = 3

        ----------
        Path = inner.txt
        Size = 5
        Method = Copy
        Blocks = 9
        """
        let properties = ArchiveProperties.parse(listOutput: output)
        #expect(properties.type == "7z")
        #expect(properties.physicalSizeBytes == 12345)
        #expect(properties.headersSizeBytes == 210)
        #expect(properties.method == "LZMA2:24")
        #expect(properties.solid == true)
        #expect(properties.blocks == 2)      // 条目块的 Blocks = 9 在分隔线之后,不参与
        #expect(properties.volumes == 3)
    }

    @Test func missingFieldsStayNil() {
        let properties = ArchiveProperties.parse(listOutput: "Listing archive: x\n--\nPath = /x.zip\nType = zip\n----------\n")
        #expect(properties.type == "zip")
        #expect(properties.physicalSizeBytes == nil)
        #expect(properties.solid == nil)
    }

    @Test func aggregateCountsMethodsEncryptionAndAppleDouble() {
        func item(_ name: String, directory: Bool = false, method: String = "Deflate", encrypted: Bool = false, attributes: String = "") -> ArchiveItem {
            ArchiveItem(
                name: name, isDirectory: directory, size: directory ? nil : 1,
                modified: nil, sizeText: "", modifiedText: "",
                method: method, isEncrypted: encrypted, attributes: attributes
            )
        }
        let aggregate = ArchiveMetadataAggregate.aggregate(items: [
            item("a.txt"),
            item("b.txt", method: "LZMA2", encrypted: true),
            item("c.txt", method: "LZMA2", attributes: "-rw-r--r--"),
            item("._a.txt"),
            item("__MACOSX/x", attributes: "-rw-r--r--"),
            item("folder", directory: true, method: "")
        ])
        #expect(aggregate.fileCount == 5)
        #expect(aggregate.folderCount == 1)
        #expect(aggregate.encryptedCount == 1)
        #expect(aggregate.appleDoubleCount == 2)
        #expect(aggregate.methodDistribution.first == ArchiveMetadataAggregate.MethodShare(method: "Deflate", count: 3))
        #expect(aggregate.methodDistribution.contains(ArchiveMetadataAggregate.MethodShare(method: "LZMA2", count: 2)))
        #expect(aggregate.topAttributes == [ArchiveMetadataAggregate.MethodShare(method: "-rw-r--r--", count: 2)])
    }
}

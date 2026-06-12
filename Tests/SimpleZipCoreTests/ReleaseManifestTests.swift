//
//  ReleaseManifestTests.swift
//  SimpleZipCoreTests
//
//  0.4.4 #4:发布清单 —— 确定性编码 / 字段契约 / 解码回读。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ReleaseManifestTests {
    private var sample: ReleaseManifest {
        ReleaseManifest(
            name: "MyApp",
            version: "1.2.0",
            generatedBy: "SimpleZip 0.4.4",
            generatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            files: [ReleaseManifest.File(
                name: "MyApp.zip",
                sha256: "deadbeef",
                sizeBytes: 4096,
                structuralFingerprint: "cafebabe"
            )]
        )
    }

    @Test func encodingIsDeterministic() throws {
        let first = try sample.encoded()
        let second = try sample.encoded()
        #expect(first == second)
    }

    @Test func encodedJSONCarriesStableEnglishFields() throws {
        let text = String(decoding: try sample.encoded(), as: UTF8.self)
        #expect(text.contains("\"manifestVersion\" : 1"))
        #expect(text.contains("\"name\" : \"MyApp\""))
        #expect(text.contains("\"version\" : \"1.2.0\""))
        #expect(text.contains("\"sha256\" : \"deadbeef\""))
        #expect(text.contains("\"sizeBytes\" : 4096"))
        #expect(text.contains("\"structuralFingerprint\" : \"cafebabe\""))
        // UTC ISO8601,不随本机时区变。
        #expect(text.contains("\"generatedAt\" : \"2025-06-15T15:06:40Z\""))
    }

    @Test func roundTripsThroughCodable() throws {
        let decoded = try JSONDecoder().decode(ReleaseManifest.self, from: sample.encoded())
        #expect(decoded == sample)
    }

    @Test func nilVersionOmitted() throws {
        let manifest = ReleaseManifest(
            name: "x", version: nil, generatedBy: "g",
            generatedAt: Date(timeIntervalSince1970: 0), files: []
        )
        let text = String(decoding: try manifest.encoded(), as: UTF8.self)
        #expect(!text.contains("\"version\""))
    }
}

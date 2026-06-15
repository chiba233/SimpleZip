//
//  AIDependencyEnvironmentTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:依赖环境嗅探(白皮书 Feat 25)。从 marker 确定性识别生态;敏感配置只记存在不读内容。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIDependencyEnvironmentTests {
    @Test func detectsCommonEcosystems() {
        #expect(AIDependencyEnvironmentDetector.ecosystems(forFiles: ["package.json", "README.md"]) == [.node])
        #expect(AIDependencyEnvironmentDetector.ecosystems(forFiles: ["Sources/App.swift", "Package.swift"]) == [.swiftPackage])
        #expect(AIDependencyEnvironmentDetector.ecosystems(forFiles: ["pyproject.toml"]) == [.python])
        #expect(AIDependencyEnvironmentDetector.ecosystems(forFiles: ["Cargo.toml"]) == [.rust])
        #expect(AIDependencyEnvironmentDetector.ecosystems(forFiles: ["go.mod"]) == [.go])
        #expect(AIDependencyEnvironmentDetector.ecosystems(forFiles: ["pom.xml"]) == [.java])
        #expect(AIDependencyEnvironmentDetector.ecosystems(forFiles: ["App.csproj"]) == [.dotnet])
        #expect(AIDependencyEnvironmentDetector.ecosystems(forFiles: ["Dockerfile"]) == [.docker])
    }

    @Test func ecosystemDetectionIsPathAndCaseInsensitive() {
        let files = ["project/PACKAGE.JSON", "deep/nested/Package.swift"]
        let found = AIDependencyEnvironmentDetector.ecosystems(forFiles: files)
        #expect(found.contains(.node))
        #expect(found.contains(.swiftPackage))
    }

    @Test func ecosystemsAreDeterministicallyOrderedAndDeduped() {
        // 多 marker + 重复:按 allCases 顺序、去重。
        let files = ["package.json", "package.json", "Cargo.toml", "Package.swift"]
        #expect(AIDependencyEnvironmentDetector.ecosystems(forFiles: files) == [.node, .swiftPackage, .rust])
    }

    @Test func sensitiveConfigsRecordedButNotRead() {
        let files = [".npmrc", ".env", "gradle.properties", "package.json", "README.md"]
        let blocked = AIDependencyEnvironmentDetector.blockedConfigFiles(in: files)
        #expect(Set(blocked) == [".npmrc", ".env", "gradle.properties"])
        // 普通文件不进 blocked。
        #expect(!blocked.contains("README.md"))
    }

    @Test func makeFactsBundlesMarkersEcosystemsAndBlocked() {
        let facts = AIDependencyEnvironmentDetector.makeFacts(
            sourceRef: AIContextSourceRef(kind: .archive, id: "arch-1"),
            files: ["package.json", ".npmrc", "src/index.ts", "README.md"])
        #expect(facts.detectedEcosystems == [.node])
        #expect(facts.markerFiles == ["package.json"]) // 只 marker,不含普通源文件
        #expect(facts.blockedFiles == [".npmrc"])
    }

    @Test func deterministicCardsCarryEvidenceAndCautions() {
        let facts = AIDependencyEnvironmentDetector.makeFacts(
            sourceRef: AIContextSourceRef(kind: .folder, id: "folder-1"),
            files: ["package.json", ".env"])
        let cards = AIDependencyEnvironmentDetector.deterministicCards(from: facts)
        #expect(cards.count == 1)
        #expect(cards.first?.ecosystem == .node)
        #expect(cards.first?.title == nil) // 留 App L10n / 模型润色
        #expect(cards.first?.cautions.contains(".env present but content blocked") == true)
    }

    @Test func noMarkersYieldNoEcosystems() {
        #expect(AIDependencyEnvironmentDetector.ecosystems(forFiles: ["a.txt", "b.png"]).isEmpty)
    }

    @Test func factsCodableRoundTrip() throws {
        let facts = AIDependencyEnvironmentDetector.makeFacts(
            sourceRef: AIContextSourceRef(kind: .archive, id: "arch-1"),
            files: ["go.mod", "Dockerfile"],
            manifestSummaries: [AIFileContentSummary(mode: "text-summary", fieldNames: ["module", "go"])])
        let decoded = try JSONDecoder().decode(AIDependencyEnvironmentFacts.self, from: JSONEncoder().encode(facts))
        #expect(decoded == facts)
    }
}

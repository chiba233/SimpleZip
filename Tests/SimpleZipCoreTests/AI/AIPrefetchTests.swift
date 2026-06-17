//
//  AIPrefetchTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:后台预读档位/预算/作用域 + 默认排除安全规则(工程补充五/六/七)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIPrefetchTests {
    @Test func offLevelHasNoBudget() {
        #expect(AIArchivePrefetchBudget.forLevel(.off) == nil)
    }

    @Test func budgetTiersGrowWithActivity() {
        let saver = AIArchivePrefetchBudget.forLevel(.powerSaver)!
        let balanced = AIArchivePrefetchBudget.forLevel(.balanced)!
        let aggressive = AIArchivePrefetchBudget.forLevel(.aggressive)!
        #expect(saver.maxArchivesPerRound < balanced.maxArchivesPerRound)
        #expect(balanced.maxArchivesPerRound < aggressive.maxArchivesPerRound)
        #expect(balanced.maxEntriesPerArchive == 10_000)
    }

    @Test func everyActivityLevelHasStableToken() {
        for l in AIBackgroundActivityLevel.allCases { #expect(!l.rawValue.isEmpty) }
    }

    @Test func excludesSystemAndKeyDirectories() {
        let home = "/Users/tester"
        #expect(AIPrefetchExclusions.shouldExclude(directoryPath: "/System/Library", home: home))
        #expect(AIPrefetchExclusions.shouldExclude(directoryPath: "/Library/Caches", home: home))
        #expect(AIPrefetchExclusions.shouldExclude(directoryPath: "/Users/tester/Library/Mail", home: home))
        #expect(AIPrefetchExclusions.shouldExclude(directoryPath: "/Users/tester/.ssh", home: home))
        #expect(AIPrefetchExclusions.shouldExclude(directoryPath: "/Users/tester/.gnupg", home: home))
        #expect(AIPrefetchExclusions.shouldExclude(directoryPath: "/Users/tester/proj/.git", home: home))
        #expect(AIPrefetchExclusions.shouldExclude(directoryPath: "/Users/tester/proj/node_modules/x", home: home))
    }

    /// 安全:凭据 / 密钥目录(与 AIFileReadabilityPolicy 敏感集对齐)在目录扫描层也必须被排除 ——
    /// 后台预读不得索引这些位置的文件名 / 元数据。
    @Test func excludesCredentialDirectories() {
        let home = "/Users/tester"
        for dir in [".docker", ".azure", ".gcloud", ".password-store", "keychains",
                    ".netrc", ".npmrc", ".pypirc", ".htpasswd", ".secrets", ".private",
                    ".env", "credentials"] {
            #expect(AIPrefetchExclusions.shouldExclude(directoryName: dir))
            #expect(AIPrefetchExclusions.shouldExclude(directoryPath: "\(home)/work/\(dir)", home: home))
        }
    }

    @Test func excludesTemporaryAndDecryptDirectories() {
        #expect(AIPrefetchExclusions.shouldExclude(directoryPath: "/private/var/folders/ab/cd"))
        #expect(AIPrefetchExclusions.shouldExclude(directoryPath: "/tmp/SimpleZip-extract-XYZ"))
        #expect(AIPrefetchExclusions.shouldExclude(directoryPath: ""))
    }

    @Test func allowsOrdinaryUserDirectories() {
        let home = "/Users/tester"
        #expect(!AIPrefetchExclusions.shouldExclude(directoryPath: "/Users/tester/Downloads", home: home))
        #expect(!AIPrefetchExclusions.shouldExclude(directoryPath: "/Users/tester/Desktop/release", home: home))
        #expect(!AIPrefetchExclusions.shouldExclude(directoryPath: "/Users/tester/Documents/proj", home: home))
    }

    @Test func directoryNameRuleCatchesDevDeps() {
        #expect(AIPrefetchExclusions.shouldExclude(directoryName: "node_modules"))
        #expect(AIPrefetchExclusions.shouldExclude(directoryName: ".git"))
        #expect(!AIPrefetchExclusions.shouldExclude(directoryName: "Sources"))
    }

    @Test func scopeRoundTripsThroughCodable() throws {
        let scope = AIArchivePrefetchScope(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            directoryPath: "/Users/tester/Downloads", origin: .suggestedSafeDirectory,
            createdAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(scope)
        #expect(try JSONDecoder().decode(AIArchivePrefetchScope.self, from: data) == scope)
    }

    @Test func everyListingStatusHasStableToken() {
        for s in AIArchivePrefetchListingStatus.allCases { #expect(!s.rawValue.isEmpty) }
    }
}

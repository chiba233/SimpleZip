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

    @Test func archiveListingRoundBudgetUsesActivityTierValue() {
        #expect(AIArchivePrefetchBudget.forLevel(.powerSaver)?.maxArchiveListingsPerRound == 10)
        #expect(AIArchivePrefetchBudget.forLevel(.balanced)?.maxArchiveListingsPerRound == 40)
        #expect(AIArchivePrefetchBudget.forLevel(.aggressive)?.maxArchiveListingsPerRound == 120)
    }

    @Test func aggressiveModelSuggestionBudgetStaysWithinHeartbeatFairnessLimit() {
        #expect(AIArchivePrefetchBudget.forLevel(.powerSaver)?.maxModelSuggestionsPerRound == 1)
        #expect(AIArchivePrefetchBudget.forLevel(.balanced)?.maxModelSuggestionsPerRound == 3)
        #expect(AIArchivePrefetchBudget.forLevel(.aggressive)?.maxModelSuggestionsPerRound == 2)
    }

    @Test func modelCallTimeoutReturnsCompletedOperation() async throws {
        let value = try await AIModelCallTimeout.run(after: .seconds(1)) { "ok" }
        #expect(value == "ok")
    }

    @Test func modelCallTimeoutThrowsWhenOperationDoesNotFinish() async throws {
        do {
            _ = try await AIModelCallTimeout.run(after: .milliseconds(1)) {
                try await Task.sleep(for: .seconds(30))
                return "late"
            }
            Issue.record("Expected the model-call timeout to throw")
        } catch is CancellationError {
            // Expected.
        }
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

    /// 包 / 工程目录(`.app` / `.framework` / `.xcodeproj` …)按后缀拦,名字随应用千变万化,精确匹配抓不到 ——
    /// 不拦就会下探 `Firefox.app/Contents/MacOS` 灌一堆二进制垃圾进候选池。
    @Test func excludesPackageBundlesBySuffix() {
        let home = "/Users/tester"
        for name in ["Firefox.app", "MyApp.app", "Sparkle.framework", "Some.bundle",
                     "SimpleZip.xcodeproj", "Workspace.xcworkspace", "Photos.photoslibrary",
                     "Debug.dSYM", "Plugin.appex"] {
            #expect(AIPrefetchExclusions.shouldExclude(directoryName: name), "\(name) 应按后缀排除")
        }
        // 路径里任一段命中后缀即不下探(包内部不索引)
        #expect(AIPrefetchExclusions.shouldExclude(
            directoryPath: "\(home)/Applications/Firefox.app/Contents/MacOS", home: home))
        #expect(AIPrefetchExclusions.shouldExclude(
            directoryPath: "\(home)/Dev/SimpleZip.xcodeproj/project.xcworkspace", home: home))
        // 普通文件夹名不被后缀误伤
        #expect(!AIPrefetchExclusions.shouldExclude(directoryName: "myapp"))
        #expect(!AIPrefetchExclusions.shouldExclude(directoryName: "framework-notes"))
    }

    /// 扩充的开发依赖 / 构建产物 / 缓存目录(`node_modules` 之外的长尾)也不下探。
    @Test func excludesExpandedDevNoiseDirectories() {
        let home = "/Users/tester"
        for name in ["Pods", "Carthage", "vendor", "bower_components", ".gradle", ".cargo",
                     "__pycache__", ".pytest_cache", ".venv", "site-packages", ".next",
                     ".turbo", ".terraform", "coverage", ".idea", ".vscode", "out", "obj"] {
            #expect(AIPrefetchExclusions.shouldExclude(directoryName: name), "\(name) 应被排除")
            #expect(AIPrefetchExclusions.shouldExclude(directoryPath: "\(home)/proj/\(name)/x", home: home),
                    "\(name) 路径段应被排除")
        }
        // 普通用户目录不被误伤
        #expect(!AIPrefetchExclusions.shouldExclude(directoryPath: "\(home)/Documents/vendor-contracts", home: home))
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

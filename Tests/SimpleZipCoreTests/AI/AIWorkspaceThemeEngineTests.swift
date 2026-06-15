//
//  AIWorkspaceThemeEngineTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80 #89:推荐工作区主题确定性生成器(白皮书建议四「动态主题」/「主动主题发现」)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIWorkspaceThemeEngineTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func loc(_ kind: AILocationKind, token: String) -> AILocationContext {
        AILocationContext(kind: kind, pathHash: "loc-" + token, folderNameTokens: [token])
    }

    private func fact(_ path: String, size: Int64? = nil, modified: Date? = nil,
                      loc: AILocationContext) -> AIFileSystemFact {
        AIFileSystemFact.make(absolutePath: path, location: loc, byteSize: size, modifiedAt: modified,
                              posixMode: "rw-r--r--", currentUserCanRead: true, currentUserCanWrite: true,
                              currentUserCanExecute: false, isDirectory: false)
    }

    @Test func releaseFolderProducesReleaseTheme() {
        let l = loc(.other, token: "dist")
        let facts = [
            fact("/Users/me/dist/SHA256SUMS", loc: l),
            fact("/Users/me/dist/SimpleZip.dmg", loc: l),
            fact("/Users/me/dist/SimpleZip.zip", loc: l),
            fact("/Users/me/dist/signature.asc", loc: l)
        ]
        let themes = AIWorkspaceThemeEngine.deterministicThemes(
            from: facts, location: l, folderDisplayName: "dist", now: now)
        let release = themes.first { $0.themeTokens.contains("release") }
        #expect(release != nil)
        #expect(release?.fingerprint != nil)
        #expect(release?.sourceRefs.count == 4)
        // 发布主题覆盖时,不再额外生成泛化「folder」主题(避免重复)。
        #expect(!themes.contains { $0.themeTokens.contains("folder") })
    }

    @Test func projectFolderProducesProjectThemeNamedAfterFolder() {
        let l = loc(.projectFolder, token: "simplezip")
        let facts = [
            fact("/Users/me/SimpleZip/Package.swift", loc: l),
            fact("/Users/me/SimpleZip/main.swift", loc: l),
            fact("/Users/me/SimpleZip/README.md", loc: l)
        ]
        let themes = AIWorkspaceThemeEngine.deterministicThemes(
            from: facts, location: l, folderDisplayName: "SimpleZip", now: now)
        let project = themes.first { $0.themeTokens.contains("project") }
        #expect(project != nil)
        #expect(project?.titleSeed == "SimpleZip")   // 真实文件夹名作种子,非「source files in this folder」
    }

    @Test func mixedFolderProducesFolderThemeNamedAfterFolder() {
        let l = loc(.desktop, token: "paper")
        let facts = [
            fact("/Users/me/Desktop/paper/论文.txt", loc: l),     // document
            fact("/Users/me/Desktop/paper/figure.png", loc: l),  // media
            fact("/Users/me/Desktop/paper/notes.md", loc: l)     // document(markdown)
        ]
        let themes = AIWorkspaceThemeEngine.deterministicThemes(
            from: facts, location: l, folderDisplayName: "paper", now: now)
        let folder = themes.first { $0.themeTokens.contains("folder") }
        #expect(folder != nil)
        #expect(folder?.titleSeed == "paper")
        #expect(folder?.sourceRefs.count == 3)
    }

    @Test func singleRoleFolderDoesNotProduceGenericTheme() {
        // 全是同一种角色(无混合)→ 不生成泛化主题(避免「documents in this folder」式弱主题)。
        let l = loc(.downloads, token: "downloads")
        let facts = [
            fact("/Users/me/Downloads/a.txt", loc: l),
            fact("/Users/me/Downloads/b.txt", loc: l),
            fact("/Users/me/Downloads/c.txt", loc: l)
        ]
        let themes = AIWorkspaceThemeEngine.deterministicThemes(
            from: facts, location: l, folderDisplayName: "Downloads", now: now)
        #expect(!themes.contains { $0.themeTokens.contains("folder") })
    }

    @Test func staleLargeFilesProduceTheme() {
        let l = loc(.documents, token: "archive")
        let old = Date(timeIntervalSince1970: 1_690_000_000)   // > 90 天前(相对 now)
        let big: Int64 = 80_000_000
        let facts = [
            fact("/Users/me/Documents/a.mov", size: big, modified: old, loc: l),
            fact("/Users/me/Documents/b.mov", size: big, modified: old, loc: l),
            fact("/Users/me/Documents/c.mov", size: big, modified: old, loc: l)
        ]
        let themes = AIWorkspaceThemeEngine.deterministicThemes(
            from: facts, location: l, folderDisplayName: "Documents", now: now)
        #expect(themes.contains { $0.themeTokens.contains("stale") })
    }

    @Test func differentFoldersProduceDistinctThemeIDs() {
        let l1 = loc(.projectFolder, token: "proj1")
        let l2 = loc(.projectFolder, token: "proj2")
        let f1 = [fact("/p1/Package.swift", loc: l1), fact("/p1/main.swift", loc: l1)]
        let f2 = [fact("/p2/Package.swift", loc: l2), fact("/p2/main.swift", loc: l2)]
        let t1 = AIWorkspaceThemeEngine.deterministicThemes(from: f1, location: l1, folderDisplayName: "P1", now: now)
        let t2 = AIWorkspaceThemeEngine.deterministicThemes(from: f2, location: l2, folderDisplayName: "P2", now: now)
        // 不同文件夹的项目主题 id 必须不同(含 location.pathHash)→ 不会互相覆盖。
        #expect(t1.first?.id != t2.first?.id)
    }

    @Test func recommendedWorkspaceUsesDeterministicID() {
        let l = loc(.projectFolder, token: "x")
        let facts = [fact("/x/Package.swift", loc: l), fact("/x/main.swift", loc: l)]
        let theme = AIWorkspaceThemeEngine.deterministicThemes(
            from: facts, location: l, folderDisplayName: "X", now: now).first!
        let ws1 = theme.toRecommendedWorkspace(generatedAt: now)
        let ws2 = theme.toRecommendedWorkspace(generatedAt: now)
        #expect(ws1.id == ws2.id)               // 可复现
        #expect(ws1.origin == .recommended)
        #expect(ws1.title == theme.titleSeed)
    }

    @Test func emptyFactsProduceNoThemes() {
        let l = loc(.other, token: "x")
        #expect(AIWorkspaceThemeEngine.deterministicThemes(
            from: [], location: l, folderDisplayName: "x", now: now).isEmpty)
    }
}

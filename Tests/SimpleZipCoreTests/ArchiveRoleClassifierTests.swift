//
//  ArchiveRoleClassifierTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:归档角色确定性识别(Feat 5)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ArchiveRoleClassifierTests {
    private func item(_ name: String, dir: Bool = false) -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: dir, size: 0, modified: nil,
                    sizeText: "", modifiedText: "", method: "")
    }

    private func profile(_ names: [String]) -> ArchiveProfile {
        ArchiveProfile.derive(from: names.map { item($0) })
    }

    @Test func sourcePackageFromSwiftProject() {
        let p = profile(["App/Package.swift", "App/a.swift", "App/b.swift", "App/c.swift",
                         "App/d.swift", "App/e.swift", "App/README.md"])
        #expect(ArchiveRoleClassifier.primaryRole(for: p) == .sourcePackage)
    }

    @Test func releasePackageFromChecksumsAndArtifacts() {
        let p = profile(["SHA256SUMS", "SimpleZip.dmg", "PUBLIC_KEY.asc"])
        #expect(ArchiveRoleClassifier.primaryRole(for: p) == .releasePackage)
    }

    @Test func mediaBundleFromMediaHeavyContent() {
        let p = profile(["a.jpg", "b.jpg", "c.png", "d.heic", "e.mov", "f.mp4", "notes.txt"])
        #expect(ArchiveRoleClassifier.primaryRole(for: p) == .mediaBundle)
    }

    @Test func signedContainerFromSzs() {
        let p = profile(["bundle.szs", "signature.asc", "metadata.json"])
        let roles = ArchiveRoleClassifier.classify(profile: p)
        #expect(roles.contains { $0.role == .signedContainer && $0.score > 0.4 })
    }

    @Test func configBundleFromConfigHeavyContent() {
        let p = profile(["app.yaml", "db.json", "server.conf", "cache.ini", "readme.txt"])
        #expect(ArchiveRoleClassifier.primaryRole(for: p) == .configBundle)
    }

    @Test func unknownWhenNoStrongSignal() {
        let p = profile(["a.bin", "b.dat"])
        #expect(ArchiveRoleClassifier.primaryRole(for: p) == .unknown)
    }

    @Test func scoresAreDeterministicAndDescending() {
        let p = profile(["SHA256SUMS", "SimpleZip.dmg", "PUBLIC_KEY.asc"])
        let a = ArchiveRoleClassifier.classify(profile: p)
        let b = ArchiveRoleClassifier.classify(profile: p)
        #expect(a == b)
        #expect(a == a.sorted { $0.score >= $1.score })
    }

    @Test func scoresNeverExceedOne() {
        let p = profile(["SHA256SUMS", "SimpleZip.dmg", "PUBLIC_KEY.asc", "VERIFY.md", "SimpleZip.app/Contents/Info.plist"])
        #expect(ArchiveRoleClassifier.classify(profile: p).allSatisfy { $0.score <= 1.0 })
    }

    @Test func reasonsAreProvided() {
        let p = profile(["App/Package.swift", "App/a.swift", "App/b.swift", "App/c.swift", "App/d.swift", "App/e.swift"])
        let source = ArchiveRoleClassifier.classify(profile: p).first { $0.role == .sourcePackage }
        #expect(source?.reasons.isEmpty == false)
    }
}

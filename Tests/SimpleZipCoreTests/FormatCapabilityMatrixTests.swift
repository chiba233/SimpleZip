import Foundation
import Testing
@testable import SimpleZipCore

/// 锁住「格式能力矩阵」的关键事实，避免改 `ArchiveCreateFormat` 能力时矩阵悄悄漂移。
struct FormatCapabilityMatrixTests {

    private func row(_ id: String) -> FormatCapabilityRow? {
        FormatCapabilityMatrix.rows.first { $0.id == id }
    }

    @Test func everyExpectedFormatHasARow() {
        let ids = Set(FormatCapabilityMatrix.rows.map(\.id))
        for expected in ["zip", "7z", "rar", "tar", "tgz", "dmg", "gpg", "siz", "szs"] {
            #expect(ids.contains(expected), "missing row: \(expected)")
        }
    }

    @Test func rarCreationIsConditionalEverythingElseCreates() {
        #expect(row("rar")?.create == .conditional)
        #expect(row("zip")?.create == .yes)
        #expect(row("7z")?.create == .yes)
    }

    @Test func encryptColumnMatchesPasswordSupport() {
        // 复用 ArchiveCreateFormat.supportsPassword → ZIP/7z 加密，TAR 不加密。
        #expect(row("zip")?.encrypt == .yes)
        #expect(row("7z")?.encrypt == .yes)
        #expect(row("tar")?.encrypt == .no)
        #expect(row("tgz")?.encrypt == .no)
    }

    @Test func headerEncryptionOnlyForSevenZipAndRar() {
        #expect(row("7z")?.headerEncrypt == .yes)
        #expect(row("rar")?.headerEncrypt == .yes)
        #expect(row("zip")?.headerEncrypt == .no)
        #expect(row("tar")?.headerEncrypt == .no)
    }

    @Test func editColumnOnlyZipAndSevenZip() {
        // 「编辑/增删条目」与 ArchiveService.supportsEntryUpdate 同口径:仅 zip/7z。
        #expect(row("zip")?.editEntries == .yes)
        #expect(row("7z")?.editEntries == .yes)
        #expect(row("rar")?.editEntries == .no)
        #expect(row("tar")?.editEntries == .no)
        #expect(row("dmg")?.editEntries == .no)
        #expect(row("siz")?.editEntries == .no)
        #expect(row("szs")?.editEntries == .no)
    }

    @Test func splitColumnMatchesVolumeSupport() {
        #expect(row("zip")?.splitVolumes == .yes)
        #expect(row("7z")?.splitVolumes == .yes)
        #expect(row("rar")?.splitVolumes == .yes)
        #expect(row("tar")?.splitVolumes == .no)
        #expect(row("dmg")?.splitVolumes == .no)
    }

    @Test func signedContainersTestColumnIsVerify() {
        // .siz / .szs 的「测试」= 验签（完整性）。
        #expect(row("siz")?.test == .yes)
        #expect(row("szs")?.test == .yes)
        // 三个签名/加密容器都能加密。
        #expect(row("gpg")?.encrypt == .yes)
        #expect(row("siz")?.encrypt == .yes)
        #expect(row("szs")?.encrypt == .yes)
    }
}

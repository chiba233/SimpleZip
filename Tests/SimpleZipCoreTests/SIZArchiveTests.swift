import Foundation
import Testing
@testable import SimpleZipCore

struct SIZArchiveTests {
    @Test
    func wrapAndUnwrapRoundTripsRequiredFiles() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let innerArchive = tempDirectory.appendingPathComponent("payload.zip")
        let signature = tempDirectory.appendingPathComponent("payload.zip.asc")
        try Data("archive-bytes".utf8).write(to: innerArchive)
        try Data("signature-bytes".utf8).write(to: signature)

        let output = tempDirectory.appendingPathComponent("payload.siz")
        try await SIZArchive.wrap(
            innerArchive: innerArchive,
            signatureFile: signature,
            metadata: metadata(innerArchiveName: "archive.zip"),
            outputURL: output
        )

        let unwrapDirectory = tempDirectory.appendingPathComponent("unwrap", isDirectory: true)
        let result = try await SIZArchive.unwrap(at: output, to: unwrapDirectory)

        #expect(result.metadata.innerArchiveName == "archive.zip")
        #expect(try Data(contentsOf: result.innerArchiveURL) == Data("archive-bytes".utf8))
        #expect(try Data(contentsOf: result.signatureURL) == Data("signature-bytes".utf8))
    }

    @Test
    func wrapRejectsExistingDestination() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let innerArchive = tempDirectory.appendingPathComponent("payload.zip")
        let signature = tempDirectory.appendingPathComponent("payload.zip.asc")
        let output = tempDirectory.appendingPathComponent("payload.siz")
        try Data("archive".utf8).write(to: innerArchive)
        try Data("signature".utf8).write(to: signature)
        try Data("existing".utf8).write(to: output)

        await #expect(throws: ArchiveError.self) {
            try await SIZArchive.wrap(
                innerArchive: innerArchive,
                signatureFile: signature,
                metadata: metadata(innerArchiveName: "archive.zip"),
                outputURL: output
            )
        }
        #expect(try Data(contentsOf: output) == Data("existing".utf8))
    }

    @Test
    func unwrapRejectsUnsafeMetadataInnerArchiveName() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let container = try makeManualContainer(
            in: tempDirectory,
            metadata: metadata(innerArchiveName: "../escape.zip"),
            extraFiles: [:]
        )

        await #expect(throws: SIZArchive.SIZError.self) {
            _ = try await SIZArchive.unwrap(at: container, to: tempDirectory.appendingPathComponent("out", isDirectory: true))
        }
    }

    @Test
    func unwrapRejectsUnexpectedFiles() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let container = try makeManualContainer(
            in: tempDirectory,
            metadata: metadata(innerArchiveName: "archive.zip"),
            extraFiles: ["extra.txt": Data("surprise".utf8)]
        )

        await #expect(throws: SIZArchive.SIZError.self) {
            _ = try await SIZArchive.unwrap(at: container, to: tempDirectory.appendingPathComponent("out", isDirectory: true))
        }
    }

    @Test
    func unwrapRejectsSymlinkEntries() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let staging = tempDirectory.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try JSONEncoder().encode(metadata(innerArchiveName: "archive.zip"))
            .write(to: staging.appendingPathComponent(SIZArchive.metadataFileName))
        try Data("archive".utf8).write(to: staging.appendingPathComponent("archive.zip"))
        try FileManager.default.createSymbolicLink(
            at: staging.appendingPathComponent(SIZArchive.signatureFileName),
            withDestinationURL: staging.appendingPathComponent("archive.zip")
        )
        let container = tempDirectory.appendingPathComponent("symlink.siz")
        _ = try runProcess("/usr/bin/tar", arguments: ["-cf", container.path, "-C", staging.path, "archive.zip", SIZArchive.metadataFileName, SIZArchive.signatureFileName])

        await #expect(throws: SIZArchive.SIZError.self) {
            _ = try await SIZArchive.unwrap(at: container, to: tempDirectory.appendingPathComponent("out", isDirectory: true))
        }
    }

    @Test
    func signedContainerOptionsRejectSplitVolumesAndSourceDeletion() throws {
        var splitOptions = ArchiveCreationOptions()
        splitOptions.sevenZipVolumeSize = "100m"
        #expect(throws: ArchiveError.self) {
            try SIZArchive.validateCreationOptionsForSignedContainer(splitOptions)
        }

        var deleteOptions = ArchiveCreationOptions()
        deleteOptions.sevenZipDeleteSourceFiles = true
        #expect(throws: ArchiveError.self) {
            try SIZArchive.validateCreationOptionsForSignedContainer(deleteOptions)
        }
    }

    private func metadata(innerArchiveName: String) -> SIZArchive.Metadata {
        SIZArchive.Metadata(
            schema: SIZArchive.schemaIdentifier,
            version: SIZArchive.schemaVersion,
            innerArchiveName: innerArchiveName,
            innerFormat: "zip",
            originalArchiveName: "payload.zip",
            // v2 起 metadata 必须含 inner archive SHA256；测试 fixture 不真做 gpg 验签，给个稳定占位 hex。
            innerArchiveSHA256: String(repeating: "0", count: 64),
            createdAt: "2026-05-29T00:00:00Z",
            createdBy: "SimpleZip Tests",
            signature: SIZArchive.SignatureInfo(
                signerFingerprint: "0123456789ABCDEF0123456789ABCDEF01234567",
                signerUserID: "Test <test@example.com>",
                armorFormat: true
            )
        )
    }

    private func makeManualContainer(
        in tempDirectory: URL,
        metadata: SIZArchive.Metadata,
        extraFiles: [String: Data]
    ) throws -> URL {
        let staging = tempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try JSONEncoder().encode(metadata).write(to: staging.appendingPathComponent(SIZArchive.metadataFileName))
        try Data("signature".utf8).write(to: staging.appendingPathComponent(SIZArchive.signatureFileName))
        try Data("archive".utf8).write(to: staging.appendingPathComponent("archive.zip"))
        for (name, data) in extraFiles {
            try data.write(to: staging.appendingPathComponent(name))
        }

        let output = tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(SIZArchive.extensionName)
        let names = ["archive.zip", SIZArchive.metadataFileName, SIZArchive.signatureFileName] + extraFiles.keys.sorted()
        _ = try runProcess("/usr/bin/tar", arguments: ["-cf", output.path, "-C", staging.path] + names)
        return output
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func runProcess(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        if process.terminationStatus != 0 {
            throw ArchiveError.commandFailed(output)
        }
        return output
    }
}

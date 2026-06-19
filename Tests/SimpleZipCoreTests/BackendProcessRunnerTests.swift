//
//  BackendProcessRunnerTests.swift
//  SimpleZipCoreTests
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct BackendProcessRunnerTests {
    @Test func passwordPromptInputIsNotEchoedIntoCapturedOutput() async throws {
        let secret = "visible-pty-secret"
        let output = try await BackendProcessRunner.runAndCapture(
            "/bin/sh",
            arguments: ["-c", "printf 'Enter password:'; IFS= read -r password; printf '\\nOK\\n'"],
            inputStrategy: .passwordPrompts([secret])
        )

        #expect(output.contains("Enter password:"))
        #expect(output.contains("OK"))
        #expect(!output.contains(secret))
    }

    @Test func sevenZipCreateZipPasswordPromptDoesNotEchoIntoObserverOutput() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SimpleZip-7zzEchoTest-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("payload".utf8).write(to: root.appendingPathComponent("payload.txt"))
        let destination = root.appendingPathComponent("protected.zip")
        let secret = "sevenzip-observer-secret"
        var options = ArchiveCreationOptions()
        options.password = secret
        options.passwordConfirmation = secret
        options.encryptionMethod = .aes256

        let capture = OutputCapture()
        try await SevenZipBackend.createZip(
            destination: destination,
            relativeNames: ["payload.txt"],
            options: options,
            currentDirectory: root,
            progressParser: nil,
            outputObserver: { capture.append($0) },
            operationID: nil
        )

        let observed = capture.value
        #expect(fileManager.fileExists(atPath: destination.path))
        #expect(observed.localizedCaseInsensitiveContains("enter password"))
        #expect(!observed.contains(secret))
    }

    @Test func rarCreatePasswordPromptDoesNotEchoIntoObserverOutputWhenBackendIsAvailable() async throws {
        guard RarBackend.isAvailable() else { return }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SimpleZip-RarEchoTest-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("payload".utf8).write(to: root.appendingPathComponent("payload.txt"))
        let destination = root.appendingPathComponent("protected.rar")
        let secret = "rar-observer-secret"
        var options = ArchiveCreationOptions()
        options.format = .rar
        options.password = secret
        options.passwordConfirmation = secret
        options.sevenZipEncryptFileNames = true

        let capture = OutputCapture()
        try await RarBackend.create(
            destination: destination,
            relativeNames: ["payload.txt"],
            options: options,
            currentDirectory: root,
            progressParser: nil,
            outputObserver: { capture.append($0) },
            operationID: nil
        )

        let observed = capture.value
        #expect(fileManager.fileExists(atPath: destination.path))
        #expect(observed.localizedCaseInsensitiveContains("password"))
        #expect(!observed.contains(secret))
    }
}

private final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks = ""

    func append(_ chunk: String) {
        lock.lock()
        chunks += chunk
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }
}

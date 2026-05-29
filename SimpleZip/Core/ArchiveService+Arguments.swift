//
//  ArchiveService+Arguments.swift
//  SimpleZip
//
//  Created by Copilot on 2026/05/28.
//

import Darwin
import Foundation

extension ArchiveService {
    static func unzipOverwriteArgument(for behavior: OverwriteBehavior) -> String {
        switch behavior {
        case .skipExisting:
            return "-n"
        case .ask, .overwrite, .replaceIfDifferent:
            return "-o"
        }
    }

    static func sevenZipOverwriteArgument(for behavior: OverwriteBehavior) -> String {
        switch behavior {
        case .skipExisting:
            return "-aos"
        case .ask, .overwrite, .replaceIfDifferent:
            return "-aoa"
        }
    }

    static func sevenZipExtractArguments(
        command: String,
        archive: URL,
        entries: [String],
        destination: URL,
        overwriteBehavior: OverwriteBehavior,
        password _: String
    ) -> [String] {
        var arguments = [command, archive.path]
        arguments.append(contentsOf: entries)
        arguments.append(contentsOf: ["-o\(destination.path)", sevenZipOverwriteArgument(for: overwriteBehavior), "-bb1", "-bsp1", "-y"])
        return arguments
    }

    static func sevenZipExcludeArguments(from options: ArchiveCreationOptions) -> [String] {
        zipExcludePatterns(from: options).map { "-xr!\($0)" }
    }

    static func tarExcludeArguments(from options: ArchiveCreationOptions) -> [String] {
        zipExcludePatterns(from: options).map { "--exclude=\($0)" }
    }

    static func sevenZipCreateArguments(destination: URL, relativeNames: [String], options: ArchiveCreationOptions) throws -> [String] {
        let command = sevenZipCommand(for: options.updateMode)
        var arguments = [command, "-t7z", "-mx=\(options.compressionLevel.rawValue)", "-bb1", "-bsp1", "-y"]
        arguments.append(contentsOf: sevenZipUpdateArguments(for: options.updateMode))
        if !options.password.isEmpty {
            arguments.append("-p")
            arguments.append(options.sevenZipEncryptFileNames ? "-mhe=on" : "-mhe=off")
        }
        if options.createSFXArchive {
            arguments.append("-sfx")
        }
        arguments.append("-md=\(options.sevenZipDictionarySizeMB)m")
        arguments.append("-mfb=\(options.sevenZipWordSize)")
        if options.sevenZipSolidArchive {
            if let blockSize = options.sevenZipSolidBlockSize.argumentValue {
                arguments.append("-ms=\(blockSize)")
            } else {
                arguments.append("-ms=on")
            }
        } else {
            arguments.append("-ms=off")
        }
        if let method = options.sevenZipMethod.argumentValue {
            arguments.append("-m0=\(method)")
        }
        if options.sevenZipThreadCount > 0 {
            arguments.append("-mmt=\(options.sevenZipThreadCount)")
        }
        if options.sevenZipPathMode == .full {
            arguments.append("-spf")
        }
        if options.sevenZipStoreSymbolicLinks {
            arguments.append("-snl")
        }
        if options.sevenZipStoreHardLinks {
            arguments.append("-snh")
        }
        if options.sevenZipCompressSharedFiles {
            arguments.append("-ssw")
        }
        if options.sevenZipDeleteSourceFiles {
            arguments.append("-sdel")
        }
        if let volumeSize = try normalizedSevenZipVolumeSize(from: options.sevenZipVolumeSize) {
            arguments.append("-v\(volumeSize)")
        }
        arguments.append(contentsOf: sevenZipExcludeArguments(from: options))
        arguments.append(contentsOf: splitCommandLineArguments(from: options.rawParameters))
        arguments.append(destination.path)
        arguments.append(contentsOf: relativeNames)
        return arguments
    }

    static func sevenZipZipCreateArguments(destination: URL, relativeNames: [String], options: ArchiveCreationOptions) throws -> [String] {
        let command = sevenZipCommand(for: options.updateMode)
        var arguments = [command, "-tzip", "-mx=\(options.compressionLevel.rawValue)", "-bb1", "-bsp1", "-y"]
        arguments.append(contentsOf: sevenZipUpdateArguments(for: options.updateMode))
        if !options.password.isEmpty {
            arguments.append("-p")
            arguments.append("-mem=\(options.encryptionMethod.zipArgumentValue)")
        }
        if options.sevenZipThreadCount > 0 {
            arguments.append("-mmt=\(options.sevenZipThreadCount)")
        }
        if options.sevenZipPathMode == .full {
            arguments.append("-spf")
        }
        if let volumeSize = try normalizedSevenZipVolumeSize(from: options.sevenZipVolumeSize) {
            arguments.append("-v\(volumeSize)")
        }
        arguments.append(contentsOf: sevenZipExcludeArguments(from: options))
        arguments.append(contentsOf: splitCommandLineArguments(from: options.rawParameters))
        arguments.append(destination.path)
        arguments.append(contentsOf: relativeNames)
        return arguments
    }

    static func rarCreateArguments(destination: URL, relativeNames: [String], options: ArchiveCreationOptions) throws -> [String] {
        var arguments = [rarCommand(for: options.updateMode), "-ma5", "-m\(rarCompressionLevel(for: options.compressionLevel))", "-r"]
        if options.sevenZipPathMode == .relative {
            arguments.append("-ep1")
        }
        if options.createSFXArchive {
            arguments.append("-sfx")
        }
        if options.sevenZipDeleteSourceFiles {
            arguments.append("-df")
        }
        if let volumeSize = try normalizedSevenZipVolumeSize(from: options.sevenZipVolumeSize) {
            arguments.append("-v\(volumeSize)")
        }
        if !options.password.isEmpty {
            arguments.append(options.sevenZipEncryptFileNames ? "-hp" : "-p")
        }
        arguments.append(contentsOf: rarExcludeArguments(from: options))
        arguments.append(contentsOf: splitCommandLineArguments(from: options.rawParameters))
        arguments.append(destination.path)
        arguments.append(contentsOf: relativeNames)
        return arguments
    }

    static func normalizedSevenZipVolumeSize(from text: String) throws -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.range(of: #"(?i)^\d+[bkmg]?$"#, options: .regularExpression) != nil else {
            throw ArchiveError.invalidSevenZipVolumeSize
        }
        return trimmed.lowercased()
    }

    nonisolated static func customExcludePatterns(from text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: "\n,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated static func excludedFileCount(in sourceURLs: [URL], options: ArchiveCreationOptions) -> Int {
        let patterns = zipExcludePatterns(from: options)
        guard !patterns.isEmpty, let parentURL = sourceURLs.first?.deletingLastPathComponent() else {
            return 0
        }
        return regularFileURLs(in: sourceURLs).filter { url in
            let relativePath = relativePathForExcludePreview(url, parent: parentURL)
            return patterns.contains { pattern in
                matchesExcludePattern(pattern, relativePath: relativePath, fileName: url.lastPathComponent)
            }
        }.count
    }

    nonisolated static func regularFileURLs(in urls: [URL]) -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        return urls.flatMap { url -> [URL] in
            guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return [url] }
            if values.isRegularFile == true {
                return [url]
            }
            guard values.isDirectory == true,
                  let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: Array(resourceKeys)
                  )
            else {
                return []
            }
            var files: [URL] = []
            for case let fileURL as URL in enumerator {
                if (try? fileURL.resourceValues(forKeys: resourceKeys).isRegularFile) == true {
                    files.append(fileURL)
                }
            }
            return files
        }
    }

    static func splitCommandLineArguments(from text: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quoteCharacter: Character?
        var escaping = false

        for character in text {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if quoteCharacter != nil && character == "\\" {
                escaping = true
                continue
            }
            if character == "\"" || character == "'" {
                if quoteCharacter == character {
                    quoteCharacter = nil
                } else if quoteCharacter == nil {
                    quoteCharacter = character
                } else {
                    current.append(character)
                }
                continue
            }
            if character.isWhitespace && quoteCharacter == nil {
                if !current.isEmpty {
                    arguments.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }

        if escaping {
            current.append("\\")
        }
        if !current.isEmpty {
            arguments.append(current)
        }
        return arguments
    }

    static func nativeZipFallbackSupported(for options: ArchiveCreationOptions) -> Bool {
        options.updateMode == .addAndReplace &&
        !options.createSFXArchive &&
        options.rawParameters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        options.sevenZipPathMode == .relative &&
        (try? normalizedSevenZipVolumeSize(from: options.sevenZipVolumeSize)) == nil &&
        (options.password.isEmpty || options.encryptionMethod == .zipCrypto)
    }

    static func passwordResponses(for options: ArchiveCreationOptions) -> [String] {
        let confirmation = options.passwordConfirmation.isEmpty ? options.password : options.passwordConfirmation
        return [options.password, confirmation]
    }

    static func sevenZipCommand(for updateMode: ArchiveUpdateMode) -> String {
        switch updateMode {
        case .addAndReplace:
            return "a"
        case .updateAndAdd, .freshen, .synchronize:
            return "u"
        }
    }

    static func sevenZipUpdateArguments(for updateMode: ArchiveUpdateMode) -> [String] {
        switch updateMode {
        case .addAndReplace, .updateAndAdd:
            return []
        case .freshen:
            return ["-up1q1r0x1y2z1w2"]
        case .synchronize:
            return ["-up1q0r2x1y2z1w2"]
        }
    }

    static func rarCommand(for updateMode: ArchiveUpdateMode) -> String {
        switch updateMode {
        case .addAndReplace:
            return "a"
        case .updateAndAdd:
            return "u"
        case .freshen:
            return "f"
        case .synchronize:
            return "s"
        }
    }

    static func rarCompressionLevel(for level: CompressionLevel) -> Int {
        switch level {
        case .store:
            return 0
        case .fast:
            return 1
        case .normal:
            return 3
        case .maximum:
            return 5
        }
    }

    static func rarExcludeArguments(from options: ArchiveCreationOptions) -> [String] {
        zipExcludePatterns(from: options).map { "-x\($0)" }
    }

    private nonisolated static func relativePathForExcludePreview(_ url: URL, parent: URL) -> String {
        let parentPath = parent.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        guard filePath.hasPrefix(prefix) else {
            return url.lastPathComponent
        }
        return String(filePath.dropFirst(prefix.count))
    }

    private nonisolated static func matchesExcludePattern(_ pattern: String, relativePath: String, fileName: String) -> Bool {
        fnmatch(pattern, relativePath, 0) == 0 || fnmatch(pattern, fileName, 0) == 0
    }
}

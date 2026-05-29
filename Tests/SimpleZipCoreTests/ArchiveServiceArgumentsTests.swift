//
//  ArchiveServiceArgumentsTests.swift
//  SimpleZip
//
//  围绕参数构造、路由 gate 和命令映射的纯逻辑测试。
//  与 ArchiveServiceTests 里的「正向流程 / 文件 round-trip」测试分开放，
//  目的是给 Phase 3/4 重构提供更细的安全网：
//  改 ArchiveService 拆成 Backend 协议时，任何分支映射弄错都会被这些测试逮住。
//

import Foundation
import Testing
@testable import SimpleZipCore

struct ArchiveServiceArgumentsTests {

    // MARK: - Overwrite 行为映射

    @Test
    func unzipOverwriteArgumentMapsEachBehavior() {
        #expect(ArchiveService.unzipOverwriteArgument(for: .skipExisting) == "-n")
        #expect(ArchiveService.unzipOverwriteArgument(for: .ask) == "-o")
        #expect(ArchiveService.unzipOverwriteArgument(for: .overwrite) == "-o")
        #expect(ArchiveService.unzipOverwriteArgument(for: .replaceIfDifferent) == "-o")
    }

    @Test
    func sevenZipOverwriteArgumentMapsEachBehavior() {
        #expect(ArchiveService.sevenZipOverwriteArgument(for: .skipExisting) == "-aos")
        #expect(ArchiveService.sevenZipOverwriteArgument(for: .ask) == "-aoa")
        #expect(ArchiveService.sevenZipOverwriteArgument(for: .overwrite) == "-aoa")
        #expect(ArchiveService.sevenZipOverwriteArgument(for: .replaceIfDifferent) == "-aoa")
    }

    // MARK: - 7-Zip 解压参数

    @Test
    func sevenZipExtractArgumentsIncludeEntriesAndDestination() {
        let arguments = ArchiveService.sevenZipExtractArguments(
            command: "x",
            archive: URL(fileURLWithPath: "/tmp/in.7z"),
            entries: ["dir/file.txt"],
            destination: URL(fileURLWithPath: "/tmp/out"),
            overwriteBehavior: .ask,
            password: ""
        )

        // 命令 + 归档路径在最前；entries 跟随其后；选项段在末尾。
        #expect(arguments.first == "x")
        #expect(arguments.contains("/tmp/in.7z"))
        #expect(arguments.contains("dir/file.txt"))
        #expect(arguments.contains("-o/tmp/out"))
        #expect(arguments.contains("-aoa"))
        #expect(arguments.contains("-bb1"))
        #expect(arguments.contains("-bsp1"))
        #expect(arguments.contains("-y"))
    }

    @Test
    func sevenZipExtractArgumentsUseSkipExistingFlag() {
        let arguments = ArchiveService.sevenZipExtractArguments(
            command: "x",
            archive: URL(fileURLWithPath: "/tmp/in.7z"),
            entries: [],
            destination: URL(fileURLWithPath: "/tmp/out"),
            overwriteBehavior: .skipExisting,
            password: ""
        )

        #expect(arguments.contains("-aos"))
        #expect(!arguments.contains("-aoa"))
    }

    // MARK: - updateMode → command 映射

    @Test
    func sevenZipCommandReflectsUpdateMode() {
        #expect(ArchiveService.sevenZipCommand(for: .addAndReplace) == "a")
        // 7-Zip 不区分 freshen / sync 命令，三者都落到 "u"。
        #expect(ArchiveService.sevenZipCommand(for: .updateAndAdd) == "u")
        #expect(ArchiveService.sevenZipCommand(for: .freshen) == "u")
        #expect(ArchiveService.sevenZipCommand(for: .synchronize) == "u")
    }

    @Test
    func sevenZipUpdateArgumentsAreEmptyForBasicModes() {
        #expect(ArchiveService.sevenZipUpdateArguments(for: .addAndReplace).isEmpty)
        #expect(ArchiveService.sevenZipUpdateArguments(for: .updateAndAdd).isEmpty)
    }

    @Test
    func sevenZipUpdateArgumentsEncodeFreshenAndSyncSemantics() {
        // 这两个 update flag 字符串是 7-Zip 命令行里的位掩码语义，写错会导致严重的数据丢失行为，
        // 所以这里直接对值做精确匹配 —— 任何一个字符变动都会立刻失败。
        #expect(ArchiveService.sevenZipUpdateArguments(for: .freshen) == ["-up1q1r0x1y2z1w2"])
        #expect(ArchiveService.sevenZipUpdateArguments(for: .synchronize) == ["-up1q0r2x1y2z1w2"])
    }

    @Test
    func rarCommandReflectsUpdateMode() {
        // RAR 跟 7-Zip 不同，四种模式各对应独立命令字符。
        #expect(ArchiveService.rarCommand(for: .addAndReplace) == "a")
        #expect(ArchiveService.rarCommand(for: .updateAndAdd) == "u")
        #expect(ArchiveService.rarCommand(for: .freshen) == "f")
        #expect(ArchiveService.rarCommand(for: .synchronize) == "s")
    }

    @Test
    func rarCompressionLevelMapsAllCases() {
        // RAR 命令行接受的压缩等级是 0/1/3/5 这几个非连续值，是 RAR 历史规范，不要改。
        #expect(ArchiveService.rarCompressionLevel(for: .store) == 0)
        #expect(ArchiveService.rarCompressionLevel(for: .fast) == 1)
        #expect(ArchiveService.rarCompressionLevel(for: .normal) == 3)
        #expect(ArchiveService.rarCompressionLevel(for: .maximum) == 5)
    }

    // MARK: - 密码响应回退

    @Test
    func passwordResponsesFallBackToPasswordWhenConfirmationEmpty() {
        var options = ArchiveCreationOptions()
        options.password = "abc"
        options.passwordConfirmation = ""

        // 7-Zip / RAR 在提示密码时会问两遍，confirmation 空意味着「重复一次输入」。
        // 这里必须用 password 兜底，否则进程会卡住等第二次输入。
        #expect(ArchiveService.passwordResponses(for: options) == ["abc", "abc"])
    }

    @Test
    func passwordResponsesPreservesExplicitConfirmation() {
        var options = ArchiveCreationOptions()
        options.password = "abc"
        options.passwordConfirmation = "def"

        // 即便两个密码不一致也照原样发出 —— 验证逻辑在更上层，这里只负责传输。
        #expect(ArchiveService.passwordResponses(for: options) == ["abc", "def"])
    }

    // MARK: - 原生 zip fallback 的开关

    @Test
    func nativeZipFallbackSupportedForBasicConfig() {
        // 默认 options 全是「最基本」选项，应该允许走原生 zip 命令而不调 7zz。
        let options = ArchiveCreationOptions()
        #expect(ArchiveService.nativeZipFallbackSupported(for: options))
    }

    @Test
    func nativeZipFallbackBlockedByUpdateMode() {
        // updateMode != addAndReplace 时原生 zip 不支持，必须走 7zz。
        var options = ArchiveCreationOptions()
        options.updateMode = .freshen
        #expect(!ArchiveService.nativeZipFallbackSupported(for: options))
    }

    @Test
    func nativeZipFallbackBlockedBySFXAndRawParameters() {
        var options = ArchiveCreationOptions()
        options.createSFXArchive = true
        #expect(!ArchiveService.nativeZipFallbackSupported(for: options))

        options = ArchiveCreationOptions()
        options.rawParameters = "-mx9"
        #expect(!ArchiveService.nativeZipFallbackSupported(for: options))
    }

    @Test
    func nativeZipFallbackBlockedByVolumeSizeAndFullPathMode() {
        var options = ArchiveCreationOptions()
        options.sevenZipVolumeSize = "256m"
        #expect(!ArchiveService.nativeZipFallbackSupported(for: options))

        options = ArchiveCreationOptions()
        options.sevenZipPathMode = .full
        #expect(!ArchiveService.nativeZipFallbackSupported(for: options))
    }

    @Test
    func nativeZipFallbackBlockedByAESButAllowsZipCrypto() {
        // 原生 zip 命令不支持 AES，遇到 AES 需要切回 7zz；
        // ZipCrypto 是 zip 命令原生支持的传统加密。
        var options = ArchiveCreationOptions()
        options.password = "secret"
        options.encryptionMethod = .aes256
        #expect(!ArchiveService.nativeZipFallbackSupported(for: options))

        options.encryptionMethod = .zipCrypto
        #expect(ArchiveService.nativeZipFallbackSupported(for: options))
    }

    // MARK: - 7-Zip create 参数的少见分支

    @Test
    func sevenZipCreateArgumentsRespectFullPathMode() throws {
        var options = ArchiveCreationOptions()
        options.format = .sevenZip
        options.sevenZipPathMode = .full

        let arguments = try ArchiveService.sevenZipCreateArguments(
            destination: URL(fileURLWithPath: "/tmp/a.7z"),
            relativeNames: ["x"],
            options: options
        )

        #expect(arguments.contains("-spf"))
    }

    @Test
    func sevenZipCreateArgumentsIncludeSolidBlockSize() throws {
        var options = ArchiveCreationOptions()
        options.format = .sevenZip
        options.sevenZipSolidArchive = true
        // 任意非 automatic 的 block size 应该被透传成 -ms=<value>。
        options.sevenZipSolidBlockSize = .size4g

        let arguments = try ArchiveService.sevenZipCreateArguments(
            destination: URL(fileURLWithPath: "/tmp/a.7z"),
            relativeNames: ["x"],
            options: options
        )

        let solidArguments = arguments.filter { $0.hasPrefix("-ms=") }
        #expect(solidArguments.count == 1)
        // 不强求具体单位字符串，只要不是 on/off —— solid block size 枚举改动时只需调整这条断言。
        let solidArgument = solidArguments.first ?? ""
        #expect(solidArgument != "-ms=on")
        #expect(solidArgument != "-ms=off")
    }

    @Test
    func sevenZipCreateArgumentsIncludeStorageAndSourceFlags() throws {
        var options = ArchiveCreationOptions()
        options.format = .sevenZip
        options.sevenZipStoreSymbolicLinks = true
        options.sevenZipStoreHardLinks = true
        options.sevenZipCompressSharedFiles = true
        options.sevenZipDeleteSourceFiles = true
        options.createSFXArchive = true

        let arguments = try ArchiveService.sevenZipCreateArguments(
            destination: URL(fileURLWithPath: "/tmp/a.7z"),
            relativeNames: ["x"],
            options: options
        )

        #expect(arguments.contains("-snl"))
        #expect(arguments.contains("-snh"))
        #expect(arguments.contains("-ssw"))
        #expect(arguments.contains("-sdel"))
        #expect(arguments.contains("-sfx"))
    }

    @Test
    func sevenZipCreateArgumentsEncryptHeadersFlagDependsOnPassword() throws {
        var options = ArchiveCreationOptions()
        options.format = .sevenZip
        options.password = "x"
        options.sevenZipEncryptFileNames = true

        let arguments = try ArchiveService.sevenZipCreateArguments(
            destination: URL(fileURLWithPath: "/tmp/a.7z"),
            relativeNames: ["x"],
            options: options
        )

        #expect(arguments.contains("-mhe=on"))
        #expect(!arguments.contains("-mhe=off"))
    }

    // MARK: - RAR create 少见分支

    @Test
    func rarCreateArgumentsRespectFullPathMode() throws {
        var options = ArchiveCreationOptions()
        options.format = .rar
        options.sevenZipPathMode = .full

        let arguments = try ArchiveService.rarCreateArguments(
            destination: URL(fileURLWithPath: "/tmp/a.rar"),
            relativeNames: ["x"],
            options: options
        )

        // full 模式下不应该加 -ep1（exclude path）。
        #expect(!arguments.contains("-ep1"))
    }

    @Test
    func rarCreateArgumentsUseStoreCompressionWhenLevelIsStore() throws {
        var options = ArchiveCreationOptions()
        options.format = .rar
        options.compressionLevel = .store

        let arguments = try ArchiveService.rarCreateArguments(
            destination: URL(fileURLWithPath: "/tmp/a.rar"),
            relativeNames: ["x"],
            options: options
        )

        #expect(arguments.contains("-m0"))
    }

    @Test
    func rarCreateArgumentsToggleHashPasswordVsPlainPassword() throws {
        var options = ArchiveCreationOptions()
        options.format = .rar
        options.password = "x"
        options.sevenZipEncryptFileNames = false

        let plainPasswordArguments = try ArchiveService.rarCreateArguments(
            destination: URL(fileURLWithPath: "/tmp/a.rar"),
            relativeNames: ["x"],
            options: options
        )
        // 不加密文件名时用 -p，加密文件名时用 -hp。
        #expect(plainPasswordArguments.contains("-p"))
        #expect(!plainPasswordArguments.contains("-hp"))

        options.sevenZipEncryptFileNames = true
        let hashPasswordArguments = try ArchiveService.rarCreateArguments(
            destination: URL(fileURLWithPath: "/tmp/a.rar"),
            relativeNames: ["x"],
            options: options
        )
        #expect(hashPasswordArguments.contains("-hp"))
        #expect(!hashPasswordArguments.contains("-p"))
    }

    // MARK: - 命令行拆分边角

    @Test
    func splitCommandLineArgumentsReturnsEmptyForBlankInput() {
        #expect(ArchiveService.splitCommandLineArguments(from: "").isEmpty)
        #expect(ArchiveService.splitCommandLineArguments(from: "   \n\t ").isEmpty)
    }

    @Test
    func splitCommandLineArgumentsAppendsTrailingBackslashWhenUnclosed() {
        // 末尾是孤立的反斜杠 —— 用户少敲了一个字符。
        // 当前实现保留它而不是吞掉，避免静默丢失。
        let arguments = ArchiveService.splitCommandLineArguments(from: "\"x\\")
        #expect(arguments == ["x\\"])
    }

    @Test
    func normalizedSevenZipVolumeSizeAcceptsDigitsOnly() throws {
        // 没有单位的纯数字也是合法的（7-Zip 默认按字节）。
        #expect(try ArchiveService.normalizedSevenZipVolumeSize(from: "1024") == "1024")
    }

    @Test
    func normalizedSevenZipVolumeSizeLowercasesUnit() throws {
        #expect(try ArchiveService.normalizedSevenZipVolumeSize(from: "2G") == "2g")
        #expect(try ArchiveService.normalizedSevenZipVolumeSize(from: "100B") == "100b")
    }
}

//
//  BundleReleaseCheck.swift
//  SimpleZip
//
//  队列 #6:App bundle / DMG / XIP 专项发布检查。
//  只读检查,不签名不公证:Info.plist / BundleID / 版本 / 主可执行 / codesign --verify /
//  spctl(Gatekeeper)/ DMG 顶层结构与 Applications 链接 / XIP 签名摘要。
//  纯解析与结构分析放成 nonisolated 静态函数(SwiftPM 可测);外部工具调用走
//  BackendProcessRunner(与 7zz 同一套取消 / 日志管道)。
//

import Foundation

enum BundleReleaseCheck {

    /// 专项检查目标。从 URL 探测:.app 目录 / .dmg 文件 / .xip 文件,其余 nil(走普通归档检查)。
    enum Target {
        case appBundle
        case diskImage
        case xipArchive

        nonisolated static func detect(at url: URL) -> Target? {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
            switch url.pathExtension.lowercased() {
            case "app" where isDirectory.boolValue:
                return .appBundle
            case "dmg" where !isDirectory.boolValue:
                return .diskImage
            case "xip" where !isDirectory.boolValue:
                return .xipArchive
            default:
                return nil
            }
        }
    }

    /// 一行检查结论。标题存 L10n key(+ 至多一个参数),detail 是工具原始输出行(不本地化),
    /// 由报告视图统一渲染 —— Core 不直接产出本地化文案,SwiftPM 测试断言 key 不受语言影响。
    struct Finding: Identifiable, Hashable, Codable {
        enum Severity: String, Hashable, Codable {
            case pass
            case info
            case warning
            case failure
        }

        let id = UUID()
        let severity: Severity
        let titleKey: String
        var titleArgument: String?
        var detail: String?

        /// Codable 排除 `id`(带初值的 let 不能解码)—— 0.4.4 报告随任务历史持久化用。
        private enum CodingKeys: String, CodingKey {
            case severity, titleKey, titleArgument, detail
        }

        nonisolated init(_ severity: Severity, _ titleKey: String, argument: String? = nil, detail: String? = nil) {
            self.severity = severity
            self.titleKey = titleKey
            self.titleArgument = argument
            self.detail = detail
        }
    }

    // MARK: - .app bundle

    /// .app 检查全套:Info.plist 系列(纯文件系统)+ codesign + Gatekeeper。
    static func inspectAppBundle(at url: URL, operationID: UUID? = nil, outputObserver: (@Sendable (String) -> Void)? = nil) async -> [Finding] {
        var findings = infoPlistFindings(at: url)
        findings.append(await codesignFinding(for: url, outputObserver: outputObserver, operationID: operationID))
        findings.append(await gatekeeperFinding(for: url, assessType: "execute", outputObserver: outputObserver, operationID: operationID))
        return findings
    }

    /// Info.plist / BundleID / 版本 / 主可执行 —— 纯文件系统,SwiftPM 可测。
    nonisolated static func infoPlistFindings(at bundleURL: URL) -> [Finding] {
        var findings: [Finding] = []
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            findings.append(Finding(.failure, "inspect.bundle.infoPlist.missing"))
            return findings
        }
        findings.append(Finding(.pass, "inspect.bundle.infoPlist.ok"))

        if let identifier = plist["CFBundleIdentifier"] as? String, !identifier.isEmpty {
            findings.append(Finding(.pass, "inspect.bundle.identifier", argument: identifier))
        } else {
            findings.append(Finding(.failure, "inspect.bundle.identifier.missing"))
        }

        let shortVersion = plist["CFBundleShortVersionString"] as? String
        let buildVersion = plist["CFBundleVersion"] as? String
        if let shortVersion, let buildVersion {
            findings.append(Finding(.pass, "inspect.bundle.version", argument: "\(shortVersion) (\(buildVersion))"))
        } else {
            findings.append(Finding(.warning, "inspect.bundle.version.missing"))
        }

        if let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty {
            let executableURL = bundleURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: executableURL.path) {
                findings.append(Finding(.pass, "inspect.bundle.executable.ok", argument: executable))
            } else {
                findings.append(Finding(.failure, "inspect.bundle.executable.missing", argument: executable))
            }
        } else {
            findings.append(Finding(.failure, "inspect.bundle.executable.unspecified"))
        }
        return findings
    }

    // MARK: - DMG

    /// DMG 检查全套:顶层结构(用已列出的条目,纯分析)+ DMG 文件本身的 codesign + Gatekeeper(open)。
    static func inspectDiskImage(at url: URL, listedItems: [ArchiveItem]?, operationID: UUID? = nil, outputObserver: (@Sendable (String) -> Void)? = nil) async -> [Finding] {
        var findings: [Finding] = []
        if let listedItems {
            findings += diskImageLayoutFindings(items: listedItems)
        }
        findings.append(await codesignFinding(for: url, unsignedSeverity: .info, outputObserver: outputObserver, operationID: operationID))
        findings.append(await gatekeeperFinding(for: url, assessType: "open", context: "context:primary-signature", outputObserver: outputObserver, operationID: operationID))
        return findings
    }

    /// DMG 顶层结构分析(纯函数,SwiftPM 可测):恰好一个 .app / Applications 链接 / 多余可见条目。
    /// 7zz 列 DMG 时第一段路径是卷名 —— 所有条目共享单一根目录时剥掉它再看顶层。
    nonisolated static func diskImageLayoutFindings(items: [ArchiveItem]) -> [Finding] {
        var findings: [Finding] = []
        let paths = items.map { $0.name.split(separator: "/").map(String.init) }.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return findings }

        let firstComponents = Set(paths.map { $0[0] })
        let stripVolumeRoot = firstComponents.count == 1 && paths.contains { $0.count > 1 }
        let topLevelIndex = stripVolumeRoot ? 1 : 0

        var topLevel: [String: Bool] = [:] // 名称 → 是否目录(取任一条目;.app 是目录)
        for (item, components) in zip(items, paths) where components.count > topLevelIndex {
            let name = components[topLevelIndex]
            let isContainerOrDirectory = item.isDirectory || components.count > topLevelIndex + 1
            topLevel[name] = (topLevel[name] ?? false) || isContainerOrDirectory
        }

        let apps = topLevel.keys.filter { $0.lowercased().hasSuffix(".app") }.sorted()
        switch apps.count {
        case 1:
            findings.append(Finding(.pass, "inspect.bundle.dmg.singleApp", argument: apps[0]))
        case 0:
            findings.append(Finding(.warning, "inspect.bundle.dmg.noApp"))
        default:
            findings.append(Finding(.warning, "inspect.bundle.dmg.multipleApps", argument: "\(apps.count)", detail: apps.joined(separator: ", ")))
        }

        if topLevel.keys.contains("Applications") {
            findings.append(Finding(.pass, "inspect.bundle.dmg.applicationsLink"))
        } else {
            findings.append(Finding(.warning, "inspect.bundle.dmg.applicationsLink.missing"))
        }

        let expected: Set<String> = Set(apps + ["Applications"])
        let extras = topLevel.keys
            .filter { !expected.contains($0) && !$0.hasPrefix(".") && $0 != "Applications" }
            .sorted()
        if !extras.isEmpty {
            let shown = extras.prefix(5).joined(separator: ", ") + (extras.count > 5 ? "…" : "")
            findings.append(Finding(.info, "inspect.bundle.dmg.extraItems", argument: "\(extras.count)", detail: shown))
        }
        return findings
    }

    // MARK: - XIP

    /// XIP 检查:pkgutil --check-signature 的信任摘要。系统 `xip` 默认只解 Apple 签名的 XIP ——
    /// 非 Apple 签名一律 warning 提示收件人可能打不开。
    static func inspectXIP(at url: URL, operationID: UUID? = nil, outputObserver: (@Sendable (String) -> Void)? = nil) async -> [Finding] {
        do {
            let output = try await BackendProcessRunner.runAndCapture(
                "/usr/sbin/pkgutil",
                arguments: ["--check-signature", url.path],
                outputObserver: outputObserver,
                operationID: operationID
            )
            return [xipSignatureFinding(fromCheckSignatureOutput: output)]
        } catch let ArchiveError.commandFailed(output) {
            return [Finding(.warning, "inspect.bundle.xip.unsigned", detail: tail(of: output))]
        } catch {
            return [Finding(.warning, "inspect.bundle.xip.unsigned", detail: error.localizedDescription)]
        }
    }

    /// 解析 pkgutil --check-signature 输出(纯函数,SwiftPM 可测)。
    nonisolated static func xipSignatureFinding(fromCheckSignatureOutput output: String) -> Finding {
        let statusLine = output
            .components(separatedBy: .newlines)
            .first { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("status:") }?
            .trimmingCharacters(in: .whitespaces)
        let lowered = (statusLine ?? "").lowercased()
        if lowered.contains("signed apple software") {
            return Finding(.pass, "inspect.bundle.xip.apple", detail: statusLine)
        }
        if lowered.contains("signed") {
            return Finding(.warning, "inspect.bundle.xip.thirdParty", detail: statusLine)
        }
        return Finding(.warning, "inspect.bundle.xip.unsigned", detail: statusLine ?? tail(of: output))
    }

    // MARK: - codesign / Gatekeeper(共用)

    /// codesign --verify --deep --strict;签名有效时再取 Authority 行当 detail。
    /// `unsignedSeverity`:.app 未签名是 failure 级问题(发不出去),DMG 未签名只是 info(常见)。
    private static func codesignFinding(for url: URL, unsignedSeverity: Finding.Severity = .warning, outputObserver: (@Sendable (String) -> Void)?, operationID: UUID?) async -> Finding {
        do {
            _ = try await BackendProcessRunner.runAndCapture(
                "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", "--verbose=2", url.path],
                outputObserver: outputObserver,
                operationID: operationID
            )
            let authority = await signingAuthority(for: url, outputObserver: outputObserver, operationID: operationID)
            return Finding(.pass, "inspect.bundle.codesign.ok", detail: authority)
        } catch let ArchiveError.commandFailed(output) {
            if output.lowercased().contains("not signed at all") {
                return Finding(unsignedSeverity, "inspect.bundle.codesign.unsigned")
            }
            return Finding(.failure, "inspect.bundle.codesign.invalid", detail: tail(of: output))
        } catch {
            return Finding(.failure, "inspect.bundle.codesign.invalid", detail: error.localizedDescription)
        }
    }

    /// `codesign -dv` 的 Authority= 首行(签名身份,例如 "Developer ID Application: …")。
    private static func signingAuthority(for url: URL, outputObserver: (@Sendable (String) -> Void)?, operationID: UUID?) async -> String? {
        guard let output = try? await BackendProcessRunner.runAndCapture(
            "/usr/bin/codesign",
            arguments: ["-dv", "--verbose=2", url.path],
            outputObserver: outputObserver,
            operationID: operationID
        ) else { return nil }
        return output
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix("Authority=") }
            .map { String($0.dropFirst("Authority=".count)) }
    }

    /// spctl --assess(Gatekeeper 视角):accepted = 收件人双击能直接开(含公证判定);
    /// rejected 对未签名 / 未公证的开发构建是常态 → warning 而非 failure。
    private static func gatekeeperFinding(for url: URL, assessType: String, context: String? = nil, outputObserver: (@Sendable (String) -> Void)?, operationID: UUID?) async -> Finding {
        var arguments = ["--assess", "--type", assessType, "--verbose=2"]
        if let context {
            arguments += ["--context", context]
        }
        arguments.append(url.path)
        do {
            let output = try await BackendProcessRunner.runAndCapture(
                "/usr/sbin/spctl",
                arguments: arguments,
                outputObserver: outputObserver,
                operationID: operationID
            )
            return Finding(.pass, "inspect.bundle.gatekeeper.accepted", detail: sourceLine(in: output))
        } catch let ArchiveError.commandFailed(output) {
            return Finding(.warning, "inspect.bundle.gatekeeper.rejected", detail: sourceLine(in: output) ?? tail(of: output))
        } catch {
            return Finding(.warning, "inspect.bundle.gatekeeper.rejected", detail: error.localizedDescription)
        }
    }

    private nonisolated static func sourceLine(in output: String) -> String? {
        output
            .components(separatedBy: .newlines)
            .first { $0.contains("source=") }?
            .trimmingCharacters(in: .whitespaces)
    }

    private nonisolated static func tail(of output: String, limit: Int = 200) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= limit ? trimmed : "…" + trimmed.suffix(limit)
    }
}

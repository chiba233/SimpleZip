//
//  ArchiveBrowserModel+SafetyPassword.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//
//  解压前的安全检查（路径穿越 / 符号链接 / 可执行外开确认）+ 加密档案的密码弹窗 retry 循环。
//

import AppKit
import Foundation

extension ArchiveBrowserModel {
    private func confirmOpeningPotentiallyUnsafeArchiveItem(_ item: ArchiveItem) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("confirm.openUnsafeArchiveItem.title", item.displayName)
        alert.informativeText = L10n.text("confirm.openUnsafeArchiveItem.message")
        alert.addButton(withTitle: L10n.text("button.open"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func allowPotentiallyUnsafeArchiveItemOpen(_ item: ArchiveItem) -> Bool {
        switch AppPreferences.activeContentOpenPolicy {
        case .allow:
            return true
        case .deny:
            errorMessage = L10n.text("error.blockedBySecurityPolicy")
            status = L10n.text("status.failed")
            return false
        case .ask:
            return confirmOpeningPotentiallyUnsafeArchiveItem(item)
        }
    }

    /// 安全检查：列出条目（可能需要密码）+ 用 ArchiveSafety 判定。
    ///
    /// 接收 password 是为了让 header-encrypted 7z 这类「不给密码连 list 都失败」的档案
    /// 能用调用方手上已有的密码（用户输入 / 预设密码 / 上次成功的密码）跑 list。
    /// 调用方负责把这个函数放在密码 retry 循环内 —— 列表失败时会抛出可被
    /// `shouldPromptForArchivePassword` 识别的错误，由 retry 循环统一处理。
    /// 返回 list 出的条目 —— 调用方（performExtractArchive）拿它算出文件数传给 `ArchiveService.extract`
    /// 的 `knownFileCount`，避免解压时为算总数再 list 一遍（双 list → 解压前像卡死）。
    /// `operationID` 透传给 list，让这步「7zz l -slt」也能被取消（之前 list 固定 nil，卡在这阶段点取消杀不掉）。
    @discardableResult
    func confirmArchiveExtractionSafety(
        archiveURL: URL,
        password: String = "",
        operationID: UUID? = nil,
        force: Bool? = nil
    ) async throws -> [ArchiveItem] {
        let force = force ?? isForced(archiveURL)
        let items = try await ArchiveService.list(archiveURL, password: password, operationID: operationID, force: force)
        try confirmArchiveExtractionSafety(entries: items)
        return items
    }

    func confirmArchiveExtractionSafety(entries: [ArchiveItem]) throws {
        let unsafeNames = ArchiveSafety.unsafeEntryNames(in: entries)
        guard !unsafeNames.isEmpty else { return }

        switch AppPreferences.suspiciousPathPolicy {
        case .allow:
            return
        case .deny:
            throw ArchiveError.blockedBySecurityPolicy
        case .ask:
            break
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("confirm.unsafeArchiveEntries.title")
        alert.informativeText = L10n.format("confirm.unsafeArchiveEntries.message", Array(unsafeNames.prefix(5)).joined(separator: ", "))
        alert.addButton(withTitle: L10n.text("button.continue"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        if alert.runModal() != .alertFirstButtonReturn {
            throw CocoaError(.userCancelled)
        }
    }

    func confirmExtractedArchiveLinks(at directory: URL) throws {
        let unsafeLinks = try ArchiveSafety.unsafeLinks(in: directory, fileManager: fileManager)
        guard !unsafeLinks.isEmpty else { return }

        switch AppPreferences.symbolicLinkPolicy {
        case .allow:
            return
        case .deny:
            throw ArchiveError.blockedBySecurityPolicy
        case .ask:
            break
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("confirm.unsafeArchiveLinks.title")
        alert.informativeText = L10n.format("confirm.unsafeArchiveLinks.message", Array(unsafeLinks.prefix(5)).joined(separator: ", "))
        alert.addButton(withTitle: L10n.text("button.continue"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        if alert.runModal() != .alertFirstButtonReturn {
            throw CocoaError(.userCancelled)
        }
    }

    func shouldPromptForArchivePassword(_ error: Error) -> Bool {
        if let archiveError = error as? ArchiveError {
            switch archiveError {
            case .passwordPromptExhausted:
                return true
            case .commandFailed(let output):
                return archiveCommandSuggestsPasswordRequirement(output)
            default:
                return false
            }
        }
        return archiveCommandSuggestsPasswordRequirement(error.localizedDescription)
    }

    private func archiveCommandSuggestsPasswordRequirement(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("enter password")
            || normalized.contains("wrong password")
            || normalized.contains("can not open encrypted archive")
            || normalized.contains("cannot open encrypted archive")
    }

    func promptForArchiveItemPassword(
        item: ArchiveItem,
        archiveURL: URL,
        detectedZipEncryption: ZipEncryptionDetection,
        isRetry: Bool
    ) -> (password: String, zipDecryptionMethod: ArchiveDecryptionMethod)? {
        promptForArchivePassword(
            archiveURL: archiveURL,
            displayName: item.displayName,
            detectedZipEncryption: detectedZipEncryption,
            isRetry: isRetry,
            actionTitle: L10n.text("button.open")
        )
    }

    func promptForArchivePassword(
        archiveURL: URL,
        displayName: String,
        detectedZipEncryption: ZipEncryptionDetection,
        isRetry: Bool,
        actionTitle: String
    ) -> (password: String, zipDecryptionMethod: ArchiveDecryptionMethod)? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = archiveURL.lastPathComponent
        alert.informativeText = isRetry ? L10n.text("error.passwordPromptExhausted") : displayName
        // 0.4.2 #9：归档级注释常被用作密码提示 —— 有注释时附在弹窗里（截断防超长）。
        let hintComment = ArchiveService.headerComment(for: archiveURL)
        if !hintComment.isEmpty {
            alert.informativeText += "\n\n" + L10n.format("password.hintComment", String(hintComment.prefix(200)))
        }
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: L10n.text("button.cancel"))

        let accessoryWidth: CGFloat = 320
        let accessoryHeight: CGFloat = archiveURL.pathExtension.lowercased() == "zip" ? 112 : 24
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: accessoryHeight))

        let passwordFieldY: CGFloat = archiveURL.pathExtension.lowercased() == "zip" ? 88 : 0
        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: passwordFieldY, width: accessoryWidth, height: 24))
        passwordField.placeholderString = L10n.text("extract.password.placeholder")
        accessoryView.addSubview(passwordField)

        let decryptionMethods = Array(ArchiveDecryptionMethod.allCases)
        var methodPicker: NSPopUpButton?
        if archiveURL.pathExtension.lowercased() == "zip" {
            if detectedZipEncryption != .unknown {
                let detectionLabel = NSTextField(labelWithString: detectedZipEncryption.autoDetectionText)
                detectionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                detectionLabel.textColor = .secondaryLabelColor
                detectionLabel.frame = NSRect(x: 0, y: 56, width: accessoryWidth, height: 16)
                accessoryView.addSubview(detectionLabel)
            }

            let methodLabel = NSTextField(labelWithString: L10n.text("extract.decryptionMethod"))
            methodLabel.frame = NSRect(x: 0, y: 32, width: accessoryWidth, height: 16)
            accessoryView.addSubview(methodLabel)

            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: 26), pullsDown: false)
            decryptionMethods.forEach { picker.addItem(withTitle: $0.title) }
            picker.selectItem(at: 0)
            accessoryView.addSubview(picker)
            methodPicker = picker
        }

        alert.accessoryView = accessoryView

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let password = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 注意：点了 Extract 但密码框留空 ≠ 取消。
        // 比如用户给一个其实没加密的档案先填了密码 → 后续重试弹框 → 用户清掉再点 Extract，
        // 这是「我想不带密码再试一次」的明确表态，把空字符串照原样返回让外层 retry 一次。
        // 旧代码这里 guard !password.isEmpty else { return nil }，会被外层当 CancellationError 抛出 ——
        // 没加密的档案就被"静默"标成取消，文件根本没解出来。
        let selectedMethod: ArchiveDecryptionMethod
        if let methodPicker {
            let index = methodPicker.indexOfSelectedItem
            selectedMethod = decryptionMethods.indices.contains(index) ? decryptionMethods[index] : .automatic
        } else {
            selectedMethod = .automatic
        }
        return (password, selectedMethod)
    }
}

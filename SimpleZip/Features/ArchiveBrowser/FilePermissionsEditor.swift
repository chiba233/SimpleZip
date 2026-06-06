//
//  FilePermissionsEditor.swift
//  SimpleZip
//
//  Task4 文件浏览右键「权限与属主…」：改 Unix 权限位（chmod）+ 改属主（chown）。
//  - chmod：当前用户拥有的文件直接 `FileManager.setAttributes` 免提权；失败的（不属于本用户）退回提权。
//  - chown：macOS 一律需要 root，走 `NSAppleScript ... with administrator privileges`（系统密码弹窗，单次授权做完所有路径）。
//  本 app 非沙盒（ENABLE_APP_SANDBOX = NO），所以 AppleScript 提权可用。security-sensitive：
//  路径全部 shell 单引号转义，再做 AppleScript 字面量转义，避免命令注入。
//

import AppKit
import Foundation
import SwiftUI

/// sheet(item:) 载荷：要改权限 / 属主的一组文件。
struct FilePermissionsEditRequest: Identifiable {
    let id = UUID()
    /// 选中的全部文件（权限 / 属主会套用到每一个）。
    let urls: [URL]
    /// sheet 标题用的名字（单选 = 文件名；多选 = 「N 个项目」）。
    let title: String
    /// 预填的权限位（取自第一个选中项；多选不一致时见 `mixedSelection`）。
    let initialMode: UInt16
    /// 预填的属主用户名（取自第一个选中项）。
    let initialOwner: String
    /// 第一项是否目录（仅用于符号化预览的首字符）。
    let isDirectory: Bool
    /// 多选且各项权限不一致 —— 提示用户「应用会统一」。
    let mixedSelection: Bool
}

/// chmod / chown 的实际执行。无 UI、无状态。
enum FilePermissionService {
    enum Failure: LocalizedError {
        case scriptUnavailable
        case cancelled
        case authFailed(String)

        var errorDescription: String? {
            switch self {
            case .scriptUnavailable:
                return L10n.text("file.getInfo.appleScriptUnavailable")
            case .cancelled:
                return nil
            case .authFailed(let message):
                return message
            }
        }
    }

    /// 读当前权限位（`st_mode & 07777`，lstat 语义不跟随符号链接）。取不到 → nil。
    static func currentMode(of url: URL) -> UInt16? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { $0[.posixPermissions] as? NSNumber }?
            .uint16Value
    }

    /// 读当前属主用户名。取不到 → 空。
    static func currentOwner(of url: URL) -> String {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.ownerAccountName] as? String) ?? ""
    }

    /// 直接 chmod（本用户拥有的文件免提权）。返回**失败**、需要提权重试的 URL 列表。
    @discardableResult
    static func directChmod(_ mode: UInt16, to urls: [URL]) -> [URL] {
        var failed: [URL] = []
        for url in urls {
            do {
                try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
            } catch {
                failed.append(url)
            }
        }
        return failed
    }

    /// 提权执行 chmod / chown —— 一次系统授权弹窗做完所有路径。两者都可为 nil（什么都不做）。
    static func privileged(chmod: (mode: UInt16, urls: [URL])?, chown: (owner: String, urls: [URL])?) throws {
        var commands: [String] = []
        if let chmod, !chmod.urls.isEmpty {
            let paths = chmod.urls.map { shellQuote($0.path) }.joined(separator: " ")
            commands.append("/bin/chmod \(String(format: "%o", chmod.mode)) \(paths)")
        }
        if let chown, !chown.owner.isEmpty, !chown.urls.isEmpty {
            let paths = chown.urls.map { shellQuote($0.path) }.joined(separator: " ")
            // -h：作用在符号链接本身而非其指向，避免误改链接目标的属主。
            commands.append("/usr/sbin/chown -h \(shellQuote(chown.owner)) \(paths)")
        }
        guard !commands.isEmpty else { return }
        try runPrivileged(commands.joined(separator: " && "))
    }

    private static func runPrivileged(_ shellCommand: String) throws {
        let source = "do shell script \"\(appleScriptLiteral(shellCommand))\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { throw Failure.scriptUnavailable }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            // -128 = 用户在密码弹窗点了取消 → 静默（不弹错误）。
            if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 { throw Failure.cancelled }
            let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? (errorInfo[NSAppleScript.errorBriefMessage] as? String)
                ?? String(describing: errorInfo)
            throw Failure.authFailed(message)
        }
    }

    /// shell 单引号转义：包一层单引号,内部单引号用 `'\''`。
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript 字符串字面量转义（先反斜杠再双引号）。
    private static func appleScriptLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// 权限 / 属主编辑 sheet —— 3×3 读 / 写 / 执行复选框 + 属主输入框。沿用现有 sheet 的「标题 + 表单 + 取消/应用」idiom。
struct FilePermissionsEditorSheet: View {
    let request: FilePermissionsEditRequest
    /// (mode?, owner?, urls) —— mode 为 nil 表示权限未变;owner 为 nil 表示属主未变。
    let apply: (UInt16?, String?, [URL]) -> Void
    let cancel: () -> Void

    @State private var bits: [Bool]
    @State private var owner: String

    /// 9 位顺序：属主 r/w/x、组 r/w/x、其他 r/w/x。
    private static let bitMasks = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]

    init(request: FilePermissionsEditRequest, apply: @escaping (UInt16?, String?, [URL]) -> Void, cancel: @escaping () -> Void) {
        self.request = request
        self.apply = apply
        self.cancel = cancel
        _bits = State(initialValue: Self.bitMasks.map { (Int(request.initialMode) & $0) != 0 })
        _owner = State(initialValue: request.initialOwner)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.format("file.permissions.title", request.title))
                .font(.headline)

            if request.mixedSelection {
                Text(L10n.text("file.permissions.mixedNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .center, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text(L10n.text("file.permissions.read")).font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("file.permissions.write")).font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("file.permissions.execute")).font(.caption).foregroundStyle(.secondary)
                }
                permissionRow(L10n.text("file.permissions.class.owner"), base: 0)
                permissionRow(L10n.text("file.permissions.class.group"), base: 3)
                permissionRow(L10n.text("file.permissions.class.everyone"), base: 6)
            }

            Text(symbolicPreview)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(L10n.text("file.permissions.ownerLabel"))
                    TextField("", text: $owner)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
                Text(L10n.text("file.permissions.ownerHint"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L10n.text("button.cancel"), role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("button.apply")) { applyChanges() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func permissionRow(_ label: String, base: Int) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.leading)
            ForEach(0..<3, id: \.self) { offset in
                Toggle("", isOn: $bits[base + offset]).labelsHidden()
            }
        }
    }

    /// 把当前勾选 + 保留的特殊位（setuid/setgid/sticky，不在 UI 暴露但不丢）拼回权限位。
    private var composedMode: UInt16 {
        var mode = Int(request.initialMode) & 0o7000
        for (index, on) in bits.enumerated() where on { mode |= Self.bitMasks[index] }
        return UInt16(mode)
    }

    private var symbolicPreview: String {
        FileBrowserService.posixModeString(mode: composedMode, isDirectory: request.isDirectory, isSymbolicLink: false)
            + "  (" + String(format: "%03o", Int(composedMode) & 0o777) + ")"
    }

    private func applyChanges() {
        let newMode = composedMode
        let modeArg: UInt16? = newMode != request.initialMode ? newMode : nil
        let trimmedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerArg: String? = (!trimmedOwner.isEmpty && trimmedOwner != request.initialOwner) ? trimmedOwner : nil
        apply(modeArg, ownerArg, request.urls)
    }
}

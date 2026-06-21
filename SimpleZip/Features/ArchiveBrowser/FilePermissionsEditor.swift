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
    /// 选区里是否含文件夹 —— 含则显示「应用到文件夹内所有项目」勾选（递归 chmod -R / chown -R）。
    let containsDirectory: Bool
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

    /// 单个文件的失败记录（活动中心红色行展示）。
    struct FileFailure: Sendable {
        let url: URL
        let reason: String
    }

    /// 一次 apply 的逐文件结果 —— 喂给活动中心 transferLog。
    struct ApplyOutcome: Sendable {
        var changed: [URL]
        var failures: [FileFailure]
    }

    /// 统一入口（活动中心任务里调用）：先对自有文件免提权直改 chmod,失败的 + 改属主合并成一次系统授权批处理。
    /// 返回逐文件结果;用户取消授权弹窗时抛 `Failure.cancelled`（调用方映射成 CancellationError）。
    /// `mode` 为 nil = 不改权限;`owner` 为空 = 不改属主。`nonisolated`：在后台 `Task.detached` 执行,避开 main actor。
    nonisolated static func apply(mode: UInt16?, owner: String?, to urls: [URL], recursive: Bool = false) throws -> ApplyOutcome {
        let wantsChown = (owner?.isEmpty == false)

        // 1. 自有文件直接 chmod（无弹窗）。递归走 `/bin/chmod -R` 子进程,非递归逐个 setAttributes（拿到逐项失败）。
        var chmodFailed: [URL] = []
        if let mode {
            if recursive {
                if !runChmod(mode, recursive: true, paths: urls) { chmodFailed = urls }
            } else {
                chmodFailed = directChmod(mode, to: urls)
            }
        }
        let needsPrivilegedChmod = (mode != nil && !chmodFailed.isEmpty)

        // 2. 需要提权（改属主,或有 chmod 因权限不足失败）→ 一次系统授权批处理（递归则带 -R）。
        if needsPrivilegedChmod || wantsChown {
            do {
                try privileged(
                    chmod: needsPrivilegedChmod ? (mode!, recursive ? urls : chmodFailed) : nil,
                    chown: wantsChown ? (owner!, urls) : nil,
                    recursive: recursive
                )
                return ApplyOutcome(changed: urls, failures: [])   // 提权成功 → 所有项视为已更改
            } catch Failure.cancelled {
                throw Failure.cancelled                            // 透传:调用方静默成「已取消」
            } catch {
                let reason = error.localizedDescription
                return ApplyOutcome(changed: [], failures: urls.map { FileFailure(url: $0, reason: reason) })
            }
        }

        // 3. 只做了直接 chmod：成功 = 没失败的那些;失败 = chmodFailed。
        let failedSet = Set(chmodFailed)
        return ApplyOutcome(
            changed: urls.filter { !failedSet.contains($0) },
            failures: chmodFailed.map { FileFailure(url: $0, reason: L10n.text("file.permissions.chmodFailed")) }
        )
    }

    /// 非提权 `/bin/chmod`（可选 `-R`）—— 自有文件免弹窗。返回是否全部成功（退出码 0）。
    nonisolated private static func runChmod(_ mode: UInt16, recursive: Bool, paths: [URL]) -> Bool {
        guard !paths.isEmpty else { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        // 安全:`--` 终止选项,路径(虽是绝对路径、本就以 / 开头)不被当 flag —— 纵深防御。
        process.arguments = (recursive ? ["-R"] : []) + ["--", String(format: "%o", mode)] + paths.map(\.path)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0
    }

    /// 直接 chmod（本用户拥有的文件免提权）。返回**失败**、需要提权重试的 URL 列表。
    /// `nonisolated`：在活动中心的后台 `Task.detached` 里执行,不能要求 main actor。
    @discardableResult
    nonisolated static func directChmod(_ mode: UInt16, to urls: [URL]) -> [URL] {
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
    /// `recursive` = 加 `-R` 递归到文件夹内所有项目。`nonisolated`：后台执行。
    nonisolated static func privileged(chmod: (mode: UInt16, urls: [URL])?, chown: (owner: String, urls: [URL])?, recursive: Bool) throws {
        var commands: [String] = []
        if let chmod, !chmod.urls.isEmpty {
            let paths = chmod.urls.map { shellQuote($0.path) }.joined(separator: " ")
            let flag = recursive ? "-R " : ""
            // 安全:`--` 终止选项,路径不被当 flag(纵深防御;路径本就绝对)。
            commands.append("/bin/chmod \(flag)-- \(String(format: "%o", chmod.mode)) \(paths)")
        }
        if let chown, !chown.owner.isEmpty, !chown.urls.isEmpty {
            let paths = chown.urls.map { shellQuote($0.path) }.joined(separator: " ")
            // -h：作用在符号链接本身而非其指向,避免误改链接目标的属主;递归再加 -R。
            let flags = recursive ? "-R -h " : "-h "
            // 安全:owner 是 UI 输入,shellQuote 防 shell 注入、`--` 再防它被 chown 当成 option(如以 - 开头)。
            commands.append("/usr/sbin/chown \(flags)-- \(shellQuote(chown.owner)) \(paths)")
        }
        guard !commands.isEmpty else { return }
        try runPrivileged(commands.joined(separator: " && "))
    }

    nonisolated private static func runPrivileged(_ shellCommand: String) throws {
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
    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript 字符串字面量转义（先反斜杠再双引号）。
    nonisolated private static func appleScriptLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// 权限 / 属主编辑 sheet —— 3×3 读 / 写 / 执行复选框 + 属主输入框。沿用现有 sheet 的「标题 + 表单 + 取消/应用」idiom。
struct FilePermissionsEditorSheet: View {
    let request: FilePermissionsEditRequest
    /// (mode?, owner?, recursive, urls) —— mode 为 nil 表示权限未变;owner 为 nil 表示属主未变;recursive = 递归到文件夹内所有项目。
    let apply: (UInt16?, String?, Bool, [URL]) -> Void
    let cancel: () -> Void

    @State private var bits: [Bool]
    @State private var owner: String
    @State private var applyRecursively = false

    /// 9 位顺序：属主 r/w/x、组 r/w/x、其他 r/w/x。
    private static let bitMasks = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]

    init(request: FilePermissionsEditRequest, apply: @escaping (UInt16?, String?, Bool, [URL]) -> Void, cancel: @escaping () -> Void) {
        self.request = request
        self.apply = apply
        self.cancel = cancel
        _bits = State(initialValue: Self.bitMasks.map { (Int(request.initialMode) & $0) != 0 })
        _owner = State(initialValue: request.initialOwner)
    }

    var body: some View {
        // design system:统一走 TaskDialogShell 骨架。副标题实时显示符号化权限预览(-rw-r--r-- (644))。
        TaskDialogShell(
            heroSystemImage: "lock.shield.fill",
            heroColors: [.purple, .indigo],
            title: L10n.format("file.permissions.title", request.title),
            subtitle: symbolicPreview,
            width: 460,
            maxContentHeight: 560,
            confirmTitle: L10n.text("button.apply"),
            confirmSystemImage: "lock.shield",
            confirm: { applyChanges() },
            cancel: cancel
        ) {
                    DialogSection(L10n.text("file.permissions.section.mode")) {
                        if request.mixedSelection {
                            Text(L10n.text("file.permissions.mixedNote"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Grid(alignment: .center, horizontalSpacing: 18, verticalSpacing: 10) {
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
                    }

                    DialogSection(L10n.text("file.permissions.section.owner")) {
                        // 字段与标签同行钉右缘,说明横跨整行(版式规则)。
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .center, spacing: 12) {
                                DialogRowLabel(L10n.text("file.permissions.ownerLabel"), systemImage: "person.fill", tint: .cyan)
                                Spacer(minLength: 12)
                                TextField("", text: $owner)
                                    .textFieldStyle(.roundedBorder)
                                    .dialogFieldEmphasis()
                                    .frame(width: 200)
                            }
                            Text(L10n.text("file.permissions.ownerHint"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // 选区含文件夹时才出现：递归套用到文件夹内所有项目（chmod -R / chown -R）。
                        if request.containsDirectory {
                            DialogToggleRow(
                                title: L10n.text("file.permissions.recursive"),
                                subtitle: L10n.text("file.permissions.recursive.hint"),
                                systemImage: "arrow.down.forward.square.fill",
                                tint: .purple,
                                isOn: $applyRecursively
                            )
                        }
                    }
        }
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
        apply(modeArg, ownerArg, applyRecursively, request.urls)
    }
}

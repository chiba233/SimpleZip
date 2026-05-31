//
//  SimpleZipApp.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import SwiftUI

/// SimpleZip 应用入口：负责创建主窗口和注册菜单命令。
@main
struct SimpleZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 早于 SwiftUI `.commands {}` 段被求值之前，把用户在偏好里选的语言
        // 同步写到 `AppleLanguages`。
        // 没有这一步的话：用户改完语言重启 → SwiftUI App.body 的 commands 段在 NSApp 初始化阶段
        // 比 GeneralPane 的 applyLanguage 早一帧跑，AppKit 已经按系统语言把 File / Edit /
        // Window / Help 这一行 native 菜单文字定下来了 ——
        // 用户会看到「App 内文字是 zh-Hans，顶部菜单栏却还是日语」的奇怪状态。
        AppPreferences.applyAppleLanguagesOverrideAtLaunch()

        // Sparkle —— 这里只是「触一下 shared」让 SPUStandardUpdaterController 早一点完成构造，
        // 这样 Sparkle 周期检查能尽早开始；菜单项 / 助手版本检查共享同一实例。
        _ = SparkleUpdater.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // **明确不处理任何外部 URL / NSUserActivity 事件** —— `[]` 匹配空集。
        // 没这一行时 SwiftUI 看到 `.siz` / `.szs` 通过 LSHandlerRank 路由进来，会**克隆一个新 WindowGroup 窗口**
        // 去满足「外部事件需要落到对应 scene」的约定。我们走 AppDelegate.application(_:open:) 自己拿 URL 入队 +
        // 现有 ContentView 监听通知 drain → 全程一个窗口。
        .handlesExternalEvents(matching: [])
        .commands {
            ArchiveFileCommands()
            ColumnsViewCommands()
            ToolsCommands()

            CommandGroup(replacing: .appInfo) {
                Button(L10n.text("menu.aboutSimpleZip")) {
                    AboutPanel.show()
                }
                // 「重新运行欢迎助手」放在 SimpleZip 菜单里、紧跟「关于」后面 ——
                // 是 macOS 一线 App（Mail / Pages 等）「重置体验」类菜单的常见落位。
                Button(L10n.text("welcome.menu.runAgain")) {
                    NotificationCenter.default.post(name: .openWelcomeAssistant, object: nil)
                }
            }

            CommandGroup(replacing: .help) {
                // 「检查更新…」放在帮助菜单顶部 —— Sparkle 推荐的位置，
                // 也是 macOS 应用（VS Code / Sketch 等）常见落位。
                Button(L10n.text("menu.checkForUpdates")) {
                    SparkleUpdater.shared.checkForUpdates()
                }
                Divider()
                // 把项目主页和 MIT 许可证作为「帮助」菜单里的原生菜单项 ——
                // 比塞进 About 面板的 credits 文本框更符合 macOS 习惯，
                // 也避免 credits 一长就出现滚动条 / 边框的难看效果。
                Button(L10n.text("menu.projectPage")) {
                    AboutPanel.openProjectPage()
                }
                Button(L10n.text("menu.reportBug")) {
                    AboutPanel.openNewIssuePage()
                }
                Button(L10n.text("menu.license")) {
                    AboutPanel.openLicensePage()
                }
            }
        }

        Settings {
            SettingsView()
        }
    }
}

/// 顶部“文件”菜单命令：把工具栏里的核心操作也挂到 macOS 菜单栏。
struct ArchiveFileCommands: Commands {
    @FocusedObject private var model: ArchiveBrowserModel?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button {
                model?.chooseFolder()
            } label: {
                Label(L10n.text("button.openFolder"), systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(model == nil)

            Button {
                model?.chooseArchive()
            } label: {
                Label(L10n.text("button.openArchive"), systemImage: "doc.zipper")
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(model == nil)

            // 「以压缩包打开」选中文件，跳过扩展名校验直接走 7-Zip。
            // 启用条件：选中单个非目录文件，且它本身不是已识别的压缩包（已识别的用普通 Open 即可）。
            Button {
                if let item = model?.selectedFileItems.first {
                    model?.openAsArchive(item.url)
                }
            } label: {
                Label(L10n.text("file.openAsArchive"), systemImage: "doc.zipper")
            }
            .disabled(!canOpenSelectionAsArchive)

            Divider()

            Button {
                model?.openSelectedItem()
            } label: {
                Label(L10n.text("button.open"), systemImage: "arrow.turn.up.right")
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canOpenSelection)

            Button {
                model?.createArchive()
            } label: {
                Label(L10n.text("button.addToArchive"), systemImage: "plus.square.on.square")
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(!canCreateArchive)

            // 「创建签名清单」—— `.szs` 一次性签名一棵文件树（不打包）。
            // **不用 `if` 包裹**：SwiftUI `@CommandsBuilder` 对 if-condition 支持脆弱，
            // 动态隐藏菜单项会让整张菜单在 redraw 时丢 first-responder（破坏 Cmd+C/V/X）。
            // 改成始终插入 + `.disabled(...)` 控制可用性。
            Button {
                NotificationCenter.default.post(name: .openCreateSZSSheet, object: nil)
            } label: {
                Label(L10n.text("szs.create.menuItem"), systemImage: "signature")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!AppPreferences.gpgEnabled || !GPGBackend.isAvailable())

            Divider()

            // 菜单的 Cmd+E 始终走「整包解压」—— 之前用 extractFromCurrentContext() 做「智能路由」，
            // 用户有选中条目时会被静默换成「解压选中」对话框，跟菜单文案 "Extract" 不一致。
            // 「解压选中」由下面 Cmd+Shift+E 专项负责，二者各司其职。
            Button {
                model?.extractArchive()
            } label: {
                Label(L10n.text("button.extract"), systemImage: "tray.and.arrow.down")
            }
            .keyboardShortcut("e", modifiers: [.command])
            .disabled(!canExtractArchive)

            Button {
                model?.extractSelectedArchiveItems()
            } label: {
                Label(L10n.text("button.extractSelected"), systemImage: "arrow.down.doc")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!canExtractSelected)

            Button {
                model?.testArchive()
            } label: {
                Label(L10n.text("button.test"), systemImage: "checkmark.seal")
            }
            .keyboardShortcut("t", modifiers: [.command])
            .disabled(!canTestArchive)

            Menu(L10n.text("button.hash")) {
                Button(L10n.text("hash.all")) {
                    model?.calculateHash()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Divider()

                ForEach(HashAlgorithm.allCases) { algorithm in
                    Button(algorithm.title) {
                        model?.calculateHash(algorithms: [algorithm])
                    }
                }
            }
            .disabled(!canHash)

            Divider()

            Button {
                model?.revealInFinder()
            } label: {
                Label(L10n.text("button.revealInFinder"), systemImage: "arrow.up.forward.app")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model == nil)

            Button {
                model?.reload()
            } label: {
                Label(L10n.text("help.refresh"), systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(model == nil)

            Button {
                model?.goUp()
            } label: {
                Label(L10n.text("help.goUp"), systemImage: "chevron.up")
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(!(model?.canGoUp ?? false))
        }

        CommandGroup(replacing: .pasteboard) {
            Button {
                if isTextInputFocused {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                } else if canManageSelectedFiles {
                    model?.copySelectedFiles()
                } else {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
            } label: {
                Label(L10n.text("file.copy"), systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command])

            Button {
                if isTextInputFocused {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                } else if canManageSelectedFiles {
                    model?.cutSelectedFiles()
                } else {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                }
            } label: {
                Label(L10n.text("file.cut"), systemImage: "scissors")
            }
            .keyboardShortcut("x", modifiers: [.command])

            Button {
                if isTextInputFocused {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                } else if isFolderMode {
                    model?.pasteFiles()
                } else {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
            } label: {
                Label(L10n.text("file.paste"), systemImage: "clipboard")
            }
            .keyboardShortcut("v", modifiers: [.command])

            Button {
                // 把 selectAll(_:) 丢给 first responder：
                // - 文本输入聚焦 → NSText / NSTextView 的 selectAll
                // - NSTableView 聚焦 → 选所有行（NSTableView 默认实现 selectAll(_:)）
                // 旧版本加 `.disabled(!isTextInputFocused)` 试图「只在文本输入时启用」，
                // 但这就把主表格的全选给 break 了 —— 任何 responder 处理就行，不必预先 disable。
                NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
            } label: {
                Label(L10n.text("file.selectAll"), systemImage: "selection.pin.in.out")
            }
            .keyboardShortcut("a", modifiers: [.command])

            Button {
                model?.moveSelectedFilesToFolder()
            } label: {
                Label(L10n.text("file.moveTo"), systemImage: "folder.badge.gearshape")
            }
            .disabled(!canManageSelectedFiles)

            Button {
                model?.deleteSelectedFiles()
            } label: {
                Label(L10n.text("file.delete"), systemImage: "trash")
            }
            // Finder 标准：⌘⌫ 删除（移到废纸篓）。不绑裸 Delete —— 裸退格在浏览 / 选中状态下太容易误触。
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(!canManageSelectedFiles)
        }
    }

    private var canOpenSelectionAsArchive: Bool {
        guard let model, case .folder = model.mode else { return false }
        guard model.selectedFileItems.count == 1, let item = model.selectedFileItems.first else { return false }
        // 已识别的压缩包用普通 Open 即可，避免菜单里出现两个看上去都能用的命令。
        return !item.isDirectory && !ArchiveService.isSupportedArchive(item.url)
    }

    private var canOpenSelection: Bool {
        guard let model else { return false }
        switch model.mode {
        case .folder, .tag:
            return !model.selectedFileItems.isEmpty
        case .archive:
            return model.selectedArchiveItems.contains { $0.isDirectory }
        }
    }

    private var canCreateArchive: Bool {
        guard let model, case .folder = model.mode else { return false }
        return !model.selectedFileItems.isEmpty
    }

    private var canExtractArchive: Bool {
        guard let model else { return false }
        switch model.mode {
        case .archive:
            return true
        case .folder, .tag:
            return model.selectedFileItems.contains { ArchiveService.isSupportedArchive($0.url) }
        }
    }

    private var canExtractSelected: Bool {
        guard let model, case .archive = model.mode else { return false }
        return !model.selectedArchiveItems.isEmpty
    }

    private var canTestArchive: Bool {
        canExtractArchive
    }

    private var canHash: Bool {
        guard let model else { return false }
        switch model.mode {
        case .archive:
            return true
        case .folder, .tag:
            return !model.selectedFileItems.isEmpty
        }
    }

    private var isFolderMode: Bool {
        guard let model, case .folder = model.mode else { return false }
        return true
    }

    private var canManageSelectedFiles: Bool {
        guard let model, case .folder = model.mode else { return false }
        return !model.selectedFileItems.isEmpty
    }

    private var isTextInputFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSText {
            return true
        }
        return responder.responds(to: #selector(NSText.copy(_:))) &&
            responder.responds(to: #selector(NSText.paste(_:)))
    }
}

/// 顶部「视图」菜单 —— 列表列开关（0.1.10 起从 Settings → Columns pane 搬到这里）。
///
/// 0.2.0 计划在此菜单下加「Group By」「Sort By」等多重视图选项；先把 Columns 子菜单结构定下来，
/// 后续加项只是新增 `Menu` 兄弟节点，不需要改既有结构。
///
/// 同一组 AppPreferences key 在两个地方读写（这里的 View 菜单 + 表头右键菜单），AppStorage 会自动跟
/// UserDefaults 双向同步，所以菜单勾选状态、表头右键的 ✓、表格本身的列可见性永远一致，不需要中央协调。
struct ColumnsViewCommands: Commands {
    @AppStorage(AppPreferences.Key.showFileSizeColumn) private var showFileSizeColumn = true
    @AppStorage(AppPreferences.Key.showFileTypeColumn) private var showFileTypeColumn = true
    @AppStorage(AppPreferences.Key.showFileApplicationColumn) private var showFileApplicationColumn = true
    @AppStorage(AppPreferences.Key.showFileLastOpenedColumn) private var showFileLastOpenedColumn = true
    @AppStorage(AppPreferences.Key.showFileDateAddedColumn) private var showFileDateAddedColumn = true
    @AppStorage(AppPreferences.Key.showFileModifiedColumn) private var showFileModifiedColumn = true
    @AppStorage(AppPreferences.Key.showFileCreatedColumn) private var showFileCreatedColumn = true
    @AppStorage(AppPreferences.Key.showArchiveKindColumn) private var showArchiveKindColumn = true
    @AppStorage(AppPreferences.Key.showArchiveSizeColumn) private var showArchiveSizeColumn = true
    @AppStorage(AppPreferences.Key.showArchiveModifiedColumn) private var showArchiveModifiedColumn = true
    @AppStorage(AppPreferences.Key.showArchiveMethodColumn) private var showArchiveMethodColumn = true
    @AppStorage(AppPreferences.Key.showArchivePathColumn) private var showArchivePathColumn = false
    @AppStorage(AppPreferences.Key.showArchiveEncryptedColumn) private var showArchiveEncryptedColumn = false
    @AppStorage(AppPreferences.Key.showArchivePackedSizeColumn) private var showArchivePackedSizeColumn = false
    @AppStorage(AppPreferences.Key.showArchiveCrcColumn) private var showArchiveCrcColumn = false
    @AppStorage(AppPreferences.Key.showArchiveCreatedColumn) private var showArchiveCreatedColumn = false
    @AppStorage(AppPreferences.Key.showArchiveAttributesColumn) private var showArchiveAttributesColumn = false

    var body: some Commands {
        CommandMenu(L10n.text("menu.view")) {
            // 分组（Group By）已挪到 设置 → 视图（含总开关 / 范围 / 默认方式 / 按文件夹）。
            Menu(L10n.text("view.columns.fileBrowser")) {
                Toggle(L10n.text("column.size"), isOn: $showFileSizeColumn)
                Toggle(L10n.text("column.kind"), isOn: $showFileTypeColumn)
                Toggle(L10n.text("column.application"), isOn: $showFileApplicationColumn)
                Toggle(L10n.text("column.lastOpened"), isOn: $showFileLastOpenedColumn)
                Toggle(L10n.text("column.dateAdded"), isOn: $showFileDateAddedColumn)
                Toggle(L10n.text("column.modified"), isOn: $showFileModifiedColumn)
                Toggle(L10n.text("column.created"), isOn: $showFileCreatedColumn)
            }
            Menu(L10n.text("view.columns.archiveBrowser")) {
                Toggle(L10n.text("column.path"), isOn: $showArchivePathColumn)
                Toggle(L10n.text("column.kind"), isOn: $showArchiveKindColumn)
                Toggle(L10n.text("column.size"), isOn: $showArchiveSizeColumn)
                Toggle(L10n.text("column.packedSize"), isOn: $showArchivePackedSizeColumn)
                Toggle(L10n.text("column.modified"), isOn: $showArchiveModifiedColumn)
                Toggle(L10n.text("column.created"), isOn: $showArchiveCreatedColumn)
                Toggle(L10n.text("column.method"), isOn: $showArchiveMethodColumn)
                Toggle(L10n.text("column.crc"), isOn: $showArchiveCrcColumn)
                Toggle(L10n.text("column.attributes"), isOn: $showArchiveAttributesColumn)
                Toggle(L10n.text("column.encrypted"), isOn: $showArchiveEncryptedColumn)
            }
        }
    }
}

struct ToolsCommands: Commands {
    @FocusedObject private var model: ArchiveBrowserModel?

    var body: some Commands {
        CommandMenu(L10n.text("menu.tools")) {
            Button(L10n.text("button.benchmark")) {
                model?.showSevenZipBenchmarkOptions()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(model == nil)
        }
    }
}

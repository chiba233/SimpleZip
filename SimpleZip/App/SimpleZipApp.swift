//
//  SimpleZipApp.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import SwiftUI

/// SimpleZip 应用入口：负责创建主窗口和注册菜单命令。
/// @main 已交给 main.swift —— 它先判 CLI companion(`simplezip` 符号链接 / `--cli`),
/// 不是 CLI 才走到这里的 `SimpleZipApp.main()`。
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
                    // 0.4.2 用户点名：系统 About 面板下岗，重定向到内容更全的「设置 → 关于」。
                    SettingsDeepLink.open(.about)
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
        // #113 查找 ⌘F —— 聚焦主窗口的原生 `.searchable` 搜索框（编辑菜单的标准 Find 位置）。
        CommandGroup(after: .textEditing) {
            Button(L10n.text("menu.find")) {
                model?.requestSearchFocus()
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(model == nil)

            Divider()

            // 0.4.2（用户点名菜单栏 parity）：批量重命名（文件浏览 / 归档内都通,按模式路由）。
            Button(L10n.text("archive.batchRename.menu")) {
                model?.requestBatchRenameAnywhere()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(model == nil)

            // 查找重复文件（归档模式;只读分析）。
            Button(L10n.text("duplicates.menu")) {
                model?.findDuplicateFilesInArchive()
            }
            .disabled({
                guard let model else { return true }
                if case .archive = model.mode { return false }
                return true
            }())
        }

        // 0.4.2 用户点名「左上角菜单栏选项不全」：顶级「操作」菜单 —— 右键里的主力操作全部上桌。
        // GPG 项按 A4 门控（关总开关不渲染）；其余粗粒度 disabled(model == nil)，
        // 细粒度前置条件由各 model 方法自己把关（选区不对会给明确错误提示,不会静默）。
        // 「操作」= 对所选执行的主动作(高频,保持短)。工具 / 分析 / 校验全家搬去新顶级菜单「归档」
        // (用户点名:菜单栏同步右键的新结构 + 长平铺折成分组)。
        CommandMenu(L10n.text("menu.actions")) {
            Button(L10n.text("button.addToArchive")) { model?.createArchive() }
                .disabled(model == nil)
            Button(L10n.text("button.extract")) { model?.extractArchive() }
                .disabled(model == nil)
            Button(L10n.text("button.extractSelected")) { model?.extractSelectedArchiveItems() }
                .disabled(model == nil)
            Button(L10n.text("archive.saveCopyAs")) { model?.saveSelectedArchiveItemCopy() }
                .disabled(model == nil)

            // GPG 对(菜单栏既定折中:disabled 而非动态隐藏,防 first-responder 丢失)。
            Divider()
            Button(L10n.text("szs.create.menuItem")) { model?.createSignedManifest() }
                .disabled(!AppPreferences.gpgEnabled || !GPGBackend.isAvailable() || model == nil)
            Button(L10n.text("file.encrypt.gpg")) { model?.encryptSelectionToGPG() }
                .disabled(!AppPreferences.gpgEnabled || !GPGBackend.isAvailable() || model == nil)
        }

        // 新顶级菜单「归档」:测试 / 校验 / 工具 / 分析 / 包内工具,与右键的分组一一对应。
        CommandMenu(L10n.text("menu.archive")) {
            Button {
                model?.testArchive()
            } label: {
                Label(L10n.text("button.test"), systemImage: "checkmark.seal")
            }
            // ⌃⌘T —— 裸 ⌘T 让给「新建标签页」;原在文件菜单,随测试/哈希家族整体迁来。
            .keyboardShortcut("t", modifiers: [.command, .control])
            .disabled(!canTestArchive)

            Button(L10n.text("file.batchTest.button")) { model?.batchTestSelectedArchives() }
                .disabled(model == nil)

            // 「校验 ▸」与右键同款:全部哈希 + 各算法 + 校验文件两件套。
            Menu(L10n.text("file.submenu.checksums")) {
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

                Divider()

                Button(L10n.text("checksum.generate.menu")) { model?.generateChecksumFileForSelection() }
                    .disabled(!canManageSelectedFiles)
                Button(L10n.text("checksum.verify.menu")) {
                    if let item = model?.selectedFileItems.first { model?.verifyChecksumFile(item) }
                }
                .disabled(!canVerifyChecksumSelection)
            }
            .disabled(!canHash)

            Divider()

            Button(L10n.text("file.compareArchives")) { model?.compareSelectedArchives() }
                .disabled(model == nil)
            Button(L10n.text("file.convert.menuItem")) { model?.requestConvertSelectedArchives() }
                .disabled(model == nil)
            Button(L10n.text("file.split.menuItem")) { model?.splitSelectedFile() }
                .disabled(!canSplitSelectedFile)
            Button(L10n.text("file.combine.menuItem")) { model?.combineSelectedVolumes() }
                .disabled(!canCombineSelectedVolumes)
            Button(L10n.text("missingVolumes.menu")) { model?.searchMissingVolumesForSelection() }
                .disabled(model == nil)

            Divider()

            Button(L10n.text("inspect.menu")) { model?.inspectSelectedArchiveForRelease() }
                .disabled(model == nil)
            Button(L10n.text("space.menu")) { model?.analyzeSelectedArchiveSpace() }
                .disabled(model == nil)
            Button(L10n.text("dupArchives.menu")) { model?.findDuplicateArchivesInFolder() }
                .disabled(!isFolderMode)
            // #68:扫归档里的敏感/配置/脚本/许可证文件(确定性扫描;报告里再 AI 解释)。归档打开时可用。
            Button(L10n.text("menu.sensitiveFiles")) { model?.presentSensitiveFileReport() }
                .disabled(!isArchiveOpen)

            // #63(macOS 26 AI):用一句话找「文件X在哪个包」—— 仅 AI 可用时出现(A4)。
            if AIReportAssistant.isReady {
                Button(L10n.text("menu.findArchive")) { model?.presentArchiveFinder() }
                    .disabled(model == nil)
            }

            Divider()

            // 包内工具(打开压缩包后可用)。
            Button(L10n.text("contentSearch.menu")) { model?.promptContentSearch() }
                .disabled(!isArchiveOpen)
            Button(L10n.text("duplicates.menu")) { model?.findDuplicateFilesInArchive() }
                .disabled(!isArchiveOpen)
            Button(L10n.text("security.banner.review")) { model?.showsArchiveSecurityReport = true }
                .disabled(model?.canShowArchiveSecurityReport != true)
            Button(L10n.text("archive.comment.menu")) { model?.showsArchiveCommentEditor = true }
                .disabled(model?.canEditArchiveComment != true)
            Button(L10n.text("archive.cleanJunk.plain")) { model?.cleanArchiveJunkEntries() }
                .disabled(model?.canDropIntoOpenArchive != true)
        }

        // 0.4.2 #93 菜单一致性收尾：右键的高频项补进菜单栏(文件域)。
        CommandGroup(after: .newItem) {
            Divider()
            Button(L10n.text("button.open")) {
                if let item = model?.selectedFileItems.first { model?.open(item) }
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(model?.selectedFileItems.isEmpty != false)

            Button(L10n.text("file.openAsArchive")) {
                if let item = model?.selectedFileItems.first { model?.openAsArchive(item.url) }
            }
            .disabled(model?.selectedFileItems.isEmpty != false)

            Button(L10n.text("file.newFolder")) { model?.createNewFolderAndBeginRename() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model == nil)

            Button(L10n.text("file.duplicate")) { model?.duplicateSelectedFiles() }
                .disabled(model?.selectedFileItems.isEmpty != false)

            Divider()

            Button(L10n.text("file.getInfo")) { model?.showGetInfoForSelection() }
                .keyboardShortcut("i", modifiers: [.command])
                .disabled(model == nil)

            Button(L10n.text("button.revealInFinder")) { model?.revealInFinder() }
                .disabled(model == nil)
        }

        CommandGroup(replacing: .newItem) {
            // 「新建标签页」⌘T —— 在当前窗口里新开一个标签（全新 ContentView / ArchiveBrowserModel）。
            // 自己用 AppKit 建窗 + addTabbedWindow，零闪烁；不依赖 model，任何时候都可用。
            Button(L10n.text("menu.newTab")) {
                MainWindowFactory.open(asTab: true)
            }
            .keyboardShortcut("t", modifiers: [.command])

            // 「新建窗口」—— 故意开一个独立窗口（不并标签）。⌘N 已被「添加到压缩包」占用、⇧⌘N 被「创建签名清单」
            // 占用，这里用 ⌥⌘N（如需别的键告诉我）。
            Button(L10n.text("menu.newWindow")) {
                MainWindowFactory.open(asTab: false)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Divider()

            Button {
                model?.createNewFolderAndBeginRename()
            } label: {
                Label(L10n.text("file.newFolder"), systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!isFolderMode)

            Menu {
                ForEach(ArchiveBrowserModel.NewFileTemplate.allCases) { template in
                    Button {
                        model?.createNewFileAndBeginRename(template: template)
                    } label: {
                        Label(template.title, systemImage: template.systemImage)
                    }
                }
            } label: {
                Label(L10n.text("file.newFile"), systemImage: "doc.badge.plus")
            }
            .disabled(!isFolderMode)

            Divider()

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

            // 「加密为 .gpg」/「创建符号链接」之前只在右键菜单里有,菜单栏缺失 —— 补齐 parity。
            // GPG 项跟上面的「创建签名清单」一样用 `.disabled`(而非动态隐藏)：菜单栏里动态增删项会让
            // 整张菜单 redraw 时丢 first-responder、破坏 Cmd+C/V/X —— 这是菜单栏的既定折中(A4 的可见性
            // 强约束针对主界面/右键入口;菜单栏统一走 disabled)。
            Button {
                model?.encryptSelectionToGPG()
            } label: {
                Label(L10n.text("file.encrypt.gpg"), systemImage: "lock.doc")
            }
            .disabled(!AppPreferences.gpgEnabled || !GPGBackend.isAvailable() || !canManageSelectedFiles)

            Button {
                model?.createSymbolicLinkForSelection()
            } label: {
                Label(L10n.text("file.makeSymlink"), systemImage: "link")
            }
            .disabled(!canManageSelectedFiles)

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

            // 测试(⌃⌘T)与哈希家族已整体迁往新顶级菜单「归档」(校验 ▸),文件菜单瘦身。

            Divider()

            // 「显示简介」⌘I —— 右键菜单已有，补进 File 菜单做 parity（Quick Look / 重命名 / 打开方式
            // 绑在 NSOutlineView 协调器上，菜单栏 parity 留作专项 #93；Get Info 只需选中 URL，可直接走 model）。
            Button {
                model?.showGetInfoForSelection()
            } label: {
                Label(L10n.text("file.getInfo"), systemImage: "info.circle")
            }
            .keyboardShortcut("i", modifiers: [.command])
            .disabled(!canManageSelectedFiles)

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

        CommandGroup(replacing: .undoRedo) {
            // ⌘Z / ⇧⌘Z：正在编辑文本（地址栏 / 内联重命名）时交给字段编辑器的 undo（撤销打字）；
            // 否则走主窗口的文件操作撤销栈（移动 / 粘贴 / 副本 / 重命名 / 删除）。按真实 first responder
            // 路由，不依赖 isTextInputFocused（内联重命名是 AppKit 字段编辑器，未必被它跟踪）。
            Button(undoMenuTitle) {
                if let text = NSApp.keyWindow?.firstResponder as? NSText, text.undoManager?.canUndo == true {
                    text.undoManager?.undo()
                } else {
                    model?.undoFileOperation()
                }
            }
            .keyboardShortcut("z", modifiers: [.command])
            .disabled(!canUndoMenuItem)

            Button(redoMenuTitle) {
                if let text = NSApp.keyWindow?.firstResponder as? NSText, text.undoManager?.canRedo == true {
                    text.undoManager?.redo()
                } else {
                    model?.redoFileOperation()
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!canRedoMenuItem)
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
                model?.duplicateSelectedFiles()
            } label: {
                Label(L10n.text("file.duplicate"), systemImage: "plus.square.on.square")
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(!canManageSelectedFiles)

            Button {
                model?.combineSelectedVolumes()
            } label: {
                Label(L10n.text("file.combine.menuItem"), systemImage: "arrow.triangle.merge")
            }
            .disabled(!canCombineSelectedVolumes)

            Button {
                model?.splitSelectedFile()
            } label: {
                Label(L10n.text("file.split.menuItem"), systemImage: "rectangle.split.2x1")
            }
            .disabled(!canSplitSelectedFile)

            Button {
                model?.moveSelectedFilesToFolder()
            } label: {
                Label(L10n.text("file.moveTo"), systemImage: "folder.badge.gearshape")
            }
            .disabled(!canManageSelectedFiles)

            Button {
                model?.removeSelectedFromCurrentTag()
            } label: {
                Label(removeFromCurrentTagTitle, systemImage: "tag.slash")
            }
            .disabled(!canRemoveFromCurrentTag)

            Button {
                model?.deleteSelectionInCurrentContext()
            } label: {
                Label(L10n.text("file.delete"), systemImage: "trash")
            }
            // Finder 标准：⌘⌫ 删除（文件移废纸篓；可编辑归档里删条目）。不绑裸 Delete —— 太容易误触。
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(!canDeleteCurrentSelection)
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
            // 0.4.4:`.siz` 也算(解压走既有 unwrap 流程,测试 = 签名验证 sheet,A5)。
            return model.selectedFileItems.contains { SignedContainerService.isToolableArchive($0.url) }
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

    /// 「归档」菜单包内工具(内容搜索 / 重复文件)的可用条件:正浏览一个压缩包。
    private var isArchiveOpen: Bool {
        guard let model, case .archive = model.mode else { return false }
        return true
    }

    /// 「验证校验文件」:单选且文件名是已识别的校验文件(SHA256SUMS / *.sha256 …)。
    private var canVerifyChecksumSelection: Bool {
        guard let model, model.selectedFileItems.count == 1,
              let only = model.selectedFileItems.first, !only.isDirectory else { return false }
        return ChecksumFile.isChecksumFileName(only.name)
    }

    private var canSplitSelectedFile: Bool {
        guard let model else { return false }
        switch model.mode {
        case .folder, .tag:
            return canSplitFileItemSelection(model)
        case .archive:
            return false
        }
    }

    private var canCombineSelectedVolumes: Bool {
        guard let model else { return false }
        switch model.mode {
        case .folder, .tag:
            guard model.selectedFileItems.count == 1,
                  let item = model.selectedFileItems.first else { return false }
            return FileSplitCombine.isFirstVolume(item.url)
        case .archive:
            return false
        }
    }

    private func canSplitFileItemSelection(_ model: ArchiveBrowserModel) -> Bool {
        guard model.selectedFileItems.count == 1,
              let item = model.selectedFileItems.first else { return false }
        return !item.isDirectory
    }

    private var canRemoveFromCurrentTag: Bool {
        guard let model, case .tag = model.mode else { return false }
        return !model.selectedFileItems.isEmpty
    }

    private var removeFromCurrentTagTitle: String {
        guard let model, case .tag(let tag) = model.mode else {
            return L10n.text("file.removeFromTag.fallback")
        }
        return L10n.format("file.removeFromTag", tag)
    }

    /// ⌘⌫ 删除可用：文件夹里选中文件，或可编辑归档里选中条目。
    private var canDeleteCurrentSelection: Bool {
        guard let model else { return false }
        if case .folder = model.mode { return !model.selectedFileItems.isEmpty }
        if model.canDropIntoOpenArchive { return !model.selectedArchiveItems.isEmpty }
        return false
    }

    private var isTextInputFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSText {
            return true
        }
        return responder.responds(to: #selector(NSText.copy(_:))) &&
            responder.responds(to: #selector(NSText.paste(_:)))
    }

    private var undoMenuTitle: String {
        guard !textResponderCanUndo, let actionName = model?.fileUndoActionName else {
            return L10n.text("menu.undo")
        }
        return L10n.format("menu.undoNamed", actionName)
    }

    private var redoMenuTitle: String {
        guard !textResponderCanRedo, let actionName = model?.fileRedoActionName else {
            return L10n.text("menu.redo")
        }
        return L10n.format("menu.redoNamed", actionName)
    }

    private var textResponderCanUndo: Bool {
        guard let text = NSApp.keyWindow?.firstResponder as? NSText else { return false }
        return text.undoManager?.canUndo == true
    }

    private var textResponderCanRedo: Bool {
        guard let text = NSApp.keyWindow?.firstResponder as? NSText else { return false }
        return text.undoManager?.canRedo == true
    }

    private var canUndoMenuItem: Bool {
        textResponderCanUndo || model?.fileUndoManager.canUndo == true
    }

    private var canRedoMenuItem: Bool {
        textResponderCanRedo || model?.fileUndoManager.canRedo == true
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
    @AppStorage(AppPreferences.Key.showFileSymlinkColumn) private var showFileSymlinkColumn = false
    @AppStorage(AppPreferences.Key.showFilePermissionsColumn) private var showFilePermissionsColumn = false
    @AppStorage(AppPreferences.Key.showFileOwnerColumn) private var showFileOwnerColumn = false
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
    @AppStorage(AppPreferences.Key.showArchiveAccessedColumn) private var showArchiveAccessedColumn = false
    @AppStorage(AppPreferences.Key.showArchiveHostOSColumn) private var showArchiveHostOSColumn = false
    @AppStorage(AppPreferences.Key.showArchiveCharacteristicsColumn) private var showArchiveCharacteristicsColumn = false
    @AppStorage(AppPreferences.Key.showArchiveSymlinkColumn) private var showArchiveSymlinkColumn = false
    @AppStorage(AppPreferences.Key.showArchiveCommentColumn) private var showArchiveCommentColumn = false
    // 0.4.2 #4:分卷集折叠开关(默认开)。注意 getter 是 defaultTrueBool —— @AppStorage 初值必须同为 true。
    @AppStorage(AppPreferences.Key.collapseVolumeSets) private var collapseVolumeSets = true

    var body: some Commands {
        CommandMenu(L10n.text("menu.view")) {
            // 0.4.2 #4:分卷集折叠(文件浏览把 .001/.002… 家族折叠成首卷一行)。
            Toggle(L10n.text("menu.view.collapseVolumes"), isOn: $collapseVolumeSets)

            Divider()

            // 「显示标签页栏」由 AppKit 在有标签组时自动插入（避免重复，这里不再自建）；
            // 它默认没有快捷键，我们在运行时给它绑 ⇧⌘T（见 MainWindowFactory.bindTabBarMenuShortcut）。
            // 分组（Group By）已挪到 设置 → 视图（含总开关 / 范围 / 默认方式 / 按文件夹）。
            Menu(L10n.text("view.columns.fileBrowser")) {
                Toggle(L10n.text("column.size"), isOn: $showFileSizeColumn)
                Toggle(L10n.text("column.kind"), isOn: $showFileTypeColumn)
                Toggle(L10n.text("column.application"), isOn: $showFileApplicationColumn)
                Toggle(L10n.text("column.lastOpened"), isOn: $showFileLastOpenedColumn)
                Toggle(L10n.text("column.dateAdded"), isOn: $showFileDateAddedColumn)
                Toggle(L10n.text("column.modified"), isOn: $showFileModifiedColumn)
                Toggle(L10n.text("column.created"), isOn: $showFileCreatedColumn)
                Toggle(L10n.text("column.symlink"), isOn: $showFileSymlinkColumn)
                Toggle(L10n.text("column.permissions"), isOn: $showFilePermissionsColumn)
                Toggle(L10n.text("column.owner"), isOn: $showFileOwnerColumn)
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
                Toggle(L10n.text("column.accessed"), isOn: $showArchiveAccessedColumn)
                Toggle(L10n.text("column.hostOS"), isOn: $showArchiveHostOSColumn)
                Toggle(L10n.text("column.characteristics"), isOn: $showArchiveCharacteristicsColumn)
                Toggle(L10n.text("column.symlink"), isOn: $showArchiveSymlinkColumn)
                Toggle(L10n.text("column.comment"), isOn: $showArchiveCommentColumn)
                Toggle(L10n.text("column.encrypted"), isOn: $showArchiveEncryptedColumn)
            }
        }
    }
}

struct ToolsCommands: Commands {
    @FocusedObject private var model: ArchiveBrowserModel?

    var body: some Commands {
        CommandMenu(L10n.text("menu.tools")) {
            Button(L10n.text("menu.activityCenter")) {
                ActivityWindowController.shared.show()
            }

            Divider()

            Button(L10n.text("releaseAssistant.menu")) {
                model?.showReleaseAssistant()
            }
            .disabled(model == nil)

            Button(L10n.text("button.benchmark")) {
                model?.showSevenZipBenchmarkOptions()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(model == nil)
        }
    }
}

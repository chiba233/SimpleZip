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

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            ArchiveFileCommands()
            ToolsCommands()

            CommandGroup(replacing: .appInfo) {
                Button(L10n.text("menu.aboutSimpleZip")) {
                    AboutPanel.show()
                }
            }

            CommandGroup(replacing: .help) {
                Button(L10n.text("menu.projectPage")) {
                    AboutPanel.openProjectPage()
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
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            } label: {
                Label(L10n.text("file.selectAll"), systemImage: "selection.pin.in.out")
            }
            .keyboardShortcut("a", modifiers: [.command])
            .disabled(!isTextInputFocused)

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
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!canManageSelectedFiles)
        }
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

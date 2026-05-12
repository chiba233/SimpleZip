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
            Button(L10n.text("button.openFolder")) {
                model?.chooseFolder()
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(model == nil)

            Button(L10n.text("button.openArchive")) {
                model?.chooseArchive()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(model == nil)

            Divider()

            Button(L10n.text("button.open")) {
                model?.openSelectedItem()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canOpenSelection)

            Button(L10n.text("button.addToArchive")) {
                model?.createArchive()
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(!canCreateArchive)

            Divider()

            Button(L10n.text("button.extract")) {
                model?.extractArchive()
            }
            .keyboardShortcut("e", modifiers: [.command])
            .disabled(!canExtractArchive)

            Button(L10n.text("button.extractSelected")) {
                model?.extractSelectedArchiveItems()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!canExtractSelected)

            Button(L10n.text("button.test")) {
                model?.testArchive()
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

            Button(L10n.text("button.revealInFinder")) {
                model?.revealInFinder()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model == nil)

            Button(L10n.text("help.refresh")) {
                model?.reload()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(model == nil)

            Button(L10n.text("help.goUp")) {
                model?.goUp()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(!(model?.canGoUp ?? false))
        }

        CommandGroup(replacing: .pasteboard) {
            Button(L10n.text("file.copy")) {
                if canManageSelectedFiles {
                    model?.copySelectedFiles()
                } else {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
            }
            .keyboardShortcut("c", modifiers: [.command])

            Button(L10n.text("file.cut")) {
                if canManageSelectedFiles {
                    model?.cutSelectedFiles()
                } else {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                }
            }
            .keyboardShortcut("x", modifiers: [.command])

            Button(L10n.text("file.paste")) {
                if isFolderMode {
                    model?.pasteFiles()
                } else {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
            }
            .keyboardShortcut("v", modifiers: [.command])

            Button(L10n.text("file.moveTo")) {
                model?.moveSelectedFilesToFolder()
            }
            .disabled(!canManageSelectedFiles)

            Button(L10n.text("file.delete")) {
                model?.deleteSelectedFiles()
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

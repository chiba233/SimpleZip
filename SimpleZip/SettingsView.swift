//
//  SettingsView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 设置窗口：放置会影响浏览、解压和文件显示行为的默认项。
struct SettingsView: View {
    @AppStorage(AppPreferences.Key.appLanguage) private var appLanguage = AppLanguage.system.rawValue
    @AppStorage(AppPreferences.Key.startupLocation) private var startupLocation = StartupLocation.home.rawValue
    @AppStorage(AppPreferences.Key.defaultExtractLocation) private var defaultExtractLocation = DefaultExtractLocation.askEveryTime.rawValue
    @AppStorage(AppPreferences.Key.overwriteBehavior) private var overwriteBehavior = OverwriteBehavior.overwrite.rawValue
    @AppStorage(AppPreferences.Key.showHiddenFiles) private var showHiddenFiles = false
    @AppStorage(AppPreferences.Key.rememberLastFolder) private var rememberLastFolder = true
    @AppStorage(AppPreferences.Key.showFileSizeColumn) private var showFileSizeColumn = true
    @AppStorage(AppPreferences.Key.showFileTypeColumn) private var showFileTypeColumn = true
    @AppStorage(AppPreferences.Key.showFileModifiedColumn) private var showFileModifiedColumn = true
    @AppStorage(AppPreferences.Key.showArchiveSizeColumn) private var showArchiveSizeColumn = true
    @AppStorage(AppPreferences.Key.showArchiveModifiedColumn) private var showArchiveModifiedColumn = true
    @AppStorage(AppPreferences.Key.showArchiveMethodColumn) private var showArchiveMethodColumn = true
    @State private var defaultAppMessage: String?
    @State private var associationStatus: [String: String] = [:]
    @State private var languageMessage: String?

    var body: some View {
        Form {
            Section(L10n.text("settings.section.general")) {
                Picker(L10n.text("settings.language"), selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                }
                .onChange(of: appLanguage) { newValue in
                    applyLanguage(newValue)
                }

                if let languageMessage {
                    Text(languageMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.text("settings.section.defaults")) {
                Picker(L10n.text("settings.startupLocation"), selection: $startupLocation) {
                    ForEach(StartupLocation.allCases) { location in
                        Text(location.title).tag(location.rawValue)
                    }
                }

                Picker(L10n.text("settings.defaultExtractLocation"), selection: $defaultExtractLocation) {
                    ForEach(DefaultExtractLocation.allCases) { location in
                        Text(location.title).tag(location.rawValue)
                    }
                }

                Picker(L10n.text("settings.overwriteBehavior"), selection: $overwriteBehavior) {
                    ForEach(OverwriteBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior.rawValue)
                    }
                }
            }

            Section(L10n.text("settings.section.browser")) {
                Toggle(L10n.text("settings.showHiddenFiles"), isOn: $showHiddenFiles)
                Toggle(L10n.text("settings.rememberLastFolder"), isOn: $rememberLastFolder)
            }

            Section(L10n.text("settings.section.fileAssociations")) {
                VStack(spacing: 0) {
                    ForEach(ArchiveAssociationService.supportedAssociations) { association in
                        FileAssociationRow(
                            association: association,
                            currentDefaultApp: associationStatus[association.id] ?? L10n.text("settings.association.loading"),
                            isSimpleZipDefault: ArchiveAssociationService.isSimpleZipDefault(for: association)
                        ) {
                            setDefaultArchiveApp(for: association)
                        }

                        if association.id != ArchiveAssociationService.supportedAssociations.last?.id {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }

                if let defaultAppMessage {
                    Text(defaultAppMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.text("settings.section.columns")) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        Text(L10n.text("settings.columns.fileBrowser"))
                            .font(.headline)
                        Text(L10n.text("settings.columns.archiveBrowser"))
                            .font(.headline)
                    }

                    GridRow {
                        Toggle(L10n.text("column.size"), isOn: $showFileSizeColumn)
                        Toggle(L10n.text("column.size"), isOn: $showArchiveSizeColumn)
                    }

                    GridRow {
                        Toggle(L10n.text("column.type"), isOn: $showFileTypeColumn)
                        Toggle(L10n.text("column.modified"), isOn: $showArchiveModifiedColumn)
                    }

                    GridRow {
                        Toggle(L10n.text("column.modified"), isOn: $showFileModifiedColumn)
                        Toggle(L10n.text("column.method"), isOn: $showArchiveMethodColumn)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 660)
        .navigationTitle(L10n.text("settings.title"))
        .onAppear(perform: refreshAssociationStatus)
    }

    private func setDefaultArchiveApp() {
        do {
            try ArchiveAssociationService.setAsDefaultForSupportedArchives()
            defaultAppMessage = L10n.text("settings.defaultArchiveAppDone")
        } catch {
            defaultAppMessage = error.localizedDescription
        }
    }

    private func setDefaultArchiveApp(for association: ArchiveAssociation) {
        do {
            try ArchiveAssociationService.setAsDefault(for: association)
            defaultAppMessage = L10n.format("settings.defaultArchiveTypeDone", ".\(association.fileExtension)")
            refreshAssociationStatus()
        } catch {
            defaultAppMessage = error.localizedDescription
        }
    }

    private func refreshAssociationStatus() {
        associationStatus = Dictionary(uniqueKeysWithValues: ArchiveAssociationService.supportedAssociations.map { association in
            (association.id, ArchiveAssociationService.currentDefaultAppName(for: association))
        })
    }

    private func applyLanguage(_ rawValue: String) {
        let language = AppLanguage(rawValue: rawValue) ?? .system
        if let code = language.appleLanguageCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        languageMessage = L10n.text("settings.languageRestartHint")
    }
}

/// 单个扩展名的文件关联设置行。
private struct FileAssociationRow: View {
    let association: ArchiveAssociation
    let currentDefaultApp: String
    let isSimpleZipDefault: Bool
    let setDefault: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(".\(association.fileExtension)")
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
                .frame(width: 48, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(association.title)
                Text(L10n.format("settings.association.currentDefault", currentDefaultApp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isSimpleZipDefault {
                Label(L10n.text("settings.association.simpleZipDefault"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button(L10n.text("settings.association.setDefault")) {
                    setDefault()
                }
            }
        }
        .padding(.vertical, 8)
    }
}

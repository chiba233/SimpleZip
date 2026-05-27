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
    @AppStorage(AppPreferences.Key.overwriteBehavior) private var overwriteBehavior = OverwriteBehavior.ask.rawValue
    @AppStorage(AppPreferences.Key.suspiciousPathPolicy) private var suspiciousPathPolicy = ArchiveSecurityDecision.ask.rawValue
    @AppStorage(AppPreferences.Key.symbolicLinkPolicy) private var symbolicLinkPolicy = ArchiveSecurityDecision.ask.rawValue
    @AppStorage(AppPreferences.Key.activeContentOpenPolicy) private var activeContentOpenPolicy = ArchiveSecurityDecision.ask.rawValue
    @AppStorage(AppPreferences.Key.showHiddenFiles) private var showHiddenFiles = false
    @AppStorage(AppPreferences.Key.showSymbolicLinks) private var showSymbolicLinks = true
    @AppStorage(AppPreferences.Key.followFinderStructure) private var followFinderStructure = false
    @AppStorage(AppPreferences.Key.hiddenSuffixesEnabled) private var hiddenSuffixesEnabled = true
    @AppStorage(AppPreferences.Key.rememberLastFolder) private var rememberLastFolder = true
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
    @AppStorage(AppPreferences.Key.sevenZipBackend) private var sevenZipBackend = SevenZipBackend.automatic.rawValue
    @AppStorage(AppPreferences.Key.rarBackend) private var rarBackend = RarBackend.automatic.rawValue
    @State private var defaultAppMessage: String?
    @State private var associationStatus: [String: String] = [:]
    @State private var languageMessage: String?
    @State private var sevenZipVersion = L10n.text("settings.7zip.checking")
    @State private var rarVersion = L10n.text("settings.rar.checking")
    @State private var selectedPane = SettingsPane.general
    @State private var showsHiddenSuffixDrawer = false
    @State private var hiddenRecommendedSuffixes = AppPreferences.hiddenRecommendedSuffixes
    @State private var hiddenCustomSuffixes = AppPreferences.hiddenCustomSuffixes
    @State private var hiddenSuffixInput = ""

    var body: some View {
        TabView(selection: $selectedPane) {
            generalPane
                .tabItem {
                    Label(L10n.text("settings.section.general"), systemImage: "gearshape")
                }
                .tag(SettingsPane.general)

            archivePane
                .tabItem {
                    Label(L10n.text("settings.section.archive"), systemImage: "archivebox")
                }
                .tag(SettingsPane.archive)

            browserPane
                .tabItem {
                    Label(L10n.text("settings.section.browser"), systemImage: "folder")
                }
                .tag(SettingsPane.browser)

            fileAssociationsPane
                .tabItem {
                    Label(L10n.text("settings.section.fileAssociations"), systemImage: "doc.badge.gearshape")
                }
                .tag(SettingsPane.fileAssociations)

            columnsPane
                .tabItem {
                    Label(L10n.text("settings.section.columns"), systemImage: "tablecells")
                }
                .tag(SettingsPane.columns)
        }
        .padding(20)
        .frame(width: 720, height: 520)
        .navigationTitle(L10n.text("settings.title"))
        .onAppear {
            if SettingsNavigation.consumePendingColumnsRequest() {
                selectColumnsPane()
            }
            hiddenRecommendedSuffixes = AppPreferences.hiddenRecommendedSuffixes
            hiddenCustomSuffixes = AppPreferences.hiddenCustomSuffixes
            refreshAssociationStatus()
            refreshSevenZipVersion()
            refreshRarVersion()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsColumns)) { _ in
            selectColumnsPane()
        }
        .onChange(of: showHiddenFiles) { _ in
            NotificationCenter.default.post(name: .browserPreferencesChanged, object: nil)
        }
        .onChange(of: showSymbolicLinks) { _ in
            NotificationCenter.default.post(name: .browserPreferencesChanged, object: nil)
        }
        .onChange(of: followFinderStructure) { _ in
            NotificationCenter.default.post(name: .browserPreferencesChanged, object: nil)
        }
        .onChange(of: hiddenSuffixesEnabled) { _ in
            NotificationCenter.default.post(name: .browserPreferencesChanged, object: nil)
        }
        .onChange(of: hiddenRecommendedSuffixes) { newValue in
            AppPreferences.setHiddenRecommendedSuffixes(newValue)
            hiddenRecommendedSuffixes = AppPreferences.hiddenRecommendedSuffixes
            NotificationCenter.default.post(name: .browserPreferencesChanged, object: nil)
        }
        .onChange(of: hiddenCustomSuffixes) { newValue in
            AppPreferences.setHiddenCustomSuffixes(newValue)
            hiddenCustomSuffixes = AppPreferences.hiddenCustomSuffixes
            NotificationCenter.default.post(name: .browserPreferencesChanged, object: nil)
        }
    }

    private var generalPane: some View {
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

                Picker(L10n.text("settings.startupLocation"), selection: $startupLocation) {
                    ForEach(StartupLocation.allCases) { location in
                        Text(location.title).tag(location.rawValue)
                    }
                }

                Toggle(L10n.text("settings.rememberLastFolder"), isOn: $rememberLastFolder)
            }
        }
        .formStyle(.grouped)
    }

    private var archivePane: some View {
        Form {
            Section(L10n.text("settings.section.defaults")) {
                Picker(L10n.text("settings.overwriteBehavior"), selection: $overwriteBehavior) {
                    ForEach(OverwriteBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior.rawValue)
                    }
                }
            }

            Section(L10n.text("settings.section.security")) {
                Picker(L10n.text("settings.security.suspiciousPaths"), selection: $suspiciousPathPolicy) {
                    ForEach(ArchiveSecurityDecision.allCases) { decision in
                        Text(decision.title).tag(decision.rawValue)
                    }
                }

                Picker(L10n.text("settings.security.symbolicLinks"), selection: $symbolicLinkPolicy) {
                    ForEach(ArchiveSecurityDecision.allCases) { decision in
                        Text(decision.title).tag(decision.rawValue)
                    }
                }

                Picker(L10n.text("settings.security.activeContent"), selection: $activeContentOpenPolicy) {
                    ForEach(ArchiveSecurityDecision.allCases) { decision in
                        Text(decision.title).tag(decision.rawValue)
                    }
                }

                Text(L10n.text("settings.security.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.text("settings.7zip.backend")) {
                Picker(L10n.text("settings.7zip.backend"), selection: $sevenZipBackend) {
                    ForEach(SevenZipBackend.allCases) { backend in
                        Text(backend.title).tag(backend.rawValue)
                    }
                }
                .onChange(of: sevenZipBackend) { _ in
                    refreshSevenZipVersion()
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.format("settings.7zip.path", ArchiveService.sevenZipBackendDescription()))
                    Text(L10n.format("settings.7zip.version", sevenZipVersion))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(L10n.text("settings.rar.backend")) {
                Picker(L10n.text("settings.rar.backend"), selection: $rarBackend) {
                    ForEach(RarBackend.allCases) { backend in
                        Text(backend.title).tag(backend.rawValue)
                    }
                }
                .onChange(of: rarBackend) { _ in
                    refreshRarVersion()
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.format("settings.rar.path", ArchiveService.rarBackendDescription()))
                    Text(L10n.format("settings.rar.version", rarVersion))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var browserPane: some View {
        Form {
            Section(L10n.text("settings.section.browser")) {
                Toggle(L10n.text("settings.showHiddenFiles"), isOn: $showHiddenFiles)
                Toggle(L10n.text("settings.showSymbolicLinks"), isOn: $showSymbolicLinks)
                Toggle(L10n.text("settings.followFinderStructure"), isOn: $followFinderStructure)
                DisclosureGroup(isExpanded: $showsHiddenSuffixDrawer) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text("settings.hiddenSuffixes.hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text("settings.hiddenSuffixes.recommended"))
                                .font(.headline)
                            ForEach(AppPreferences.recommendedHiddenSuffixes, id: \.self) { suffix in
                                let normalizedSuffix = AppPreferences.normalizedHiddenSuffix(suffix)
                                Toggle(
                                    ".\(suffix)",
                                    isOn: Binding(
                                        get: { hiddenRecommendedSuffixes.contains { AppPreferences.normalizedHiddenSuffix($0) == normalizedSuffix } },
                                        set: { shouldHide in
                                            if shouldHide {
                                                hiddenRecommendedSuffixes.append(suffix)
                                            } else {
                                                hiddenRecommendedSuffixes.removeAll { $0.caseInsensitiveCompare(suffix) == .orderedSame }
                                            }
                                        }
                                    )
                                )
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text("settings.hiddenSuffixes.custom"))
                                .font(.headline)

                            if hiddenCustomSuffixes.isEmpty {
                                Text(L10n.text("settings.hiddenSuffixes.customEmpty"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(hiddenCustomSuffixes, id: \.self) { suffix in
                                    HStack {
                                        Text(".\(suffix)")
                                            .font(.system(.body, design: .monospaced))
                                        Spacer()
                                        Button {
                                            hiddenCustomSuffixes.removeAll { $0 == suffix }
                                        } label: {
                                            Image(systemName: "minus.circle")
                                        }
                                        .buttonStyle(.borderless)
                                        .help(L10n.text("settings.hiddenSuffixes.remove"))
                                    }
                                }
                            }

                            HStack {
                                let normalizedSuffix = AppPreferences.normalizedHiddenSuffix(hiddenSuffixInput)
                                let blockedSuffixes = Set((hiddenCustomSuffixes + hiddenRecommendedSuffixes).map { $0.lowercased() })
                                Text(".")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                TextField(
                                    "",
                                    text: $hiddenSuffixInput,
                                    prompt: Text(L10n.text("settings.hiddenSuffixes.customPlaceholder"))
                                        .foregroundColor(.secondary)
                                )
                                .font(.system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 220)
                                Button(L10n.text("button.add")) {
                                    hiddenCustomSuffixes.append(normalizedSuffix)
                                    hiddenSuffixInput = ""
                                }
                                .disabled(normalizedSuffix.isEmpty || blockedSuffixes.contains(normalizedSuffix))
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Toggle(L10n.text("settings.hiddenSuffixes"), isOn: $hiddenSuffixesEnabled)
                }
                .disabled(!hiddenSuffixesEnabled)
            }
        }
        .formStyle(.grouped)
    }

    private var fileAssociationsPane: some View {
        Form {
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
        }
        .formStyle(.grouped)
    }

    private var columnsPane: some View {
        Form {
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
                        Toggle(L10n.text("column.kind"), isOn: $showArchiveKindColumn)
                    }

                    GridRow {
                        Toggle(L10n.text("column.kind"), isOn: $showFileTypeColumn)
                        Toggle(L10n.text("column.size"), isOn: $showArchiveSizeColumn)
                    }

                    GridRow {
                        Toggle(L10n.text("column.application"), isOn: $showFileApplicationColumn)
                        Toggle(L10n.text("column.size"), isOn: $showArchiveSizeColumn)
                    }

                    GridRow {
                        Toggle(L10n.text("column.lastOpened"), isOn: $showFileLastOpenedColumn)
                        Toggle(L10n.text("column.modified"), isOn: $showArchiveModifiedColumn)
                    }

                    GridRow {
                        Toggle(L10n.text("column.dateAdded"), isOn: $showFileDateAddedColumn)
                        Toggle(L10n.text("column.method"), isOn: $showArchiveMethodColumn)
                    }

                    GridRow {
                        Toggle(L10n.text("column.modified"), isOn: $showFileModifiedColumn)
                        Color.clear
                    }

                    GridRow {
                        Toggle(L10n.text("column.created"), isOn: $showFileCreatedColumn)
                        Color.clear
                    }
                }
            }
        }
        .formStyle(.grouped)
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

    private func refreshSevenZipVersion() {
        let checkingText = L10n.text("settings.7zip.checking")
        DispatchQueue.main.async {
            sevenZipVersion = checkingText
        }
        Task {
            let version = await ArchiveService.sevenZipVersion()
            DispatchQueue.main.async {
                sevenZipVersion = version
            }
        }
    }

    private func refreshRarVersion() {
        let checkingText = L10n.text("settings.rar.checking")
        DispatchQueue.main.async {
            rarVersion = checkingText
        }
        Task {
            let version = await ArchiveService.rarVersion()
            DispatchQueue.main.async {
                rarVersion = version
            }
        }
    }

    private func applyLanguage(_ rawValue: String) {
        let language = AppLanguage(rawValue: rawValue) ?? .system
        if let code = language.appleLanguageCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        let restartHint = L10n.text("settings.languageRestartHint")
        DispatchQueue.main.async {
            languageMessage = restartHint
        }
    }

    private func selectColumnsPane() {
        DispatchQueue.main.async {
            selectedPane = .columns
        }
    }
}

private enum SettingsPane: Hashable {
    case general
    case archive
    case browser
    case fileAssociations
    case columns
}

extension Notification.Name {
    static let requestOpenSettingsColumns = Notification.Name("SimpleZip.requestOpenSettingsColumns")
    static let openSettingsColumns = Notification.Name("SimpleZip.openSettingsColumns")
    static let browserPreferencesChanged = Notification.Name("SimpleZip.browserPreferencesChanged")
}

@MainActor
enum SettingsNavigation {
    private static var shouldOpenColumns = false

    static func requestOpenColumns() {
        if #available(macOS 14.0, *) {
            NotificationCenter.default.post(name: .requestOpenSettingsColumns, object: nil)
        } else {
            openColumnsLegacy()
        }
    }

    static func prepareOpenColumns() {
        shouldOpenColumns = true
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openSettingsColumns, object: nil)
        }
    }

    static func openColumnsLegacy() {
        prepareOpenColumns()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    static func consumePendingColumnsRequest() -> Bool {
        defer { shouldOpenColumns = false }
        return shouldOpenColumns
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

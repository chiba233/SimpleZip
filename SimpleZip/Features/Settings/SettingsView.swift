//
//  SettingsView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI
import AppKit

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
    @State private var isSevenZipMissing = false
    @State private var rarVersion = L10n.text("settings.rar.checking")
    @State private var isRarMissing = false
    @State private var hasLocalRarBackend = false
    @State private var isInstallingRar = false
    @State private var rarInstallReview: RarInstallReview?
    @State private var hasReadRarLicense = false
    @State private var hasReadRarReadme = false
    @State private var systemInstallMessage: String?
    @State private var rarInstallMessage: String?
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
        .controlSize(.small)
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

                if shouldShowSevenZipSystemInstallPrompt {
                    SystemInstallCommandView(
                        title: L10n.text("settings.systemInstall.7zip.title"),
                        command: "brew install sevenzip",
                        message: $systemInstallMessage,
                        copyCommand: copySystemInstallCommand,
                        copyAndOpenTerminal: copySystemInstallCommandAndOpenTerminal
                    )
                }
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

                if shouldShowRarControls {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(rarControlsPrompt)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Button {
                                    openRarInstallReadme()
                                } label: {
                                    Label(L10n.text("settings.rar.openReadme"), systemImage: "doc.text")
                                }

                                Button {
                                    revealRarInstallFiles()
                                } label: {
                                    Label(L10n.text("settings.rar.revealInstallFiles"), systemImage: "folder")
                                }
                            }

                            HStack {
                                Button {
                                    beginRarInstallReview(.install)
                                } label: {
                                    Label(L10n.text("settings.rar.runInstaller"), systemImage: "arrow.down.circle")
                                }
                                .disabled(isInstallingRar || hasLocalRarBackend)

                                Button {
                                    beginRarInstallReview(.update)
                                } label: {
                                    Label(L10n.text("settings.rar.updateBackend"), systemImage: "arrow.triangle.2.circlepath")
                                }
                                .disabled(isInstallingRar || !hasLocalRarBackend)

                                Button(role: .destructive) {
                                    deleteLocalRarBackend()
                                } label: {
                                    Label(L10n.text("settings.rar.deleteBackend"), systemImage: "trash")
                                }
                                .disabled(isInstallingRar || !hasLocalRarBackend)
                            }
                        }

                        if let rarInstallMessage {
                            Text(rarInstallMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if shouldShowRarSystemInstallPrompt {
                    SystemInstallCommandView(
                        title: L10n.text("settings.systemInstall.rar.title"),
                        command: "brew install --cask rar",
                        message: $systemInstallMessage,
                        copyCommand: copySystemInstallCommand,
                        copyAndOpenTerminal: copySystemInstallCommandAndOpenTerminal
                    )
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .sheet(item: $rarInstallReview) { review in
            rarInstallReviewSheet(review)
        }
    }

    private var shouldShowRarControls: Bool {
        let selectedBackend = RarBackend(rawValue: rarBackend)
        guard selectedBackend == .automatic || selectedBackend == .bundled else {
            return false
        }
        return isRarMissing || hasLocalRarBackend
    }

    private var shouldShowSevenZipSystemInstallPrompt: Bool {
        SevenZipBackend(rawValue: sevenZipBackend) == .system && isSevenZipMissing
    }

    private var shouldShowRarSystemInstallPrompt: Bool {
        RarBackend(rawValue: rarBackend) == .system && isRarMissing
    }

    private var rarControlsPrompt: String {
        hasLocalRarBackend ? L10n.text("settings.rar.localBackendPrompt") : L10n.text("settings.rar.installPrompt")
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
                                .buttonStyle(.bordered)
                                .disabled(normalizedSuffix.isEmpty || blockedSuffixes.contains(normalizedSuffix))
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 6)
                    .disabled(!hiddenSuffixesEnabled)
                } label: {
                    Toggle(L10n.text("settings.hiddenSuffixes"), isOn: $hiddenSuffixesEnabled)
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
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
        .controlSize(.small)
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

            Section(L10n.text("settings.columns.preview")) {
                VStack(alignment: .leading, spacing: 14) {
                    ColumnsPreviewTable(
                        title: L10n.text("settings.columns.fileBrowser"),
                        columns: fileColumnPreview
                    )
                    ColumnsPreviewTable(
                        title: L10n.text("settings.columns.archiveBrowser"),
                        columns: archiveColumnPreview
                    )
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
    }

    private var fileColumnPreview: [ColumnPreview] {
        var columns: [FileColumn] = [.name]
        if showFileSizeColumn { columns.append(.size) }
        if showFileTypeColumn { columns.append(.type) }
        if showFileApplicationColumn { columns.append(.application) }
        if showFileLastOpenedColumn { columns.append(.lastOpened) }
        if showFileDateAddedColumn { columns.append(.dateAdded) }
        if showFileModifiedColumn { columns.append(.modified) }
        if showFileCreatedColumn { columns.append(.created) }

        return orderedColumns(columns, key: AppPreferences.Key.fileColumnOrder).map { column in
            ColumnPreview(title: column.title, value: filePreviewValue(for: column), preferredWidth: previewWidth(for: column))
        }
    }

    private var archiveColumnPreview: [ColumnPreview] {
        var columns: [ArchiveColumn] = [.name]
        if showArchiveKindColumn { columns.append(.kind) }
        if showArchiveSizeColumn { columns.append(.size) }
        if showArchiveModifiedColumn { columns.append(.modified) }
        if showArchiveMethodColumn { columns.append(.method) }

        return orderedColumns(columns, key: AppPreferences.Key.archiveColumnOrder).map { column in
            ColumnPreview(title: column.title, value: archivePreviewValue(for: column), preferredWidth: previewWidth(for: column))
        }
    }

    private func filePreviewValue(for column: FileColumn) -> String {
        switch column {
        case .name:
            return "Project.zip"
        case .size:
            return "12.4 MB"
        case .type:
            return "ZIP Archive"
        case .application:
            return "SimpleZip"
        case .lastOpened:
            return "May 29, 2026"
        case .dateAdded:
            return "May 28, 2026"
        case .modified:
            return "May 27, 2026"
        case .created:
            return "May 20, 2026"
        }
    }

    private func archivePreviewValue(for column: ArchiveColumn) -> String {
        switch column {
        case .name:
            return "Documents/"
        case .kind:
            return "Folder"
        case .size:
            return "42 KB"
        case .modified:
            return "2026-05-29 10:30"
        case .method:
            return "Deflate"
        }
    }

    private func previewWidth(for column: FileColumn) -> CGFloat {
        switch column {
        case .name:
            return 170
        case .size:
            return 86
        case .type, .application:
            return 128
        case .lastOpened, .dateAdded, .modified, .created:
            return 136
        }
    }

    private func previewWidth(for column: ArchiveColumn) -> CGFloat {
        switch column {
        case .name:
            return 170
        case .kind:
            return 110
        case .size, .method:
            return 86
        case .modified:
            return 140
        }
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
            isSevenZipMissing = !ArchiveService.canUseSevenZip()
        }
        Task {
            let version = await ArchiveService.sevenZipVersion()
            DispatchQueue.main.async {
                sevenZipVersion = version
                isSevenZipMissing = !ArchiveService.canUseSevenZip()
            }
        }
    }

    private func refreshRarVersion() {
        let checkingText = L10n.text("settings.rar.checking")
        DispatchQueue.main.async {
            rarVersion = checkingText
            isRarMissing = !ArchiveService.canCreateRAR()
            hasLocalRarBackend = ArchiveService.hasLocalRarBackend()
        }
        Task {
            let version = await ArchiveService.rarVersion()
            DispatchQueue.main.async {
                rarVersion = version
                isRarMissing = !ArchiveService.canCreateRAR()
                hasLocalRarBackend = ArchiveService.hasLocalRarBackend()
            }
        }
    }

    private func openRarInstallReadme() {
        guard let readmeURL = ArchiveService.rarInstallReadmeURL() else {
            rarInstallMessage = L10n.text("settings.rar.installFilesMissing")
            return
        }
        guard FileManager.default.fileExists(atPath: readmeURL.path) else {
            rarInstallMessage = L10n.text("settings.rar.installFilesMissing")
            return
        }
        NSWorkspace.shared.open(readmeURL)
    }

    private func revealRarInstallFiles() {
        guard let resourcesURL = ArchiveService.rarInstallResourcesURL() else {
            rarInstallMessage = L10n.text("settings.rar.installFilesMissing")
            return
        }
        guard FileManager.default.fileExists(atPath: resourcesURL.path) else {
            rarInstallMessage = L10n.text("settings.rar.installFilesMissing")
            return
        }
        let installFiles = [
            ArchiveService.rarInstallReadmeURL(),
            ArchiveService.rarInstallLicenseURL(),
            ArchiveService.rarInstallerScriptURL()
        ].compactMap { $0 }
        NSWorkspace.shared.activateFileViewerSelecting(installFiles.isEmpty ? [resourcesURL] : installFiles)
    }

    private func beginRarInstallReview(_ action: RarInstallAction) {
        guard let licenseURL = ArchiveService.rarInstallLicenseURL(),
              let readmeURL = ArchiveService.rarInstallReadmeURL()
        else {
            rarInstallMessage = L10n.text("settings.rar.installFilesMissing")
            return
        }

        do {
            let licenseText = try String(contentsOf: licenseURL, encoding: .utf8)
            let readmeText = try String(contentsOf: readmeURL, encoding: .utf8)
            hasReadRarLicense = false
            hasReadRarReadme = false
            let review = RarInstallReview(action: action, licenseText: licenseText, readmeText: readmeText)
            DispatchQueue.main.async {
                rarInstallReview = review
            }
        } catch {
            rarInstallMessage = L10n.format("settings.rar.installFailedWithOutput", error.localizedDescription)
        }
    }

    private func runRarInstaller(action: RarInstallAction) {
        guard let installerURL = ArchiveService.rarInstallerScriptURL() else {
            rarInstallMessage = L10n.text("settings.rar.installFilesMissing")
            return
        }
        guard FileManager.default.fileExists(atPath: installerURL.path) else {
            rarInstallMessage = L10n.text("settings.rar.installFilesMissing")
            return
        }

        isInstallingRar = true
        rarInstallReview = nil
        rarInstallMessage = action == .install ? L10n.text("settings.rar.installing") : L10n.text("settings.rar.updating")

        Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [installerURL.path]
            process.currentDirectoryURL = installerURL.deletingLastPathComponent()
            process.standardOutput = output
            process.standardError = output

            do {
                try process.run()
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self)
                    .split(separator: "\n")
                    .suffix(4)
                    .joined(separator: "\n")

                DispatchQueue.main.async {
                    isInstallingRar = false
                    refreshRarVersion()
                    if process.terminationStatus == 0 {
                        rarInstallMessage = action == .install ? L10n.text("settings.rar.installSucceeded") : L10n.text("settings.rar.updateSucceeded")
                    } else if text.isEmpty {
                        rarInstallMessage = L10n.text("settings.rar.installFailed")
                    } else {
                        rarInstallMessage = L10n.format("settings.rar.installFailedWithOutput", text)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isInstallingRar = false
                    rarInstallMessage = L10n.format("settings.rar.installFailedWithOutput", error.localizedDescription)
                }
            }
        }
    }

    private func deleteLocalRarBackend() {
        do {
            try ArchiveService.deleteLocalRarBackend()
            refreshRarVersion()
            rarInstallMessage = L10n.text("settings.rar.deleteSucceeded")
        } catch {
            rarInstallMessage = L10n.format("settings.rar.deleteFailedWithOutput", error.localizedDescription)
        }
    }

    private func copySystemInstallCommand(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        systemInstallMessage = L10n.format("settings.systemInstall.copied", command)
    }

    private func copySystemInstallCommandAndOpenTerminal(_ command: String) {
        copySystemInstallCommand(command)
        if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open(terminalURL)
        }
    }

    @ViewBuilder
    private func rarInstallReviewSheet(_ review: RarInstallReview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(review.action.title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                RarInstallDocumentView(
                    title: L10n.text("settings.rar.licenseHeading"),
                    text: review.licenseText,
                    checkboxTitle: L10n.text("settings.rar.licenseReadCheckbox"),
                    isRead: $hasReadRarLicense
                )

                RarInstallDocumentView(
                    title: L10n.text("settings.rar.readmeHeading"),
                    text: review.readmeText,
                    checkboxTitle: L10n.text("settings.rar.readmeReadCheckbox"),
                    isRead: $hasReadRarReadme
                )
            }

            HStack {
                Spacer()
                Button(L10n.text("button.cancel")) {
                    rarInstallReview = nil
                }
                Button(review.action.confirmButtonTitle) {
                    runRarInstaller(action: review.action)
                }
                .disabled(!hasReadRarLicense || !hasReadRarReadme || isInstallingRar)
            }
        }
        .padding(20)
        .frame(width: 680, height: 620)
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

private enum RarInstallAction: String, Identifiable {
    case install
    case update

    var id: String { rawValue }

    var title: String {
        switch self {
        case .install:
            return L10n.text("settings.rar.installReviewTitle")
        case .update:
            return L10n.text("settings.rar.updateReviewTitle")
        }
    }

    var confirmButtonTitle: String {
        switch self {
        case .install:
            return L10n.text("settings.rar.downloadAndInstall")
        case .update:
            return L10n.text("settings.rar.downloadAndUpdate")
        }
    }
}

private struct RarInstallReview: Identifiable {
    let id = UUID()
    let action: RarInstallAction
    let licenseText: String
    let readmeText: String
}

private enum SettingsPane: Hashable {
    case general
    case archive
    case browser
    case fileAssociations
    case columns
}

private struct ColumnPreview: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let preferredWidth: CGFloat
}

private struct ColumnsPreviewTable: View {
    let title: String
    let columns: [ColumnPreview]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(columns) { column in
                            previewCell(column.title, column: column, isHeader: true)
                        }
                    }
                    Divider()
                    HStack(spacing: 0) {
                        ForEach(columns) { column in
                            previewCell(column.value, column: column, isHeader: false)
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .background(.background)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary)
                }
            }
            .frame(height: 68)
        }
    }

    private func previewCell(_ text: String, column: ColumnPreview, isHeader: Bool) -> some View {
        Text(text)
            .font(isHeader ? .caption.weight(.semibold) : .caption)
            .foregroundStyle(isHeader ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: column.preferredWidth, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: isHeader ? 28 : 34, alignment: .center)
            .background(isHeader ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            .overlay(alignment: .trailing) {
                Divider()
            }
    }
}

private struct SystemInstallCommandView: View {
    let title: String
    let command: String
    @Binding var message: String?
    let copyCommand: (String) -> Void
    let copyAndOpenTerminal: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                Button {
                    copyCommand(command)
                } label: {
                    Label(L10n.text("settings.systemInstall.copy"), systemImage: "doc.on.doc")
                }

                Button {
                    copyAndOpenTerminal(command)
                } label: {
                    Label(L10n.text("settings.systemInstall.copyAndOpenTerminal"), systemImage: "terminal")
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RarInstallDocumentView: View {
    let title: String
    let text: String
    let checkboxTitle: String
    @Binding var isRead: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.quaternary)
            }
                .frame(minHeight: 190)

            Toggle(checkboxTitle, isOn: $isRead)
        }
    }
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
        .controlSize(.small)
    }
}

//
//  ContentView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 主窗口视图：只负责把侧边栏、工具栏、列表和状态栏组合在一起。
struct ContentView: View {
    @StateObject private var model = ArchiveBrowserModel()
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                TopBar(model: model)

                Divider()

                if case .archive = model.mode {
                    ArchiveTable(model: model)
                } else {
                    FileTable(model: model)
                }

                Divider()
                StatusBar(model: model)
            }
            .frame(minWidth: 620)
            .navigationTitle(model.title)
        }
        .frame(minWidth: 980, minHeight: 620)
        .focusedSceneObject(model)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(8)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            receiveDroppedFileURLs(from: providers)
        }
        .alert(L10n.text("alert.operationFailed"), isPresented: Binding(get: {
            model.isShowingOperationFailureAlert
        }, set: { newValue in
            if !newValue { model.dismissOperationFailureAlert() }
        })) {
            if model.operationDetailsSession != nil {
                Button(L10n.text("button.details")) {
                    model.openOperationDetailsFromFailureAlert()
                }
            }
            Button(L10n.text("button.ok"), role: .cancel) { model.dismissOperationFailureAlert() }
        } message: {
            Text(model.operationFailurePreviewMessage)
        }
        .sheet(isPresented: Binding(get: {
            model.isShowingOperationDetails && model.operationDetailsSession != nil
        }, set: { newValue in
            model.handleOperationDetailsPresentationChange(newValue)
        })) {
            if let session = model.operationDetailsSession {
                ArchiveOperationDetailsView(session: session) {
                    model.closeOperationDetails()
                }
            }
        }
        .sheet(item: $model.hashReport) { report in
            HashResultsView(report: report) {
                model.hashReport = nil
            }
        }
        .sheet(item: $model.benchmarkRequest) { request in
            BenchmarkOptionsView(request: request) { confirmedRequest in
                model.benchmarkRequest = nil
                model.runSevenZipBenchmark(confirmedRequest)
            } cancel: {
                model.benchmarkRequest = nil
            }
        }
        .sheet(item: $model.benchmarkSession) { session in
            BenchmarkRunView(session: session) {
                if session.isRunning {
                    model.cancelCurrentOperation()
                }
                model.benchmarkSession = nil
            }
        }
        .sheet(item: $model.archiveCreationRequest) { request in
            ArchiveCreationOptionsView(request: request) { confirmedRequest in
                model.archiveCreationRequest = nil
                model.performCreateArchive(confirmedRequest)
            } cancel: {
                model.archiveCreationRequest = nil
            }
        }
        .sheet(item: $model.extractSelectionRequest) { request in
            ExtractSelectionOptionsView(request: request) { confirmedRequest in
                model.extractSelectionRequest = nil
                model.performExtractSelection(confirmedRequest)
            } cancel: {
                model.extractSelectionRequest = nil
            }
        }
        .sheet(item: $model.extractArchiveRequest) { request in
            ExtractArchiveOptionsView(request: request) { confirmedRequest in
                model.extractArchiveRequest = nil
                model.performExtractArchive(confirmedRequest)
            } cancel: {
                model.extractArchiveRequest = nil
            }
        }
        .onAppear {
            ExternalFileOpenQueue.shared.drain().forEach(openExternalURL)
        }
        .onOpenURL { url in
            openExternalURL(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openExternalFile)) { _ in
            ExternalFileOpenQueue.shared.drain().forEach(openExternalURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserPreferencesChanged)) { _ in
            model.reload()
        }
        .background {
            if #available(macOS 14.0, *) {
                SettingsRequestBridge()
            }
        }
    }

    /// 处理 Finder / Open With / 拖到 Dock 图标等外部打开事件。
    private func openExternalURL(_ url: URL) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            model.openFolder(url)
        } else if ArchiveService.isSupportedArchive(url) {
            model.openArchive(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func receiveDroppedFileURLs(from providers: [NSItemProvider]) -> Bool {
        let fileURLProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileURLProviders.isEmpty else { return false }

        var urls = Array<URL?>(repeating: nil, count: fileURLProviders.count)
        let lock = NSLock()
        let group = DispatchGroup()

        for (index, provider) in fileURLProviders.enumerated() {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }

                if let data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock()
                    urls[index] = url
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            model.openDroppedURLs(urls.compactMap { $0 })
        }

        return true
    }
}

@available(macOS 14.0, *)
private struct SettingsRequestBridge: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .requestOpenSettingsColumns)) { _ in
                SettingsNavigation.prepareOpenColumns()
                openSettings()
            }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

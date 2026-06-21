//
//  WebExtractSheet.swift
//  SimpleZip
//
//  地址栏输入网络归档 URL 时弹的独立「下载并解压」面板(不复用普通解压窗口)。打开即探测服务器是否真给一个
//  可流式的归档:URL + 文件名 + 「可流式解压 ✓/✗」;不支持就如实门控、不假装。✓ 后边下边解(整包不落盘)。
//

import AppKit
import SwiftUI

/// 地址栏触发的网络解压请求(sheet 自带探测 + 流式下载解压,自包含)。
struct WebExtractRequest: Identifiable {
    let id = UUID()
    let url: URL
    /// 默认解压目标(地址栏所在的当前文件夹);sheet 里可改。
    var destination: URL
}

struct WebExtractSheet: View {
    @State var request: WebExtractRequest
    /// 关闭回调:成功带回解出的目标 URL(供 app 内浏览器导航 + 选中,**不唤醒 Finder**);取消 / 失败为 nil。
    let onClose: (URL?) -> Void

    private enum Phase: Equatable {
        case probing
        case ready(WebArchiveProbeResult)
        case running
        case failed(String)
        case done(URL)
    }

    @State private var phase: Phase = .probing
    @State private var probe: WebArchiveProbeResult?
    @State private var keepArchive = false
    @State private var receivedBytes: Int64 = 0
    @State private var totalBytes: Int64 = -1
    @State private var runTask: Task<Void, Never>?
    private let coordinator = ArchiveExtractionCoordinator(fileManager: .default)

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "arrow.down.circle.fill",
                colors: [.blue, .indigo],
                title: L10n.text("webExtract.title"),
                subtitle: request.url.host
            )

            VStack(alignment: .leading, spacing: 16) {
                DialogSection {
                    infoRow(L10n.text("webExtract.url"), systemImage: "link", tint: .blue) {
                        Text(request.url.absoluteString)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    infoRow(L10n.text("webExtract.filename"), systemImage: "doc.fill", tint: .teal) {
                        Text(displayFilename)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    streamableRow
                }

                if isStreamable {
                    DialogSection {
                        infoRow(L10n.text("archive.destination"), systemImage: "folder.fill", tint: .blue) {
                            HStack(spacing: 8) {
                                Text(request.destination.path)
                                    .font(.caption).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                Button(L10n.text("button.choose"), action: chooseDestination)
                                    .disabled(phase == .running)
                            }
                        }
                        DialogToggleRow(
                            title: L10n.text("webExtract.keepArchive"),
                            subtitle: L10n.text("webExtract.keepArchive.detail"),
                            systemImage: "archivebox.fill",
                            tint: .orange,
                            pinsToTrailing: true,
                            isOn: $keepArchive
                        )
                        .disabled(phase == .running)
                    }
                }

                progressOrStatus
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()

            DialogFooter(
                confirmTitle: confirmTitle,
                confirmSystemImage: "arrow.down.circle",
                confirmDisabled: !canExtract,
                confirm: startExtraction,
                cancel: cancel
            ) {
                EmptyView()
            }
        }
        .frame(width: 540)
        .task { await runProbe() }
    }

    // MARK: - 行

    private var streamableRow: some View {
        infoRow(L10n.text("webExtract.streamable"), systemImage: "bolt.horizontal.fill", tint: .yellow) {
            switch phase {
            case .probing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("webExtract.probing")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            default:
                if isStreamable {
                    Label(L10n.text("webExtract.streamable.yes"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Label(L10n.text("webExtract.streamable.no"), systemImage: "xmark.circle.fill")
                            .foregroundStyle(.orange)
                        if let reason = probe?.unsupportedReason {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private var progressOrStatus: some View {
        switch phase {
        case .running:
            VStack(alignment: .leading, spacing: 6) {
                if totalBytes > 0 {
                    ProgressView(value: Double(receivedBytes), total: Double(max(1, totalBytes)))
                    Text(L10n.format("webExtract.progress",
                                     ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file),
                                     ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                    Text(L10n.format("webExtract.progress.unknown",
                                     ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .done:
            Label(L10n.text("webExtract.done"), systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        default:
            EmptyView()
        }
    }

    private func infoRow<Value: View>(_ title: String, systemImage: String, tint: Color,
                                      @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .center, spacing: 6) {
            DialogRowLabel(title, systemImage: systemImage, tint: tint, width: 110)
            Spacer(minLength: 12)
            value()
        }
    }

    // MARK: - 状态派生

    private var isStreamable: Bool { probe?.isStreamable == true }

    private var displayFilename: String {
        probe?.filename ?? (request.url.lastPathComponent.removingPercentEncoding ?? request.url.lastPathComponent)
    }

    private var canExtract: Bool {
        if case .running = phase { return false }
        if case .done = phase { return false }
        return isStreamable
    }

    private var confirmTitle: String {
        if case .running = phase { return L10n.text("webExtract.downloading") }
        return L10n.text("webExtract.extract")
    }

    // MARK: - 动作

    private func runProbe() async {
        let result = await WebArchiveStreamExtract.probe(request.url)
        probe = result
        phase = .ready(result)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = request.destination
        if panel.runModal() == .OK, let url = panel.url {
            request.destination = url
        }
    }

    private func startExtraction() {
        guard canExtract, let probe else { return }
        phase = .running
        receivedBytes = 0
        totalBytes = probe.byteCount ?? -1
        let url = request.url
        let filename = probe.filename
        let destination = request.destination
        let keep = keepArchive
        let coordinator = coordinator
        runTask = Task { @MainActor in
            do {
                let target = try await WebArchiveStreamExtract.run(
                    url: url, filename: filename, destination: destination, keepArchive: keep,
                    coordinator: coordinator,
                    onProgress: { received, total in
                        Task { @MainActor in applyProgress(received: received, total: total) }
                    })
                phase = .done(target)
                SystemSound.operationComplete?.play()
                // 不唤醒 Finder —— SimpleZip 自己就是文件浏览器,在 app 内导航 + 选中(见 onClose 回调)。
                try? await Task.sleep(nanoseconds: 800_000_000)
                onClose(target)
            } catch is CancellationError {
                onClose(nil)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// 进度按**整数百分比**(或未知总量时每 256KB)节流,避免高速下载每个 chunk 都刷 @State。
    private func applyProgress(received: Int64, total: Int64) {
        guard case .running = phase else { return }
        if total > 0 {
            let oldPercent = totalBytes > 0 ? receivedBytes * 100 / totalBytes : -1
            let newPercent = received * 100 / max(1, total)
            totalBytes = total
            if newPercent != oldPercent { receivedBytes = received }
        } else if received - receivedBytes >= 262_144 || receivedBytes == 0 {
            receivedBytes = received
        }
    }

    private func cancel() {
        if case .running = phase {
            runTask?.cancel()   // → URLSession task 取消 + bsdtar 终止 + 清理(见 WebArchiveStreamExtract）
        }
        onClose(nil)
    }
}

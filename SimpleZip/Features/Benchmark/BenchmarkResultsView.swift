//
//  BenchmarkResultsView.swift
//  SimpleZip
//
//  Created by Copilot on 2026/05/13.
//
//  0.4.1 现代化：跑分选项 / 跑分结果两个 sheet 套用 DialogChrome 体例
//  （DialogHero 渐变图标 + DialogSection 卡片 + 钉底 bar 操作栏），
//  结果页把压缩 / 解压速度做成大数字指标卡，原始输出收进默认折叠的 DialogDrawer。
//

import AppKit
import SwiftUI

struct BenchmarkOptionsView: View {
    @State var request: SevenZipBenchmarkRequest
    let start: (SevenZipBenchmarkRequest) -> Void
    let cancel: () -> Void

    private var maxThreadCount: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "speedometer",
                colors: [.purple, .indigo],
                title: L10n.text("benchmark.title"),
                subtitle: L10n.text("benchmark.hero.subtitle")
            )

            DialogSection {
                Stepper(value: $request.options.dictionarySizeMB, in: 1...256) {
                    HStack {
                        Text(L10n.text("benchmark.dictionarySize"))
                        Spacer()
                        Text("\(request.options.dictionarySizeMB) MB")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Stepper(value: $request.options.threadCount, in: 0...maxThreadCount) {
                    HStack {
                        Text(L10n.text("benchmark.threads"))
                        Spacer()
                        Text(request.options.threadCount == 0 ? L10n.text("archive.7z.threads.auto") : "\(request.options.threadCount)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()

            HStack {
                Spacer()
                Button(action: cancel) {
                    Label(L10n.text("button.cancel"), systemImage: "xmark")
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    start(request)
                } label: {
                    Label(L10n.text("button.benchmark"), systemImage: "speedometer")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 460)
    }
}

struct BenchmarkRunView: View {
    @ObservedObject var session: SevenZipBenchmarkSession
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "speedometer",
                colors: [.purple, .indigo],
                title: L10n.text("benchmark.title"),
                subtitle: session.report?.backendDescription
            )

            HeightCappedScrollView(maxHeight: 560) {
                VStack(alignment: .leading, spacing: 14) {
                    DialogSection {
                        infoRow(L10n.text("benchmark.dictionarySize"), "\(session.options.dictionarySizeMB) MB")
                        infoRow(L10n.text("benchmark.threads"), session.options.threadCount == 0 ? L10n.text("archive.7z.threads.auto") : "\(session.options.threadCount)")
                        infoRow(L10n.text("benchmark.elapsedTime"), elapsedTimeText)
                        if let threads = session.report?.benchmarkThreads {
                            infoRow(L10n.text("benchmark.backendThreads"), "\(threads)")
                        }
                        if let totalRating = session.report?.totalRatingMips {
                            infoRow(L10n.text("benchmark.totalRating"), "\(totalRating.formatted()) MIPS")
                        }
                    }

                    metricSection(
                        title: L10n.text("benchmark.current"),
                        metrics: currentMetrics,
                        dictionaryBits: session.report?.dictionaryRows.last?.dictionaryBits
                    )
                    metricSection(title: L10n.text("benchmark.average"), metrics: averageMetrics, dictionaryBits: nil)

                    DialogDrawer(L10n.text("benchmark.rawOutput"), systemImage: "terminal", color: .gray) {
                        ScrollView {
                            Text(session.rawOutput.isEmpty ? L10n.text("benchmark.waiting") : session.rawOutput)
                                .font(.system(.callout, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(10)
                        }
                        .frame(minHeight: 140, maxHeight: 260)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.07))
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                if session.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("benchmark.waiting"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(session.isRunning ? L10n.text("button.cancel") : L10n.text("button.ok")) {
                    close()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(minWidth: 620, idealWidth: 680)
    }

    private var averageMetrics: (SevenZipBenchmarkMetrics?, SevenZipBenchmarkMetrics?) {
        (session.report?.compressionAverage, session.report?.decompressionAverage)
    }

    private var currentMetrics: (SevenZipBenchmarkMetrics?, SevenZipBenchmarkMetrics?) {
        guard let latest = session.report?.dictionaryRows.last else { return (nil, nil) }
        return (latest.compression, latest.decompression)
    }

    private var elapsedTimeText: String {
        let end = session.finishedAt ?? Date()
        let interval = end.timeIntervalSince(session.startedAt)
        return String(format: "%.3f s", interval)
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.callout)
    }

    /// 一组（当前 / 平均）指标：压缩、解压各一张大数字卡片并排。
    @ViewBuilder
    private func metricSection(title: String, metrics: (SevenZipBenchmarkMetrics?, SevenZipBenchmarkMetrics?), dictionaryBits: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let dictionaryBits {
                    Text("2^\(dictionaryBits)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 2)
            HStack(spacing: 10) {
                metricCard(
                    title: L10n.text("benchmark.compressing"),
                    systemImage: "arrow.down.circle.fill",
                    color: .blue,
                    metrics: metrics.0
                )
                metricCard(
                    title: L10n.text("benchmark.decompressing"),
                    systemImage: "arrow.up.circle.fill",
                    color: .green,
                    metrics: metrics.1
                )
            }
        }
    }

    /// 单张指标卡：速度做大数字主角,MIPS / CPU 占用做次行说明。
    @ViewBuilder
    private func metricCard(title: String, systemImage: String, color: Color, metrics: SevenZipBenchmarkMetrics?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(color)
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
            }
            if let metrics {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(metrics.speedKiBPerSecond.formatted())
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("KiB/s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(metrics.ratingMips.formatted()) MIPS · \(metrics.usagePercent)% CPU")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.text("benchmark.waiting"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }
}

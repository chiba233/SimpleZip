//
//  BenchmarkResultsView.swift
//  SimpleZip
//
//  Created by Copilot on 2026/05/13.
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
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("benchmark.title"))
                .font(.title3.weight(.semibold))

            Form {
                Stepper(value: $request.options.dictionarySizeMB, in: 1...256) {
                    HStack {
                        Text(L10n.text("benchmark.dictionarySize"))
                        Spacer()
                        Text("\(request.options.dictionarySizeMB) MB")
                            .foregroundStyle(.secondary)
                    }
                }

                Stepper(value: $request.options.threadCount, in: 0...maxThreadCount) {
                    HStack {
                        Text(L10n.text("benchmark.threads"))
                        Spacer()
                        Text(request.options.threadCount == 0 ? L10n.text("archive.7z.threads.auto") : "\(request.options.threadCount)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button(L10n.text("button.cancel"), action: cancel)
                Button(L10n.text("button.benchmark")) {
                    start(request)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct BenchmarkRunView: View {
    @ObservedObject var session: SevenZipBenchmarkSession
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("benchmark.title"))
                        .font(.title2.weight(.semibold))
                    if let backend = session.report?.backendDescription {
                        Text(backend)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Button(session.isRunning ? L10n.text("button.cancel") : L10n.text("button.ok")) {
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                detailRow(L10n.text("benchmark.dictionarySize"), "\(session.options.dictionarySizeMB) MB")
                detailRow(L10n.text("benchmark.threads"), session.options.threadCount == 0 ? L10n.text("archive.7z.threads.auto") : "\(session.options.threadCount)")
                detailRow(L10n.text("benchmark.elapsedTime"), elapsedTimeText)
                if let threads = session.report?.benchmarkThreads {
                    detailRow(L10n.text("benchmark.backendThreads"), "\(threads)")
                }
                if let totalRating = session.report?.totalRatingMips {
                    detailRow(L10n.text("benchmark.totalRating"), "\(totalRating) MIPS")
                }
            }

            metricSection(title: L10n.text("benchmark.current"), metrics: currentMetrics, dictionaryBits: session.report?.dictionaryRows.last?.dictionaryBits)
            metricSection(title: L10n.text("benchmark.average"), metrics: averageMetrics, dictionaryBits: nil)

            Text(L10n.text("benchmark.rawOutput"))
                .font(.headline)

            ScrollView {
                Text(session.rawOutput.isEmpty ? L10n.text("benchmark.waiting") : session.rawOutput)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor))
            )
        }
        .padding(20)
        .frame(minWidth: 780, idealWidth: 900, minHeight: 560, idealHeight: 700)
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
    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
        }
    }

    @ViewBuilder
    private func metricSection(title: String, metrics: (SevenZipBenchmarkMetrics?, SevenZipBenchmarkMetrics?), dictionaryBits: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                if let dictionaryBits {
                    Text("2^\(dictionaryBits)")
                        .foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                detailRow(L10n.text("benchmark.compressing"), metricText(metrics.0))
                detailRow(L10n.text("benchmark.decompressing"), metricText(metrics.1))
            }
        }
    }

    private func metricText(_ metrics: SevenZipBenchmarkMetrics?) -> String {
        guard let metrics else { return L10n.text("benchmark.waiting") }
        return "\(metrics.speedKiBPerSecond) KiB/s · \(metrics.ratingMips) MIPS · \(metrics.usagePercent)% CPU"
    }
}

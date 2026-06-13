//
//  CompressionEstimatorTests.swift
//  SimpleZipCoreTests
//
//  #12 压缩率预估:可压数据估出 <原大小、随机数据估≈原大小、store/tar 不压、外推按比例。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct CompressionEstimatorTests {
    @Test func compressibleDataEstimatesSmaller() {
        let sample = Data(repeating: 0x41, count: 100_000)   // 全 'A',高度可压
        let size = CompressionEstimator.compressedSampleSize(of: sample, format: .zip, level: 5)
        #expect(size != nil)
        #expect((size ?? .max) < sample.count)               // 明显小于原样本
    }

    @Test func incompressibleDataEstimatesAboutSame() {
        // 伪随机(确定性)数据基本压不动 → 压后 ≈ 原大小(不夸大压缩)。
        var bytes = [UInt8](repeating: 0, count: 50_000)
        var state: UInt32 = 0x12345678
        for index in bytes.indices {
            state = state &* 1_103_515_245 &+ 12345
            bytes[index] = UInt8((state >> 16) & 0xFF)
        }
        let sample = Data(bytes)
        let size = CompressionEstimator.compressedSampleSize(of: sample, format: .sevenZip, level: 9) ?? 0
        #expect(size >= sample.count * 9 / 10)               // 不可能压到原来的 90% 以下
    }

    @Test func storeLevelDoesNotCompress() {
        let sample = Data(repeating: 0x41, count: 10_000)
        #expect(CompressionEstimator.compressedSampleSize(of: sample, format: .zip, level: 0) == sample.count)
    }

    @Test func tarFormatDoesNotCompress() {
        let sample = Data(repeating: 0x41, count: 10_000)
        #expect(CompressionEstimator.algorithm(for: .tar) == nil)
        #expect(CompressionEstimator.compressedSampleSize(of: sample, format: .tar, level: 9) == sample.count)
    }

    @Test func emptySampleReturnsNil() {
        #expect(CompressionEstimator.compressedSampleSize(of: Data(), format: .zip, level: 5) == nil)
    }

    @Test func extrapolationScalesByRatio() {
        // 样本压一半 → 1000 字节估 500。
        #expect(CompressionEstimator.estimatedTotal(totalBytes: 1000, sampleBytes: 200, compressedSample: 100) == 500)
        #expect(CompressionEstimator.estimatedTotal(totalBytes: 1000, sampleBytes: 0, compressedSample: 0) == nil)
    }
}

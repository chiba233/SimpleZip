//
//  CompressionEstimator.swift
//  SimpleZip
//
//  0.4.4 #12:创建对话框的压缩率**预估**。用 Apple 的 Compression 框架把一份样本压一遍,按比例外推到
//  整个选区,给用户一个「大概压到多大」的参考。
//
//  诚实定位:这是**估算**,不是实际产物 —— 后端 7zz 用的算法 / 级别与这里不完全一致,样本也只是一部分。
//  对 ZIP(deflate≈zlib)较准,对 7z/xz(用 LZMA 代理)是趋势参考。展示时务必标明「预估」。
//

import Compression
import Foundation

nonisolated enum CompressionEstimator {
    /// 与目标格式相近的取样压缩算法;nil = 该格式不压缩(如 tar),预估 = 原大小。
    static func algorithm(for format: ArchiveCreateFormat) -> compression_algorithm? {
        switch format {
        case .zip, .gzip, .tarGzip:
            return COMPRESSION_ZLIB              // deflate 系
        case .sevenZip, .xz, .rar, .bzip2:
            return COMPRESSION_LZMA              // 强压缩代理
        case .tar, .dmg:
            return nil                           // 不压缩 / 不适用
        }
    }

    /// 把样本按格式相近算法压一遍,返回压后字节数。`level == 0`(仅存储)或不压缩格式 → 返回原样本大小。
    /// 样本为空返回 nil(无法估算)。
    static func compressedSampleSize(of sample: Data, format: ArchiveCreateFormat, level: Int) -> Int? {
        guard !sample.isEmpty else { return nil }
        guard level > 0, let algorithm = algorithm(for: format) else { return sample.count }
        return encodedSize(of: sample, algorithm: algorithm) ?? sample.count
    }

    /// 由样本压缩比外推整个选区的预估压后大小。`sampleBytes`/`compressedSample` 来自 `compressedSampleSize`。
    static func estimatedTotal(totalBytes: Int64, sampleBytes: Int, compressedSample: Int) -> Int64? {
        guard sampleBytes > 0, totalBytes > 0 else { return nil }
        let ratio = Double(compressedSample) / Double(sampleBytes)
        return Int64((Double(totalBytes) * ratio).rounded())
    }

    private static func encodedSize(of data: Data, algorithm: compression_algorithm) -> Int? {
        let sourceCount = data.count
        let destinationCapacity = sourceCount + 4096   // 压不动时退化到接近原大小,留余量。
        var destination = [UInt8](repeating: 0, count: destinationCapacity)
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&destination, destinationCapacity, base, sourceCount, nil, algorithm)
        }
        // 返回 0 = 失败(目标缓冲不够,即数据压不缩)→ 当作不可压缩,用原大小(不夸大压缩率)。
        return written > 0 ? written : sourceCount
    }
}

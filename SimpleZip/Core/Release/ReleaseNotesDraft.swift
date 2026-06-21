//
//  ReleaseNotesDraft.swift
//  SimpleZip
//
//  0.4.4 #5:发布说明草稿生成 —— 把「下载 / 校验 / 验签」样板一键拼好,粘进 GitHub Release 就能用。
//  纯函数,SwiftPM 可测。输出固定英文:这是发布物材料(对下载者),与 VERIFY.md / CLI 同一口径,
//  不跟 UI 语言走。GPG 段由调用方把关(gpgEnabled && 实际签了才给材料;A4)。
//

import Foundation

nonisolated enum ReleaseNotesDraft {

    struct Inputs {
        var artifactName: String
        var versionLabel: String?
        var sha256: String?
        var fileCount: Int?
        var totalBytes: Int64?
        var testPassed: Bool?
        /// nil = 本次没启用可复现(或不知道)→ 不写该行;true 才写。
        var reproducible: Bool?
        var wroteChecksums: Bool
        /// 三件齐(容器名 / 公钥文件名 / 指纹)才出 GPG 验签段。
        var signedContainerName: String?
        var publicKeyFileName: String?
        var fingerprint: String?

        init(
            artifactName: String,
            versionLabel: String? = nil,
            sha256: String? = nil,
            fileCount: Int? = nil,
            totalBytes: Int64? = nil,
            testPassed: Bool? = nil,
            reproducible: Bool? = nil,
            wroteChecksums: Bool = false,
            signedContainerName: String? = nil,
            publicKeyFileName: String? = nil,
            fingerprint: String? = nil
        ) {
            self.artifactName = artifactName
            self.versionLabel = versionLabel
            self.sha256 = sha256
            self.fileCount = fileCount
            self.totalBytes = totalBytes
            self.testPassed = testPassed
            self.reproducible = reproducible
            self.wroteChecksums = wroteChecksums
            self.signedContainerName = signedContainerName
            self.publicKeyFileName = publicKeyFileName
            self.fingerprint = fingerprint
        }
    }

    static func make(_ inputs: Inputs) -> String {
        var lines: [String] = []
        if let version = inputs.versionLabel, !version.isEmpty {
            lines.append("# \(version)")
            lines.append("")
        }
        lines.append("## Downloads")
        lines.append("")
        if let sha256 = inputs.sha256 {
            lines.append("| File | SHA-256 |")
            lines.append("|---|---|")
            lines.append("| `\(inputs.artifactName)` | `\(sha256)` |")
        } else {
            lines.append("- `\(inputs.artifactName)`")
        }
        lines.append("")

        lines.append("## Verify your download")
        lines.append("")
        lines.append("```")
        lines.append("shasum -a 256 \(quotedIfNeeded(inputs.artifactName))")
        lines.append("```")
        if inputs.wroteChecksums {
            lines.append("")
            lines.append("Or verify everything at once with the shipped `SHA256SUMS`:")
            lines.append("")
            lines.append("```")
            lines.append("shasum -a 256 -c SHA256SUMS")
            lines.append("```")
        }
        lines.append("")

        // 发布检查摘要 + 可复现标记。
        var facts: [String] = []
        if inputs.testPassed == true {
            var fact = "Release inspection passed"
            if let count = inputs.fileCount, let bytes = inputs.totalBytes {
                fact += " (\(count) files, \(formattedBytes(bytes)))"
            }
            facts.append(fact + ".")
        }
        if inputs.reproducible == true {
            facts.append("Reproducible build: re-creating the archive from the same input yields the same SHA-256.")
        }
        if !facts.isEmpty {
            lines.append(contentsOf: facts.map { "- \($0)" })
            lines.append("")
        }

        // GPG 验签段:三件齐才出,复用 .szs 验证材料的现成文案(VERIFY.md 同源,不二抄)。
        if let container = inputs.signedContainerName,
           let publicKey = inputs.publicKeyFileName,
           let fingerprint = inputs.fingerprint {
            lines.append(SZSArchive.verifyInstructions(
                containerName: container,
                publicKeyFileName: publicKey,
                fingerprint: fingerprint
            ))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func quotedIfNeeded(_ name: String) -> String {
        name.contains(" ") ? "\"\(name)\"" : name
    }

    private static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

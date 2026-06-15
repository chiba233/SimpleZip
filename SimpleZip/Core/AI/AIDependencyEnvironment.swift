//
//  AIDependencyEnvironment.swift
//  SimpleZip
//
//  0.4.5 #80:依赖环境嗅探(白皮书 Feat 25「幽灵依赖与环境嗅探」)。从**非加密 marker 文件**确定性识别
//  归档 / 文件夹属于哪个生态(Node / SwiftPM / Python / Rust / Go / Java …),供 AI Lens 的 source 视角、
//  解压后下一步动作卡、源码包节点证据卡使用。模型只把生态事实润色成人话,不执行任何安装命令。
//
//  **安全规则**(白皮书原文):`.npmrc` / `.env` / `gradle.properties` 等只记录「存在」+ 字段名,**绝不读内容**;
//  不执行 npm install / pip install / mvn;不读锁文件全文。文本摘要复用 `AIFileContentSummary`(已先过
//  `AISensitiveRedactor`,命中过多 → mode=blocked)。纯函数、确定性,SwiftPM 可断言。
//

import Foundation

/// 受控依赖生态全集(稳定英文 token)。
nonisolated enum AIDependencyEcosystem: String, Codable, Equatable, CaseIterable, Sendable {
    case node
    case swiftPackage = "swift-package"
    case python
    case rust
    case go
    case java
    case ruby
    case php
    case dotnet
    case docker
}

/// 依赖环境的确定性事实。
nonisolated struct AIDependencyEnvironmentFacts: Codable, Equatable, Sendable {
    let sourceRef: AIContextSourceRef
    let markerFiles: [String]
    /// 已脱敏的安全 manifest 摘要(package.json / Package.swift 的字段名 / 短摘要)。
    let safeManifestSummaries: [AIFileContentSummary]
    let detectedEcosystems: [AIDependencyEcosystem]
    /// 可能含密钥的配置文件(只记存在,内容被屏蔽),如 `.npmrc` / `.env`。
    let blockedFiles: [String]

    init(sourceRef: AIContextSourceRef, markerFiles: [String],
         safeManifestSummaries: [AIFileContentSummary] = [],
         detectedEcosystems: [AIDependencyEcosystem], blockedFiles: [String] = []) {
        self.sourceRef = sourceRef
        self.markerFiles = markerFiles
        self.safeManifestSummaries = safeManifestSummaries
        self.detectedEcosystems = detectedEcosystems
        self.blockedFiles = blockedFiles
    }
}

/// 依赖环境卡。`title`/`body` 模型润色(确定性版 nil → App 按 ecosystem 做 L10n)。
nonisolated struct AIDependencyEnvironmentCard: Codable, Equatable, Sendable {
    let ecosystem: AIDependencyEcosystem
    let title: String?
    let body: String?
    /// 运行要求(如 `node>=24`),由模型从 manifest 摘要提取;确定性版为空。
    let requirements: [String]
    /// 注意点(如 `.npmrc present but content blocked`)。
    let cautions: [String]
    let evidence: [AIEvidenceFact]

    init(ecosystem: AIDependencyEcosystem, title: String? = nil, body: String? = nil,
         requirements: [String] = [], cautions: [String] = [], evidence: [AIEvidenceFact] = []) {
        self.ecosystem = ecosystem
        self.title = title
        self.body = body
        self.requirements = requirements
        self.cautions = cautions
        self.evidence = evidence
    }
}

nonisolated enum AIDependencyEnvironmentDetector {
    /// marker basename(小写)→ 生态。后缀类(`.csproj`)单独判。
    private static let markerToEcosystem: [String: AIDependencyEcosystem] = [
        "package.swift": .swiftPackage,
        "package.json": .node,
        "pyproject.toml": .python, "requirements.txt": .python, "setup.py": .python, "pipfile": .python,
        "cargo.toml": .rust,
        "go.mod": .go,
        "pom.xml": .java, "build.gradle": .java, "build.gradle.kts": .java,
        "gemfile": .ruby,
        "composer.json": .php,
        "dockerfile": .docker,
    ]

    /// 可能含密钥的配置文件 basename(小写)—— 只记存在,绝不读内容。
    private static let sensitiveConfigBasenames: Set<String> = [
        ".npmrc", ".env", "gradle.properties", ".netrc", ".pypirc", ".dockercfg",
    ]

    /// 从一组文件名(或路径)识别生态。去重,按 `allCases` 顺序确定性返回。
    static func ecosystems(forFiles files: [String]) -> [AIDependencyEcosystem] {
        var found = Set<AIDependencyEcosystem>()
        for file in files {
            let base = (file as NSString).lastPathComponent.lowercased()
            if let eco = markerToEcosystem[base] { found.insert(eco) }
            let ext = (base as NSString).pathExtension
            if ext == "csproj" || ext == "sln" { found.insert(.dotnet) }
        }
        return AIDependencyEcosystem.allCases.filter { found.contains($0) }
    }

    /// 从文件名里挑出敏感配置(原名保留,按出现去重保序)。
    static func blockedConfigFiles(in files: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for file in files {
            let base = (file as NSString).lastPathComponent
            if sensitiveConfigBasenames.contains(base.lowercased()), seen.insert(base).inserted {
                result.append(base)
            }
        }
        return result
    }

    /// 组装确定性事实。
    static func makeFacts(sourceRef: AIContextSourceRef, files: [String],
                          manifestSummaries: [AIFileContentSummary] = []) -> AIDependencyEnvironmentFacts {
        AIDependencyEnvironmentFacts(
            sourceRef: sourceRef,
            markerFiles: files.filter { markerToEcosystem[($0 as NSString).lastPathComponent.lowercased()] != nil
                || ["csproj", "sln"].contains(($0 as NSString).pathExtension.lowercased()) },
            safeManifestSummaries: manifestSummaries,
            detectedEcosystems: ecosystems(forFiles: files),
            blockedFiles: blockedConfigFiles(in: files))
    }

    /// 确定性环境卡(无模型也工作):每个生态一张,evidence = marker,cautions = 屏蔽的配置文件。
    static func deterministicCards(from facts: AIDependencyEnvironmentFacts) -> [AIDependencyEnvironmentCard] {
        facts.detectedEcosystems.map { eco in
            AIDependencyEnvironmentCard(
                ecosystem: eco,
                cautions: facts.blockedFiles.map { "\($0) present but content blocked" },
                evidence: [AIEvidenceFact(label: "marker", facts: facts.markerFiles, sourceRef: facts.sourceRef)])
        }
    }
}

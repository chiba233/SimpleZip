//
//  AIVirtualFolderPlanTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80 #89:AI 文件夹虚拟目录树 plan + builder(白皮书建议四「数据结构必须这样落地」)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIVirtualFolderPlanTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let wsID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    private func workspace(title: String = "我的论文", prompt: String? = "准备论文答辩") -> AIWorkspace {
        AIWorkspace(id: wsID, origin: .recommended, title: title, prompt: prompt,
                    queryPlan: AIWorkspaceQueryPlan(taskTags: ["t"], keywords: ["paper"]),
                    iconSystemName: "sparkles", generatedAt: now)
    }

    private func fileCandidate(_ id: String, role: String, name: String) -> AIVirtualNodeCandidate {
        AIVirtualNodeCandidate(id: id, kind: .file, displayName: name,
                               sourceRefs: [AIContextSourceRef(kind: .file, id: "fs-" + id)],
                               roleTags: [role], scoreSignals: ["same-parent:paper"])
    }

    // MARK: - 确定性 plan

    @Test func deterministicPlanGroupsByRoleBucket() {
        let candidates = [
            fileCandidate("a1", role: "document", name: "论文.docx"),
            fileCandidate("a2", role: "document", name: "意见.pdf"),
            fileCandidate("b1", role: "image", name: "fig.png")
        ]
        let plan = AIVirtualFolderPlanner.deterministicPlan(candidates: candidates)
        // 两个角色桶:document(2) 在前,image(1) 在后。
        #expect(plan.groups.count == 2)
        #expect(plan.groups[0].title == "document")
        #expect(plan.groups[0].candidateIDs.count == 2)
        #expect(plan.groups[1].title == "image")
    }

    @Test func deterministicPlanFoldsOverflowIntoOther() {
        // 8 个不同角色桶,maxTopLevelGroups=3 → 取前 2 个桶 + 1 个 other(其余全进 other,不丢候选)。
        let roles = ["document", "image", "data", "config", "source", "checksum", "signature", "media"]
        let candidates = roles.enumerated().map { fileCandidate("c\($0.offset)", role: $0.element, name: $0.element) }
        let plan = AIVirtualFolderPlanner.deterministicPlan(
            candidates: candidates,
            constraints: AIVirtualFolderPlanConstraints(maxTopLevelGroups: 3))
        #expect(plan.groups.count == 3)
        #expect(plan.groups.last?.title == "other")
        let total = plan.groups.flatMap(\.candidateIDs).count
        #expect(total == 8)   // 一个候选都没丢
    }

    @Test func emptyCandidatesYieldEmptyPlan() {
        #expect(AIVirtualFolderPlanner.deterministicPlan(candidates: []).groups.isEmpty)
    }

    // MARK: - Builder

    @Test func buildDeterministicProducesMixedTree() {
        let docPath = "/Users/me/Desktop/paper/论文.docx"
        let archivePath = "/Users/me/Downloads/paper-assets.zip"
        let docRef = AIContextSourceRef(kind: .file, id: "fs-a1")
        let archiveRef = AIContextSourceRef(kind: .archive, id: "arch-1")
        let taskID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!

        let candidates: [AIVirtualNodeCandidate] = [
            AIVirtualNodeCandidate(id: "a1", kind: .file, displayName: "论文.docx",
                                   sourceRefs: [docRef], roleTags: ["document"]),
            AIVirtualNodeCandidate(id: "z1", kind: .archive, displayName: "paper-assets.zip",
                                   sourceRefs: [archiveRef], roleTags: ["archive"]),
            AIVirtualNodeCandidate(id: "t1", kind: .task, displayName: "压缩论文材料",
                                   sourceRefs: [AIContextSourceRef(kind: .task, id: taskID.uuidString)])
        ]
        let paths: [AIContextSourceRef: String] = [docRef: docPath, archiveRef: archivePath]
        let tree = AIVirtualFolderTreeBuilder.buildDeterministic(
            workspace: workspace(), candidates: candidates, pathsBySourceRef: paths, generatedAt: now)

        #expect(tree.generationMode == .deterministic)
        #expect(!tree.isEmpty)
        #expect(tree.workspaceID == wsID)
        // 顶层都是 group;混合 file/archive/task 三类叶子都在。
        #expect(tree.nodes.allSatisfy { $0.kind == .group })
        let leaves = allLeaves(tree.nodes)
        #expect(leaves.contains { $0.kind == .file && $0.title == "论文.docx" })
        #expect(leaves.contains { $0.kind == .archive })
        #expect(leaves.contains { $0.kind == .task })
        // 主动作按 kind + 路径安全推导。
        let fileLeaf = leaves.first { $0.kind == .file }
        #expect(fileLeaf?.primaryAction == .revealFile(path: docPath))
        let archiveLeaf = leaves.first { $0.kind == .archive }
        #expect(archiveLeaf?.primaryAction == .openArchive(path: archivePath, revealEntry: nil))
        let taskLeaf = leaves.first { $0.kind == .task }
        #expect(taskLeaf?.primaryAction == .openTask(taskID))
    }

    @Test func builderDropsInvalidCandidateIDsAndEmptyGroups() {
        let ref = AIContextSourceRef(kind: .file, id: "fs-keep")
        let candidates = [AIVirtualNodeCandidate(id: "keep", kind: .file, displayName: "keep.txt",
                                                 sourceRefs: [ref], roleTags: ["document"])]
        // plan 引用一个不存在的候选 id + 一个空组。
        let plan = AIVirtualFolderPlan(groups: [
            AIVirtualFolderGroupPlan(id: "g1", title: "文稿", candidateIDs: ["keep", "ghost"]),
            AIVirtualFolderGroupPlan(id: "g2", title: "空组", candidateIDs: ["ghost"])
        ])
        let tree = AIVirtualFolderTreeBuilder.build(
            workspace: workspace(), plan: plan, candidates: candidates,
            pathsBySourceRef: [:], mode: .modelAssisted, generatedAt: now)
        #expect(tree.generationMode == .modelAssisted)
        #expect(tree.nodes.count == 1)             // 空组被丢
        #expect(tree.nodes[0].children.count == 1) // ghost 候选被丢,只剩 keep
        #expect(tree.nodes[0].children[0].title == "keep.txt")
    }

    /// BUG-P1:模型输入里 ≥4 个同模式任务被折叠成一个 `pattern-…` 摘要;模型把摘要 id 放进某组后,
    /// builder 必须把它展开回**全部成员任务**,而不是因为 byID 查不到合成 id 就静默丢整组。
    @Test func builderExpandsCollapsedPatternSummaryID() {
        let tasks = (0..<5).map { i in
            AIVirtualNodeCandidate(
                id: "hash-\(i)", kind: .task, displayName: "Hash Reader \(i)",
                sourceRefs: [AIContextSourceRef(kind: .task, id: "task-\(i)")],
                roleTags: ["checksum"], semanticTokens: ["hash", "hid", "reader"],
                scoreSignals: ["succeeded"])
        }
        let summaryMembers = AIVirtualFolderModelInputPreparer.patternSummaryMembers(from: tasks)
        #expect(summaryMembers.count == 1)
        guard let summaryID = summaryMembers.keys.first else {
            Issue.record("折叠摘要未生成"); return
        }
        #expect(summaryID.hasPrefix("pattern-hash-"))

        let plan = AIVirtualFolderPlan(groups: [
            AIVirtualFolderGroupPlan(id: "g", title: "哈希任务", candidateIDs: [summaryID])
        ])
        let tree = AIVirtualFolderTreeBuilder.build(
            workspace: workspace(), plan: plan, candidates: tasks,
            pathsBySourceRef: [:], mode: .modelAssisted, generatedAt: now)
        #expect(tree.nodes.count == 1)
        #expect(tree.nodes[0].children.count == 5)   // 5 个成员任务全部展开,无一丢失
    }

    @Test func builderUsesPlanWorkspaceTitleWhenPresent() {
        let ref = AIContextSourceRef(kind: .file, id: "fs-x")
        let candidates = [AIVirtualNodeCandidate(id: "x", kind: .file, displayName: "x", sourceRefs: [ref])]
        let plan = AIVirtualFolderPlan(workspaceTitle: "论文修订材料",
                                       groups: [AIVirtualFolderGroupPlan(id: "g", title: "文稿", candidateIDs: ["x"])])
        let tree = AIVirtualFolderTreeBuilder.build(
            workspace: workspace(title: "占位"), plan: plan, candidates: candidates,
            mode: .modelAssisted, generatedAt: now)
        #expect(tree.title == "论文修订材料")
    }

    @Test func builderClampsLongGroupTitles() {
        let ref = AIContextSourceRef(kind: .file, id: "fs-y")
        let candidates = [AIVirtualNodeCandidate(id: "y", kind: .file, displayName: "y", sourceRefs: [ref])]
        let longTitle = String(repeating: "题", count: 50)
        let plan = AIVirtualFolderPlan(groups: [AIVirtualFolderGroupPlan(id: "g", title: longTitle, candidateIDs: ["y"])])
        let tree = AIVirtualFolderTreeBuilder.build(
            workspace: workspace(), plan: plan, candidates: candidates, mode: .modelAssisted,
            constraints: AIVirtualFolderPlanConstraints(maxTitleCharacters: 10), generatedAt: now)
        #expect(tree.nodes[0].title.count == 10)
    }

    // MARK: - 动作推导

    @Test func actionDeriverResolvesArchiveEntry() {
        let archiveRef = AIContextSourceRef(kind: .archive, id: "arch-2")
        let entryRef = AIContextSourceRef(kind: .archiveEntry, id: "references.bib")
        let candidate = AIVirtualNodeCandidate(id: "ae", kind: .archiveEntry,
                                               displayName: "paper-assets.zip/references.bib",
                                               sourceRefs: [entryRef, archiveRef])
        let action = AIVirtualNodeActionDeriver.primaryAction(
            for: candidate, pathsBySourceRef: [archiveRef: "/d/paper-assets.zip"])
        #expect(action == .openArchive(path: "/d/paper-assets.zip", revealEntry: "references.bib"))
    }

    @Test func actionDeriverReturnsNilWhenPathMissing() {
        let candidate = AIVirtualNodeCandidate(id: "f", kind: .file, displayName: "x",
                                               sourceRefs: [AIContextSourceRef(kind: .file, id: "fs-z")])
        #expect(AIVirtualNodeActionDeriver.primaryAction(for: candidate, pathsBySourceRef: [:]) == nil)
    }

    @Test func actionDeriverUsesPrebuiltActionForActionKind() {
        let candidate = AIVirtualNodeCandidate(id: "act", kind: .action, displayName: "压缩这些图片")
        let prebuilt: AISuggestionAction = .createArchive(paths: ["/a.png", "/b.png"])
        let action = AIVirtualNodeActionDeriver.primaryAction(
            for: candidate, pathsBySourceRef: [:], actionsByCandidateID: ["act": prebuilt])
        #expect(action == prebuilt)
    }

    // MARK: - prompt 投影 + 解码兼容

    @Test func promptFactProjectsQueryTokens() {
        let fact = AIWorkspacePromptFact(workspace: workspace())
        #expect(fact.id == wsID)
        #expect(fact.origin == "recommended")
        #expect(fact.queryTokens.contains("paper"))
        #expect(fact.queryTokens.contains("t"))
    }

    @Test func legacyTreeDecodesWithoutGenerationMode() throws {
        // 旧缓存 JSON(无 generationMode 字段)应解码为 deterministic,不报错。
        let json = """
        {"id":"00000000-0000-0000-0000-0000000000C1","workspaceID":"00000000-0000-0000-0000-0000000000C2",
         "title":"旧树","generatedAt":0,"nodes":[],"sourceRefs":[],"omissions":[]}
        """.data(using: .utf8)!
        let tree = try JSONDecoder().decode(AIVirtualFolderTree.self, from: json)
        #expect(tree.generationMode == .deterministic)
        #expect(tree.title == "旧树")
    }

    // MARK: - 用户调教 hint(架构债 #4:把 seed / learning / structure edits 喂进模型输入)

    @Test func learningHintsIsEmptyWhenAllBlank() {
        #expect(AIWorkspaceLearningHints().isEmpty)
        #expect(!AIWorkspaceLearningHints(keptItemNames: ["a"]).isEmpty)
        #expect(!AIWorkspaceLearningHints(userGroupTitles: ["源代码"]).isEmpty)
    }

    @Test func planInputRoundTripsLearningHints() throws {
        let hints = AIWorkspaceLearningHints(
            keptItemNames: ["main.swift"], removedItemNames: ["random.tmp"],
            preferredRoleTags: ["source"], rejectedRoleTags: ["junk"], userGroupTitles: ["源代码"])
        let input = AIVirtualFolderPlanInput(
            workspace: AIWorkspacePromptFact(workspace: workspace()),
            candidates: [], learningHints: hints)
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(AIVirtualFolderPlanInput.self, from: data)
        #expect(decoded.learningHints == hints)
        #expect(decoded.learningHints?.userGroupTitles == ["源代码"])
    }

    @Test func planInputWithoutHintsDecodesNil() throws {
        // 无调教 → hints nil;合成 Codable 对 optional 走 encodeIfPresent/decodeIfPresent → 键省略,旧输入兼容。
        let input = AIVirtualFolderPlanInput(
            workspace: AIWorkspacePromptFact(workspace: workspace()), candidates: [])
        let data = try JSONEncoder().encode(input)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("learningHints"))   // nil optional 不落键(= 旧格式)
        let decoded = try JSONDecoder().decode(AIVirtualFolderPlanInput.self, from: data)
        #expect(decoded.learningHints == nil)
    }

    @Test func modelInputCollapsesRepeatedHashTasksBeforePrompting() {
        let ref = AIContextSourceRef(kind: .file, id: "reader")
        let source = AIVirtualNodeCandidate(
            id: "src", kind: .file, displayName: "scardcontrol.c", sourceRefs: [ref],
            roleTags: ["source"], semanticTokens: ["scardcontrol", "ccid"], scoreSignals: ["project-token"])
        let tasks = (0..<15).map { i in
            AIVirtualNodeCandidate(
                id: "hash-\(i)", kind: .task, displayName: "Hash HID_Global_veriCLASS_Reader \(i)",
                sourceRefs: [AIContextSourceRef(kind: .task, id: "task-\(i)")],
                roleTags: ["checksum"], semanticTokens: ["hash", "hid", "reader"],
                scoreSignals: ["succeeded"])
        }

        let prepared = AIVirtualFolderModelInputPreparer.prepare(
            candidates: [source] + tasks,
            strongTokens: ["scardcontrol", "ccid"],
            maxCandidates: 8)

        #expect(prepared.filter { $0.roleTags.contains("repeated-hash-tasks") }.count == 1)
        // 2 代表保留原 id(hash-0, hash-1);摘要用 pattern-hash- 前缀,不再匹配 "hash-"。
        #expect(prepared.filter { $0.candidateID.hasPrefix("hash-") }.count == 2)
        #expect(prepared.filter { $0.candidateID.hasPrefix("pattern-hash-") }.count == 1)
        #expect(prepared.first?.candidateID == "src")
        #expect(prepared.contains { $0.scoreSignals.contains("importance=low") })
    }

    @Test func modelInputFavorsSpecificProjectSignalsOverGenericNoise() {
        let project = AIVirtualNodeCandidate(
            id: "pcsc", kind: .file, displayName: "PCSCv2part10.c",
            sourceRefs: [AIContextSourceRef(kind: .file, id: "pcsc")],
            roleTags: ["source"], location: AILocationContext(kind: .projectFolder, pathHash: "loc-project",
                                                              folderNameTokens: ["ccid"]),
            semanticTokens: ["pcscv2part10", "scardcontrol", "ccid"], scoreSignals: ["source"])
        let spec = AIVirtualNodeCandidate(
            id: "spec", kind: .file, displayName: "SCARDCONTROL.md",
            sourceRefs: [AIContextSourceRef(kind: .file, id: "spec")],
            roleTags: ["document"], location: AILocationContext(kind: .documents, pathHash: "loc-docs",
                                                                folderNameTokens: ["ccid"]),
            semanticTokens: ["scardcontrol"], scoreSignals: ["document"])
        let generic = (0..<6).map { i in
            AIVirtualNodeCandidate(
                id: "agents-\(i)", kind: .file, displayName: "AGENTS.md",
                sourceRefs: [AIContextSourceRef(kind: .file, id: "agents-\(i)")],
                roleTags: ["document"], location: AILocationContext(kind: i.isMultiple(of: 2) ? .desktop : .downloads,
                                                                    pathHash: "loc-\(i)",
                                                                    folderNameTokens: ["desktop", "downloads"]),
                semanticTokens: ["agents", "desktop", "downloads"], scoreSignals: ["same-name", "recent"])
        }

        let prepared = AIVirtualFolderModelInputPreparer.prepare(
            candidates: generic + [spec, project],
            strongTokens: ["scardcontrol", "pcscv2part10", "ccid"],
            maxCandidates: 2)

        #expect(prepared.map(\.candidateID) == ["pcsc", "spec"])
        #expect(!prepared.contains { $0.displayName == "AGENTS.md" })
    }

    @Test func modelInputTreatsSplitDocumentRolesAsUsefulEvidence() {
        let candidates = [
            AIVirtualNodeCandidate(
                id: "readme", kind: .file, displayName: "README.md",
                sourceRefs: [AIContextSourceRef(kind: .file, id: "readme")],
                roleTags: ["project-doc"], semanticTokens: ["readme"]),
            AIVirtualNodeCandidate(
                id: "changelog", kind: .file, displayName: "CHANGELOG.md",
                sourceRefs: [AIContextSourceRef(kind: .file, id: "changelog")],
                roleTags: ["release-notes"], semanticTokens: ["changelog"]),
            AIVirtualNodeCandidate(
                id: "reader", kind: .file, displayName: "HID_Global_veriCLASS_Reader.txt",
                sourceRefs: [AIContextSourceRef(kind: .file, id: "reader")],
                roleTags: ["reference-data"], semanticTokens: ["reader", "smartcard"])
        ]

        let (_, metrics) = AIVirtualFolderModelInputPreparer.prepareWithMetrics(
            candidates: candidates, strongTokens: [])

        #expect(metrics.tierCounts["normal"] == 3)
        #expect(metrics.tierCounts["low"] == nil)
    }

    @Test func modelInputKeepsExplorationSlotsForLowWeightEvidence() {
        let strong = (0..<8).map { i in
            AIVirtualNodeCandidate(
                id: "strong-\(i)", kind: .file, displayName: "scardcontrol-\(i).c",
                sourceRefs: [AIContextSourceRef(kind: .file, id: "strong-\(i)")],
                roleTags: ["source"], semanticTokens: ["scardcontrol", "ccid"], scoreSignals: ["project-token"])
        }
        let weak = (0..<4).map { i in
            AIVirtualNodeCandidate(
                id: "weak-\(i)", kind: .file, displayName: "AGENTS.md",
                sourceRefs: [AIContextSourceRef(kind: .file, id: "weak-\(i)")],
                roleTags: ["document"], location: AILocationContext(kind: .downloads, pathHash: "loc-\(i)",
                                                                    folderNameTokens: ["downloads"]),
                semanticTokens: ["agents", "downloads"], scoreSignals: ["recent"])
        }

        let prepared = AIVirtualFolderModelInputPreparer.prepare(
            candidates: strong + weak,
            strongTokens: ["scardcontrol", "ccid"],
            maxCandidates: 6)

        #expect(prepared.count == 6)
        #expect(prepared.contains { $0.candidateID.hasPrefix("weak-") })
        #expect(prepared.first?.candidateID.hasPrefix("strong-") == true)
    }

    // MARK: - 泛化折叠(非 hash 模式)

    @Test func modelInputCollapsesRepeatedCompressTasksGeneralized() {
        let source = AIVirtualNodeCandidate(
            id: "main", kind: .file, displayName: "main.swift",
            sourceRefs: [AIContextSourceRef(kind: .file, id: "main")],
            roleTags: ["source"], semanticTokens: ["swift", "main"], scoreSignals: ["project-token"])
        let tasks = (0..<6).map { i in
            AIVirtualNodeCandidate(
                id: "cmp-\(i)", kind: .task, displayName: "Compress release-\(i).zip",
                sourceRefs: [AIContextSourceRef(kind: .task, id: "task-cmp-\(i)")],
                roleTags: ["compress"], semanticTokens: ["compress", "zip", "release"],
                scoreSignals: ["succeeded"])
        }
        let prepared = AIVirtualFolderModelInputPreparer.prepare(
            candidates: [source] + tasks, strongTokens: ["swift", "main"], maxCandidates: 6)

        #expect(prepared.filter { $0.roleTags.contains("repeated-compress-tasks") }.count == 1)
        #expect(prepared.filter { $0.candidateID.hasPrefix("pattern-compress-") }.count == 1)
        // 2 个 compress 代表保留。
        #expect(prepared.filter { $0.candidateID.hasPrefix("cmp-") }.count == 2)
    }

    // MARK: - 量化指标

    @Test func prepareMetricsQuantifiesSuppressionAndCoverage() {
        let ref = AIContextSourceRef(kind: .file, id: "reader")
        let source = AIVirtualNodeCandidate(
            id: "src", kind: .file, displayName: "scardcontrol.c", sourceRefs: [ref],
            roleTags: ["source"], semanticTokens: ["scardcontrol", "ccid"], scoreSignals: ["project-token"])
        let tasks = (0..<10).map { i in
            AIVirtualNodeCandidate(
                id: "t-\(i)", kind: .task, displayName: "Hash device \(i)",
                sourceRefs: [AIContextSourceRef(kind: .task, id: "task-\(i)")],
                roleTags: ["checksum"], semanticTokens: ["hash", "device"], scoreSignals: ["succeeded"])
        }
        let (_, metrics) = AIVirtualFolderModelInputPreparer.prepareWithMetrics(
            candidates: [source] + tasks, strongTokens: ["scardcontrol", "ccid"], maxCandidates: 6)

        #expect(metrics.inputCount == 11)
        // 10 tasks → 8 suppressed(保留 2 代表 + 1 摘要);去重后可输出 4 条。
        #expect(metrics.suppressedCount == 8)
        #expect(metrics.outputCount == 4)   // src + t-0 + t-1 + pattern-hash-summary
        // scardcontrol + ccid 两个 strongToken 都在 src 里 → coverage = 1.0。
        #expect(metrics.strongTokenCoverage == 1.0)
        // src 是 high 层;task 代表和摘要是 low 层。
        #expect((metrics.tierCounts["high"] ?? 0) >= 1)
        #expect((metrics.tierCounts["low"] ?? 0) >= 1)
    }

    @Test func prepareMetricsTierCountsSumToOutputCount() {
        let candidates = (0..<12).map { i in
            AIVirtualNodeCandidate(
                id: "f-\(i)", kind: .file, displayName: "file-\(i).txt",
                sourceRefs: [AIContextSourceRef(kind: .file, id: "f-\(i)")],
                roleTags: ["document"], semanticTokens: ["report", "doc"], scoreSignals: ["same-name", "recent"])
        }
        let (_, metrics) = AIVirtualFolderModelInputPreparer.prepareWithMetrics(
            candidates: candidates, strongTokens: ["report"], maxCandidates: 8)

        let tierTotal = metrics.tierCounts.values.reduce(0, +)
        #expect(tierTotal == metrics.outputCount)
        let kindTotal = metrics.kindCounts.values.reduce(0, +)
        #expect(kindTotal == metrics.outputCount)
        #expect(metrics.outputCount <= 8)
    }

    @Test func prepareMetricsDefaultCandidateLimitKeepsFiftyCandidates() {
        let candidates = (0..<60).map { i in
            AIVirtualNodeCandidate(
                id: "strong-\(i)", kind: .file, displayName: String(format: "release-%02d.swift", i),
                sourceRefs: [AIContextSourceRef(kind: .file, id: "strong-\(i)")],
                roleTags: ["source"],
                semanticTokens: ["simplezip", "release", "integrity", "sign"],
                scoreSignals: ["project-token", "source-ref-match", "failed"])
        }

        let (prepared, metrics) = AIVirtualFolderModelInputPreparer.prepareWithMetrics(
            candidates: candidates, strongTokens: ["simplezip", "release", "integrity", "sign"])

        #expect(prepared.count == 50)
        #expect(metrics.outputCount == 50)
    }

    private func allLeaves(_ nodes: [AIVirtualNode]) -> [AIVirtualNode] {
        nodes.flatMap { $0.kind == .group ? allLeaves($0.children) : [$0] }
    }
}

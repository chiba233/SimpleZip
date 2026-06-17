//
//  AIWorkspaceView.swift
//  SimpleZip
//
//  0.4.5 #80 #89:AI 工作区主内容区(白皮书建议四)。
//
//  顶部是**主题头**(渐变图标 + 主题名 + 可编辑的文件夹描述,后台空闲时端上模型可进一步润色,模型只写描述);
//  下面是内容 —— 直接复用主文件浏览的 NSOutlineView(`AIVirtualNodeOutline`),所以多选 / 框选 / 方向键 /
//  空格展开 / 回车改名 / 点空白取消选中 / 拖拽移动 全部与主视图一致。渲染 `AIVirtualNode`,不伪造 FileItem。
//

import AppKit
import SwiftUI

/// 一个文件 / 归档 / 文件夹节点的派生 AI 建议(确定性;模型增强后续接)。
struct AIWorkspaceNodeAction: Identifiable {
    let titleKey: String
    /// 已本地化、含动态值的完整标题(如「用 Preview 打开」)。非空时直接显示,代替 `L10n.text(titleKey)`。
    var displayTitle: String? = nil
    let systemImage: String
    let action: AISuggestionAction
    var id: String { displayTitle ?? titleKey }
}

enum AIWorkspaceNodeActions {
    /// 节点的 AI 建议(**多种、按上下文变化,不是固定哈希**):文件→在 SimpleZip 显示 / 哈希;归档→打开 / 测试;
    /// 文件夹→打开 / 压缩;**分组→把这一组成员一起压缩(可省空间)** —— 多文件成组复用「一组折一行」的语义。
    static func suggestions(for node: AIVirtualNode) -> [AIWorkspaceNodeAction] {
        switch node.kind {
        case .file:
            guard let path = resolvedPath(node) else { return [] }
            return [reveal(path), hash([path])]
        case .archive:
            guard let path = resolvedPath(node) else { return [] }
            return [openArchive(path), test(path)]
        case .folder:
            guard let path = resolvedPath(node) else { return [] }
            return [openFolder(path), compress([path], "aiWorkspace.node.compress")]
        case .group:
            let paths = descendantFilePaths(node)
            guard paths.count >= 2 else { return [] }
            return [compress(paths, "aiWorkspace.node.compressGroup")]
        default:
            return []
        }
    }

    /// 文件浏览器里**单个文件行**的 AI 抽屉。**拒绝假AI**:只读后台**端上模型**产出的东西(一句话摘要 +
    /// 模型挑的建议动作 token),没有就返回 nil(空抽屉、不展开)。**不再有任何写死动作**(打开/测试这种固定项是假 AI,
    /// 已删)—— 动作必须是模型基于内容/事实决定的;模型没说就什么都不显示。
    static func fileBrowserDrawer(for item: FileItem) -> (summary: String?, actions: [AIWorkspaceNodeAction])? {
        guard !item.isDirectory,
              let record = AIBackgroundIndexStore.shared.record(forPath: item.url.path),
              let content = record.contentSummary, content.hasModelSuggestion else { return nil }
        let path = item.url.path
        let kind = record.type == .archive ? "archive" : "file"
        let actions = content.suggestedActions.compactMap {
            fileAction($0, path: path, kind: kind, sourceRef: record.contextSourceRef)
        }
        let summary = (content.shortSummary?.isEmpty == false) ? content.shortSummary : nil
        guard summary != nil || !actions.isEmpty else { return nil }
        return (summary, actions)
    }

    /// 把**模型挑的**结构化动作 + 文件路径安全合成一条建议行(模型不拼路径;token 必须在词表里且适用该 kind)。
    /// 带 payload 的动作(openWith→app bundleId、包内文件→entryPath…)由 App 据 payload 安全合成;模型只选不拼。
    private static func fileAction(_ action: AIFileSuggestedAction, path: String, kind: String,
                                  sourceRef: AIContextSourceRef) -> AIWorkspaceNodeAction? {
        let token = action.token
        switch token {
        case "hash" where applies(token, kind):    return hash([path])
        case "compress" where applies(token, kind): return compress([path], "aiWorkspace.node.compress")
        case "test" where applies(token, kind):    return test(path)
        case "inspect" where applies(token, kind): return .init(titleKey: "aiWorkspace.suggest.inspect", systemImage: "shippingbox",
                                                                action: .inspectRelease(path: path))
        case "convert" where applies(token, kind): return .init(titleKey: "aiWorkspace.suggest.convert", systemImage: "arrow.triangle.2.circlepath",
                                                                action: .convertArchive(path: path))
        // 推荐打开方式:payload = 模型挑的非默认 App bundleId、label = App 名;App 据 bundleId 用该 App 打开此文件。
        case "openWith":
            guard let bundleID = action.payload, !bundleID.isEmpty else { return nil }
            let appName = (action.label?.isEmpty == false) ? action.label! : bundleID
            return .init(titleKey: "aiWorkspace.suggest.openWith",
                         displayTitle: L10n.format("aiWorkspace.suggest.openWith", appName),
                         systemImage: "arrow.up.forward.app",
                         action: .openWithApplication(sourceRefs: [sourceRef], bundleIdentifier: bundleID))
        default:        return nil
        }
    }

    private static func applies(_ token: String, _ kind: String) -> Bool {
        AIVirtualNodeActionDeriver.allowedSuggestionDescriptors
            .contains { $0.id == token && $0.appliesToKinds.contains(kind) }
    }

    /// 一个分组里所有(可定位路径的)叶子成员的真实路径 —— 给「把这组一起压缩」用。
    static func descendantFilePaths(_ node: AIVirtualNode) -> [String] {
        var paths: [String] = []
        func walk(_ n: AIVirtualNode) {
            if n.kind != .group, let p = resolvedPath(n) { paths.append(p) }
            n.children.forEach(walk)
        }
        node.children.forEach(walk)
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    static func resolvedPath(_ node: AIVirtualNode) -> String? {
        switch node.primaryAction {
        case .revealFile(let p), .openFolder(let p): return p
        case .openArchive(let p, _): return p
        default: return nil
        }
    }

    private static func reveal(_ p: String) -> AIWorkspaceNodeAction {
        .init(titleKey: "aiWorkspace.node.reveal", systemImage: "magnifyingglass", action: .revealFile(path: p))
    }
    private static func hash(_ p: [String]) -> AIWorkspaceNodeAction {
        .init(titleKey: "aiWorkspace.node.hash", systemImage: "number",
              action: .calculateHash(paths: p, algorithms: ["sha256"]))
    }
    private static func openArchive(_ p: String) -> AIWorkspaceNodeAction {
        .init(titleKey: "aiWorkspace.node.openArchive", systemImage: "doc.zipper",
              action: .openArchive(path: p, revealEntry: nil))
    }
    private static func test(_ p: String) -> AIWorkspaceNodeAction {
        .init(titleKey: "aiWorkspace.node.test", systemImage: "checkmark.seal", action: .testArchive(path: p))
    }
    private static func openFolder(_ p: String) -> AIWorkspaceNodeAction {
        .init(titleKey: "aiWorkspace.node.openFolder", systemImage: "folder", action: .openFolder(path: p))
    }
    private static func compress(_ paths: [String], _ titleKey: String) -> AIWorkspaceNodeAction {
        .init(titleKey: titleKey, systemImage: "archivebox", action: .createArchive(paths: paths))
    }
}

struct AIWorkspaceView: View {
    @ObservedObject var model: ArchiveBrowserModel
    let workspaceID: UUID
    @ObservedObject private var store = AIWorkspaceStore.shared

    /// 可编辑描述的草稿(聚焦失焦 / 回车提交回 store)。
    @State private var descriptionDraft: String = ""
    @FocusState private var descriptionFocused: Bool

    var body: some View {
        Group {
            if let ws = store.workspace(workspaceID), let tree = store.virtualTree(for: workspaceID), !tree.isEmpty {
                let levelNodes = model.aiWorkspacePath.last?.children ?? tree.nodes
                VStack(spacing: 0) {
                    header(ws, generationMode: tree.generationMode)
                    Divider()
                    if levelNodes.isEmpty {
                        emptyState(L10n.text("aiFolder.noSuggestions"))
                    } else {
                        AIVirtualNodeOutline(model: model, store: store, workspaceID: workspaceID,
                                             nodes: levelNodes, onDispatch: dispatch)
                    }
                }
            } else {
                emptyState(L10n.text("aiFolder.noSuggestions"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadDescriptionDraft() }
        .onChange(of: workspaceID) { _ in loadDescriptionDraft() }
    }

    // MARK: - 主题头(图标 + 主题名 + 可编辑描述)

    private func header(_ ws: AIWorkspace, generationMode: AIVirtualTreeGenerationMode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.accentColor.gradient)
                .overlay(Image(systemName: ws.iconSystemName)
                    .font(.system(size: 19, weight: .semibold)).foregroundStyle(.white))
                .frame(width: 42, height: 42)
                .shadow(color: Color.accentColor.opacity(0.35), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(ws.title).font(.title3.weight(.semibold)).lineLimit(1)
                    if store.isRegenerating(workspaceID) {
                        RegeneratingBadge(text: L10n.text("aiWorkspace.regenerating"))   // 华丽:正在 AI 重新整理
                    } else if generationMode == .deterministic {
                        Text(L10n.text("aiWorkspace.mode.deterministic"))
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                TextField(descriptionPlaceholder(ws), text: $descriptionDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1...3)
                    .focused($descriptionFocused)
                    .onSubmit { commitDescription() }
                    .onChange(of: descriptionFocused) { focused in if !focused { commitDescription() } }
            }
            Spacer(minLength: 8)
            if store.isRegenerating(workspaceID) {
                ProgressView().controlSize(.small).frame(width: 18, height: 18)
                    .help(L10n.text("aiWorkspace.regenerating"))
            } else {
                Button { store.refreshWorkspaceTree(workspaceID) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(L10n.text("sidebar.ai.refreshWorkspace"))
            }
            if ws.origin == .recommended {
                // 删除推荐工作区 = dismissRecommended:写衰减抑制账本(按主题指纹避开),**真删得掉、不会下轮又冒出来**。
                // (之前那个 hide 是错的:发现下一轮重新 upsert 又出现 = 等于没删,已移除。)
                Button { store.dismissRecommended(workspaceID) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help(L10n.text("sidebar.ai.dismissRecommended"))
            } else if ws.origin == .userCreated {
                Button(role: .destructive) { store.removeUserWorkspace(workspaceID) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help(L10n.text("sidebar.ai.deleteWorkspace"))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(LinearGradient(colors: [Color.accentColor.opacity(0.10), Color.accentColor.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom))
    }

    /// 描述为空时的占位:确定性主题种子(后台空闲时模型可把它落成真正的 userDescription)。
    private func descriptionPlaceholder(_ ws: AIWorkspace) -> String {
        let tokens = ws.queryPlan.keywords.filter { !$0.isEmpty }.prefix(5)
        guard !tokens.isEmpty else { return L10n.text("aiWorkspace.description.placeholder") }
        return L10n.text("aiWorkspace.description.seed") + tokens.joined(separator: " · ")
    }

    private func loadDescriptionDraft() { descriptionDraft = store.workspace(workspaceID)?.userDescription ?? "" }
    private func commitDescription() { store.setDescription(workspaceID, descriptionDraft) }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(Color.accentColor.opacity(0.6))
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 节点动作 → 现有 App 流程(只读 / 导航 / 启动现有任务流程)

    /// 派发统一搬到 `ArchiveBrowserModel.dispatchSuggestion` —— AI 文件夹建议子行和文件浏览器建议抽屉共用一处。
    private func dispatch(_ action: AISuggestionAction) {
        model.dispatchSuggestion(action)
    }
}

/// 「AI 正在重新整理…」华丽徽章:渐变胶囊 + 流动光泽 + 旋转魔杖 + 发光。点刷新时显示,明确告诉用户**模型真的在重排**
/// (不是干显示「自动整理」)。用 `TimelineView(.animation)` 驱动,平滑且**不用 repeatForever**(避坑)。
private struct RegeneratingBadge: View {
    let text: String

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let sweep = (t.truncatingRemainder(dividingBy: 1.8)) / 1.8   // 0..1 光泽扫动
            HStack(spacing: 5) {
                Image(systemName: "wand.and.rays")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 4) * 90))
                Text(text).font(.caption2.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(
                Capsule().fill(LinearGradient(
                    colors: [Color.accentColor, Color.purple, Color.accentColor],
                    startPoint: UnitPoint(x: sweep - 0.5, y: 0.5),
                    endPoint: UnitPoint(x: sweep + 0.5, y: 0.5)))
            )
            .shadow(color: Color.accentColor.opacity(0.5), radius: 5, y: 1)
        }
        .fixedSize()
    }
}

//
//  UpdateAssistantView.swift
//  SimpleZip
//
//  更新助手(0.4.5 新 feat):老用户升级到新版后,弹一个**迷你欢迎**,只展示「本次新增的卡片」+ 搞定页。
//
//  设计(用户拍板,刻意简单 —— 不做版本比对):每张「更新卡片」一个**已看标记**(`seenUpdateCards`)。
//  - 全新用户走完整欢迎助手 → 走完即把全部更新卡片标记已看 → 不会再弹更新助手。
//  - 老用户(已完成欢迎助手)首次升级上来 → 一次性迁移:把「本版之前就存在的卡片」标记已看,只留本版新增卡未看。
//  - 更新助手只显示**未看**的卡片;以后任何版本新增一张卡(默认未看)→ 老用户自动收到更新助手,无需版本判断。
//
//  复用欢迎助手的卡片组件(`WelcomeAIStep` 等,internal)—— 不另造一套 UI。
//

import SwiftUI
import AppKit

extension Notification.Name {
    /// DevTools 测试用:触发更新助手并指定要展示的卡(`userInfo["cards"]` = [String] 卡片 rawValue)。
    static let devToolsTriggerUpdateAssistant = Notification.Name("devToolsTriggerUpdateAssistant")
}

/// 更新助手的弹出请求(带要展示的卡)。用 `.sheet(item:)` 而非 `isPresented:` —— 后者在 present 那一拍可能
/// 读到尚未更新的 cards 数组(空 → 直接跳到搞定页,用户报的「点了只显示完成」),item 形态保证 cards 一并就绪。
struct UpdateAssistantRequest: Identifiable {
    let id = UUID()
    let cards: [UpdateCard]
}

/// 欢迎助手 / 更新助手共用的「卡片」—— 对应欢迎助手的各设置页(首页 hero+版本+备份不算卡)。
/// 每张都有「已看」标记:老用户升级一次性把除本版新增(0.4.5 = `.ai`)外的全标已看 → 更新助手只弹新卡;
/// DevTools 测试可单独触发任意一张。**新增卡片 = 在这里加 case + `WelcomeCardBody` 加渲染**,老用户自动收到。
enum UpdateCard: String, CaseIterable, Identifiable {
    case general          // 语言 + 常规
    case convenience      // 预设密码 + 自动解压 + 文件关联
    case finderServices   // Finder 右键集成
    case safety           // 安全策略 + 访达收藏同步
    case engine           // 压缩后端 + GPG
    case ai               // 端上智能(0.4.5 新增)
    var id: String { rawValue }

    /// 0.4.5 这一版「新增」的卡(老用户迁移时**不**标已看,留给更新助手弹)。将来加版本就把当版新卡列进来。
    static let introducedThisVersion: [UpdateCard] = [.ai]
}

/// 更新助手的「该不该弹 / 弹哪些卡」决策 —— 纯读写 `AppPreferences` 的已看集,无版本比对。
enum UpdateAssistant {
    /// 老用户一次性迁移:已完成欢迎助手 → 把「本版之前就存在」的卡(= 除 `introducedThisVersion` 外的全部)标记已看,
    /// 只留本版新增卡未看,留给更新助手弹。
    static func migrateForExistingUserIfNeeded() {
        guard !AppPreferences.updateCardsMigrated else { return }
        if AppPreferences.welcomeAssistantCompleted {
            let newThisVersion = Set(UpdateCard.introducedThisVersion.map(\.rawValue))
            let preexisting = UpdateCard.allCases.map(\.rawValue).filter { !newThisVersion.contains($0) }
            AppPreferences.markUpdateCardsSeen(preexisting)
        }
        AppPreferences.markUpdateCardsMigrated()
    }

    /// 该弹更新助手吗 → 返回未看过的卡(空 = 不弹)。只对**已完成欢迎助手**的老用户(新用户走完整欢迎)。
    static func pendingCards() -> [UpdateCard] {
        guard AppPreferences.welcomeAssistantCompleted else { return [] }
        let seen = AppPreferences.seenUpdateCards
        return UpdateCard.allCases.filter { !seen.contains($0.rawValue) }
    }

    /// 标记一批卡已看(更新助手走完 = 标其展示的;欢迎助手走完 = 标全部)。
    static func markSeen(_ cards: [UpdateCard]) {
        AppPreferences.markUpdateCardsSeen(cards.map(\.rawValue))
    }
}

/// 迷你欢迎 wizard:逐页展示新增卡片,最后一页是「搞定」。复用欢迎助手的卡片组件。
struct UpdateAssistantView: View {
    let cards: [UpdateCard]
    /// 关闭(完成 / 跳过)时由 host 处理 —— 内部已在完成时标记卡片已看。
    let onComplete: () -> Void

    @State private var page = 0

    /// 总页 = 卡片数 + 1(末页搞定)。
    private var totalPages: Int { cards.count + 1 }
    private var isDonePage: Bool { page >= cards.count }
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ViewThatFits(in: .vertical) {
                paddedContent
                ScrollView { paddedContent }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(page)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: 24)),
                removal: .opacity.combined(with: .offset(x: -18))
            ))
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        // 与欢迎助手同宽高(780×700)—— 复用它专门适配好的尺寸,别自造一个更局促的。
        .frame(width: 780, height: 700)
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(colors: [Color.accentColor.opacity(0.13), .clear],
                               startPoint: .top, endPoint: .center)
                LinearGradient(colors: [.clear, Color.purple.opacity(0.07)],
                               startPoint: .center, endPoint: .bottomTrailing)
            }
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 30, height: 30)
            } else {
                Image(systemName: "sparkles").font(.system(size: 24)).foregroundStyle(Color.accentColor)
            }
            Text(L10n.text("update.window.title")).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var paddedContent: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
    }

    @ViewBuilder
    private var content: some View {
        if isDonePage {
            doneView
        } else {
            VStack(alignment: .leading, spacing: 16) {
                hero
                cardView(cards[page])
            }
        }
    }

    /// 顶部「已更新到最新版本」横幅(每张卡片页上方)。
    private var hero: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(
                    LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .shadow(color: .indigo.opacity(0.35), radius: 9, y: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.format("update.hero.title", currentVersion))
                    .font(.title2.weight(.bold))
                Text(L10n.text("update.hero.body"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// 渲染一张卡 —— 复用欢迎助手同一份 `WelcomeCardBody`(零重复:欢迎向导与更新助手同源)。
    private func cardView(_ card: UpdateCard) -> some View {
        WelcomeCardBody(card: card)
    }

    /// 搞定页:庆祝徽章 + 标题 + 一句话。
    private var doneView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(
                    LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle()
                )
                .shadow(color: .green.opacity(0.45), radius: 14, y: 6)
            Text(L10n.text("update.done.title")).font(.largeTitle.weight(.bold))
            Text(L10n.text("update.done.body"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    private var footer: some View {
        HStack {
            // 跳过:直接完成(已展示的卡仍按完成标记已看 —— 用户看到了就不再骚扰)。
            Button(L10n.text("welcome.button.cancel")) { finish() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if page > 0 {
                Button(L10n.text("welcome.button.back")) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { page = max(page - 1, 0) }
                }
            }
            if page < totalPages - 1 {
                Button(L10n.text("welcome.button.next")) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { page = min(page + 1, totalPages - 1) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(L10n.text("welcome.button.finish")) { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finish() {
        UpdateAssistant.markSeen(cards)   // 展示过即标记已看,下次启动不再弹
        onComplete()
    }
}

//
//  TaskCompletionNotifier.swift
//  SimpleZip
//
//  0.4.4 #10:长任务完成后发系统通知(UserNotifications)。
//
//  只在「开关开 + app 不在前台 + 任务够长 + 成功/失败」时发 —— 用户在 app 里盯着活动中心就不打扰,
//  短任务也不值得打扰。授权请求绑在用户**打开开关**那一刻(明确 opt-in),而不是某次后台完成时突然弹。
//  默认关。
//

import AppKit
// UserNotifications 是 pre-concurrency 框架(其类型未标 Sendable)—— @preconcurrency 抑制跨 @Sendable 闭包的噪声警告。
@preconcurrency import UserNotifications

@MainActor
enum TaskCompletionNotifier {
    /// 「长任务」阈值:至少跑这么久才值得通知。
    static let minimumDuration: TimeInterval = 10

    /// 任务收尾时调(finish 里)。各项 gate 不满足就静默返回。
    static func notifyIfNeeded(_ task: OperationTask) {
        guard AppPreferences.tasksNotifyOnFinish else { return }
        guard !NSApplication.shared.isActive else { return }       // 前台不打扰
        let finished = task.finishedAt ?? Date()
        guard finished.timeIntervalSince(task.startedAt) >= minimumDuration else { return }
        let body: String
        switch task.status {
        case .succeeded: body = L10n.text("notify.task.succeeded")
        case .failed: body = L10n.text("notify.task.failed")
        default: return                                            // skipped / cancelled / running 不通知
        }
        deliver(title: task.title, body: body)
    }

    /// 用户**打开开关**时请求授权 —— 把系统提示绑在明确的 opt-in 上。
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func deliver(title: String, body: String) {
        // 不捕获 center —— 闭包里重新取 .current()(同一单例),避免在 @Sendable 闭包里捕获非 Sendable 类型。
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

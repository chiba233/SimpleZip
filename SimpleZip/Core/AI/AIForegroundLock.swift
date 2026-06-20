//
//  AIForegroundLock.swift
//  SimpleZipCore
//
//  app / agent 后台索引互斥的「前台活跃」锁(flock)。
//
//  问题:用户开了「静默后台索引」后,周期后台 agent(launchd 拉起跑 `--background-index`)和正在运行的主 App
//  都可能去扫描 / 写同一份共享派生索引。约定是 **App 在线时后台索引归 App**(走 App 自己的电源管理),后台 agent
//  只在 App 关闭时跑。但 launchd 的 StartInterval / RunAtLoad 可能在 App 正开着时把 agent 拉起。
//
//  机制:**App 启动取一把独占文件锁并长期持有**(进程退出 / 崩溃由 OS 自动释放,无需显式解锁);**agent 在开跑前
//  探一下** —— 锁被占 = App 在前台活跃 → agent 让位、跳过这轮。
//
//  这是 **best-effort 让位、不是硬互斥**:App 写派生索引是原子写、agent 单轮有界,所以极少见的「agent 探完未占 →
//  App 紧接着启动 → 短暂重叠」最坏只是跑了一轮冗余,不会损坏数据。锁文件两边据**同一个 App bundle id** 算到同一处
//  (`<App Support>/<App bundle id>/ai-foreground.lock`,与 AIDerivedData 同级);A19:agent 不可信自己的
//  `Bundle.main`,故 bundle id 由调用方显式传入(app / agent 都传 `AIAgentConfiguration.appBundleID`,值一致)。
//

import Foundation

public final class AIForegroundLock {

    /// 锁文件名(app / agent 共用,放 `<App Support>/<App bundle id>/` 下,与 `AIDerivedData/` 同级)。
    public static let fileName = "ai-foreground.lock"

    /// 据 App bundle id 算锁文件 URL(app / agent 传**同一个** id → 同一路径);顺带建好父目录。拿不到 App Support
    /// 根 → nil(调用方据此跳过锁逻辑,不阻断主流程)。
    public static func lockURL(appBundleID: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent(appBundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName, isDirectory: false)
    }

    private var heldFD: Int32 = -1

    public init() {}

    /// **App 侧**:取独占锁并**长期持有**(fd 留在实例里不关 → 持有到进程退出 / `release()`)。已持有则直接 true。
    /// 用 `LOCK_NB` 非阻塞 → 即使被占也立刻返回(不会卡主线程,可在启动时主线程调)。
    @discardableResult
    public func acquireAndHold(at url: URL) -> Bool {
        if heldFD >= 0 { return true }
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false   // 已被本机另一处持有(正常单实例 App 少见)
        }
        heldFD = fd
        return true
    }

    /// 显式释放(一般不需要 —— 进程退出 OS 自动释放;留着以备需要)。
    public func release() {
        if heldFD >= 0 {
            flock(heldFD, LOCK_UN)
            close(heldFD)
            heldFD = -1
        }
    }

    /// **agent 侧**:探前台 App 是否活跃(持有锁)。试取非阻塞独占锁:取到 = 没人占(随即释放,回 false);取不到
    /// (EWOULDBLOCK)= App 持有 → 回 true(agent 应让位)。**只探一下、不持有**。开不了文件 → 保守回 false
    /// (不无故阻断 agent)。
    public static func isForegroundAppActive(at url: URL) -> Bool {
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)   // 取到了 → 没人占 → 立即释放
            return false
        }
        return true   // EWOULDBLOCK → App 持有 → 前台活跃
    }
}

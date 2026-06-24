import XCTest

/// 启动冒烟测试。设 `SIMPLEZIP_UI_TESTING=1` 让 app 跳过所有首启模态弹窗 —— 欢迎 / 更新助手、以及
/// 「上次未干净退出」的恢复提示（后者无窗口时走 `runModal`，会卡住主线程让主窗口根本出不来）。
/// 否则 XCUITest 一遇模态就阻塞。只验证启动到前台、主窗口与菜单栏出现、能干净退出，刻意不碰
/// NSOpenPanel / sheet 等系统交互（无人值守环境下 flaky）。覆盖 SwiftPM 核心测试照不到的 app 装配。
final class SimpleZipLaunchTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        // 兜底:万一仍冒出系统弹窗（权限框等），点默认按钮放行，别让测试卡住。
        addUIInterruptionMonitor(withDescription: "system dialog") { element in
            for label in ["好", "好的", "允许", "Allow", "OK", "不允许", "Don't Allow"] {
                let button = element.buttons[label]
                if button.exists { button.click(); return true }
            }
            return false
        }
    }

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SIMPLEZIP_UI_TESTING"] = "1"
        app.launch()
        app.activate()
        return app
    }

    /// app 启动后处于前台运行、且至少出现一个窗口。
    func testAppLaunchesWithAMainWindow() {
        let app = launchedApp()
        XCTAssertEqual(app.state, .runningForeground, "app 启动后应处于前台运行")
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 30),
            "启动后应至少出现一个窗口"
        )
        app.terminate()
    }

    /// 启动后菜单栏存在（顶层菜单装配成功），且能干净退出。
    func testMenuBarIsPresentAndAppTerminates() {
        let app = launchedApp()
        XCTAssertTrue(
            app.menuBars.firstMatch.waitForExistence(timeout: 30),
            "启动后应有菜单栏"
        )
        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "terminate 后应已退出")
    }
}

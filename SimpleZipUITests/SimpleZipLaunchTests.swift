import XCTest

/// 启动冒烟测试。只验证 app 能启动、主窗口与菜单栏出现、能正常退出 —— 覆盖 SwiftPM 核心测试照不到的
/// app 行为（AppKit/SwiftUI 装配、窗口创建、菜单栏 .commands 构建）。刻意不碰 NSOpenPanel / sheet /
/// 文件对话框等系统交互（在无人值守环境下 flaky）。
///
/// `XCUIApplication()` 启动的是 TEST_TARGET_NAME 指向的 app（SimpleZip-dev）。启动会触发 SMAppService /
/// XPC / 后台索引等较重的初始化，故等待超时给得宽松。
final class SimpleZipLaunchTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// app 启动后处于前台运行、且至少出现一个窗口（欢迎助手或浏览器窗口都算）。
    func testAppLaunchesWithAMainWindow() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground, "app 启动后应处于前台运行")
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 30),
            "启动后应至少出现一个窗口"
        )
        app.terminate()
    }

    /// 启动后菜单栏存在（顶层菜单装配成功），且能干净退出。
    func testMenuBarIsPresentAndAppTerminates() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.menuBars.firstMatch.waitForExistence(timeout: 30),
            "启动后应有菜单栏"
        )
        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "terminate 后应已退出")
    }
}

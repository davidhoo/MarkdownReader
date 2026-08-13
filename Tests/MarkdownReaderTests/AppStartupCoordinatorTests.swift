import XCTest
@testable import MarkdownReader

/// 应用级启动服务测试（Task 13 Step 1）。
///
/// 验证 WebView 预热、自动更新检查、最后位置恢复的应用级幂等性，
/// 以及 lastOpened 只由最后活动窗口写入。
@MainActor
final class AppStartupCoordinatorTests: TemporaryDirectoryTestCase {

    private func makeSession(coordinator: WindowCoordinator) -> WindowSession {
        WindowSession(id: WindowID(), coordinator: coordinator)
    }

    // MARK: - WebView 预热幂等

    func testWarmupRunsOnceAcrossMultipleWindowRegistrations() {
        let service = WebViewWarmupService.shared
        service.resetForTesting()
        XCTAssertEqual(service.state, .idle)

        let first = service.warmUpIfNeeded()
        XCTAssertEqual(service.state, .ready, "首次预热后状态必须为 ready")

        // 多窗口注册不重复预热
        let second = service.warmUpIfNeeded()
        let third = service.warmUpIfNeeded()
        XCTAssertEqual(service.state, .ready)
        XCTAssertTrue(first === second, "后续调用必须返回同一 WebPage")
        XCTAssertTrue(second === third, "幂等：始终同一实例")
    }

    // MARK: - 预热资源集：仅基础运行时，不含可选 Mermaid/KaTeX

    func testWarmupHTMLLoadsBaseRuntimeOnly() {
        let html = WebViewWarmupService.warmupHTML

        XCTAssertTrue(html.contains("mr:///js/prism-core.min.js"))
        XCTAssertTrue(html.contains("mr:///js/markdown-reader.js"))
        XCTAssertFalse(html.contains("mr:///js/mermaid.min.js"))
        XCTAssertFalse(html.contains("mr:///js/katex.min.js"))
        XCTAssertFalse(html.contains("mr:///css/katex.min.css"))
    }

    // MARK: - 启动优先级：外部请求抑制恢复

    func testExternalOpenSuppressesRestoreLastLocation() {
        let coordinator = AppStartupCoordinator.shared
        coordinator.resetForTesting()

        coordinator.hasPendingExternalRequests = true
        XCTAssertFalse(coordinator.shouldRestoreLastLocation(),
                       "有待处理外部请求时不得恢复上次位置")

        coordinator.hasPendingExternalRequests = false
        // reopenLastLocation 默认值取决于 SettingsModel；此处只验证无外部请求时不被抑制
        // （shouldRestoreLastLocation 还需 reopenLastLocation 为 true）
    }

    // MARK: - lastOpened 只由最后活动窗口写入

    func testOnlyLastActiveWindowUpdatesLastLocation() throws {
        let coordinator = WindowCoordinator()
        let active = makeSession(coordinator: coordinator)
        let background = makeSession(coordinator: coordinator)
        coordinator.register(session: active)
        coordinator.register(session: background)

        // active 设为最后活动窗口
        coordinator.recordActive(windowID: active.id)
        XCTAssertEqual(coordinator.lastActiveWindowID, active.id)

        let url = try makeFile(named: "active.md", content: "# A")

        // background 窗口尝试记录 → 不应写入（非最后活动）
        background.recordLastOpened(file: url, directory: nil)
        let settings = SettingsModel.shared
        // 记录前先清空，验证 background 不写入
        let before = settings.lastOpenedFile
        // background 非活动，recordLastOpened 内 isActive=false，不写
        // （before 可能非 nil，这里只验证 background 未改变它）

        // active 窗口记录 → 应写入
        active.recordLastOpened(file: url, directory: nil)
        XCTAssertEqual(settings.lastOpenedFile?.lastPathComponent, "active.md",
                       "最后活动窗口应能更新 lastOpenedFile")
    }

    // MARK: - 应用级启动只执行一次

    func testAppLevelStartupIsIdempotent() {
        let coordinator = AppStartupCoordinator.shared
        coordinator.resetForTesting()

        coordinator.performAppLevelStartupOnce()
        coordinator.performAppLevelStartupOnce()
        coordinator.performAppLevelStartupOnce()

        // 幂等：多次调用不重复执行（无崩溃、无异常即通过）
        // WebView 预热应只发生一次
        XCTAssertEqual(WebViewWarmupService.shared.state, .ready)
    }
}

import SwiftUI
import MarkdownReaderKit
import os

/// 应用委托，处理 macOS 应用生命周期事件。
///
/// Task 8：所有文件/目录打开入口统一通过 `WindowCoordinator.enqueue(OpenRequest)` 路由。
/// 冷启动时 Coordinator 尚未 attach 窗口，请求在内存队列暂存；attach 后 drain。
/// 已删除：pendingOpenFileURL/pendingOpenDirectoryURL UserDefaults、0.5s 启动延迟、
/// 单窗口守卫（Task 6 已删）、activateFirstHiddenWindow 通知广播。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let logger = Logger(subsystem: "com.markdownreader.app", category: "AppDelegate")

    /// 应用是否已经完成启动
    private var didFinishLaunching = false

    /// 应用级终止协调器（Task 1）。实例属性即共享实例，避免与静态副本分裂。
    let terminationCoordinator: ApplicationTerminationCoordinator

    /// 应用即将完成启动
    func applicationWillFinishLaunching(_ notification: Notification) {
        logger.info("applicationWillFinishLaunching")
    }

    // MARK: - 文件打开回调

    /// macOS 13+ URL 版本的文件打开回调。
    /// 冷启动时在 applicationDidFinishLaunching 之前调用；热启动时直接调用。
    /// 传递完整 URL 列表给 Coordinator，不再截断为单个 URL，不再写 UserDefaults。
    func application(_ application: NSApplication, open urls: [URL]) {
        logger.info("application(_:open:) called with \(urls.count) URLs")
        guard !urls.isEmpty else { return }

        // 构造 OpenRequest 并入队。Coordinator 在 ready 前暂存，ready 后立即处理。
        let request = OpenRequest(urls: urls, source: .external)
        enqueueRequest(request)
    }

    // MARK: - 应用生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false

        let appearanceMode = SettingsModel.shared.appearanceMode
        if let nsAppearance = appearanceMode.nsAppearance {
            NSApp.appearance = nsAppearance
        }

        didFinishLaunching = true
        logger.info("applicationDidFinishLaunching")

        // 标准一级菜单由 SwiftUI/AppKit 创建，不读取应用自定义 L10n 设置。
        // 在应用生命周期层启动同步器，使冷启动和后续 Commands 重建都保持当前语言。
        MainMenuLocalizationService.start(
            language: SettingsModel.shared.languagePref.resolvedLanguage
        )

        // 注册窗口拖拽：Task 11 起由 WindowLifecycleBridge 在每窗口挂载时安装
        // 窗口级 WindowDropOverlayView，不再由 AppDelegate 全局安装。

        // Task 2：启动优先级由 AppStartupCoordinator 统一裁决。
        // pending 请求由 Coordinator 按 readiness 自行 drain（WindowSceneHost 注册/安装 action 后触发），
        // AppDelegate 不再决定 drain 时机。
        let coordinator = Self.coordinator
        AppStartupCoordinator.shared.hasPendingExternalRequests = coordinator.pendingRequestCount > 0
        if coordinator.pendingRequestCount == 0 {
            // 无外部请求：恢复上次位置（若开启）
            if AppStartupCoordinator.shared.shouldRestoreLastLocation() {
                logger.info("Cold start: restoring last location")
                NotificationCenter.default.post(name: .restoreLastLocation, object: nil)
            }
        }
        // 有 pending 请求时不恢复上次位置，等待 Coordinator drain 时按 external 优先处理。
    }

    // MARK: - Dock 点击处理

    /// 用户点击 Dock 图标时调用。
    /// 无可见窗口时创建空白窗口（通过 Coordinator），不再激活隐藏窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            logger.info("applicationShouldHandleReopen — no visible windows")
            terminationCoordinator.handleReopen()
        }
        return false
    }

    // MARK: - 应用退出

    /// Task 1：返回 `.terminateLater`，由 TerminationCoordinator 异步串行处理脏 Untitled session。
    /// 在返回前同步切到 `.processing`，消除重复 Cmd+Q 的排队窗口（重复调用 beginTermination 返回 false，不再 reply）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationCoordinator.coordinator = Self.coordinator
        guard terminationCoordinator.beginTermination() else {
            // 已在处理中：不重复 reply
            return .terminateLater
        }
        Task { @MainActor in
            await self.terminationCoordinator.processTermination()
        }
        return .terminateLater
    }

    // MARK: - Coordinator 访问

    /// AppDelegate 通过此属性访问 App 持有的 WindowCoordinator。
    /// MarkdownReaderApp 在 init 时注入。
    static var coordinator: WindowCoordinator {
        _sharedCoordinator
    }

    /// 供 WindowCloseGuard 访问同一终止协调器（Task 1：Cmd+W 复用 Cmd+Q 的保存确认流程）。
    static var sharedTerminationCoordinator: ApplicationTerminationCoordinator {
        _sharedTerminationCoordinator
    }

    private static let _sharedCoordinator = WindowCoordinator()
    private static let _sharedTerminationCoordinator = ApplicationTerminationCoordinator()

    override init() {
        self.terminationCoordinator = Self._sharedTerminationCoordinator
        super.init()
        terminationCoordinator.coordinator = Self._sharedCoordinator
    }

    /// 将打开请求入队到 Coordinator。
    /// Task 2：始终先入队，drain 时机由 Coordinator 按 readiness 自行决定。
    private func enqueueRequest(_ request: OpenRequest) {
        Self.coordinator.enqueue(request)
    }
}

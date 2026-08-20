import SwiftUI
import MarkdownReaderKit
import WebKit

@main
struct MarkdownReaderApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 自动更新 ViewModel（Task 13：应用级共享实例）。
    @State private var updateViewModel = UpdateViewModel.shared

    /// 应用级窗口协调器：每个窗口共享同一 Coordinator，统一路由与所有权。
    /// 由 App 持有，注入到每个 ContentView 的 WindowSession（Task 5/6）。
    /// Task 8：AppDelegate 和 App 共享同一 Coordinator 实例。
    @State private var windowCoordinator = AppDelegate.coordinator

    init() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 当前界面语言（从共享 SettingsModel 读取，用于菜单等非视图场景）
    private var language: Language {
        SettingsModel.shared.languagePref.resolvedLanguage
    }

    /// 最近打开记录（从 SettingsModel 读取，用于菜单动态生成）
    private var recentItems: [RecentItem] {
        SettingsModel.shared.recentItems
    }

    /// 打开最近的子菜单（文件在上、目录在下，不显示分区标题）
    @ViewBuilder
    private var openRecentMenu: some View {
        if recentItems.isEmpty {
            Text(L10n.tr(.openRecentEmpty, language: language))
                .disabled(true)
        } else {
            Menu(L10n.tr(.openRecent, language: language)) {
                let files = recentItems.filter { !$0.isDirectory }
                let folders = recentItems.filter { $0.isDirectory }

                // 文件列表
               ForEach(files) { item in
                   Button {
                        windowCoordinator.enqueue(OpenRequest(url: item.url, source: .openRecent))
                   } label: {
                       HStack {
                           Image(systemName: "doc.text")
                           Text(item.displayName)
                       }
                   }
               }

               // 分隔线（文件和目录都有时显示）
               if !files.isEmpty && !folders.isEmpty {
                   Divider()
               }

               // 目录列表
               ForEach(folders) { item in
                   Button {
                        windowCoordinator.enqueue(OpenRequest(url: item.url, source: .openRecent))
                   } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(item.displayName)
                        }
                    }
                }

                Divider()

                Button(L10n.tr(.clearRecentItems, language: language)) {
                    SettingsModel.shared.clearRecentItems()
                }
            }
        }
    }

    var body: some Scene {
        // data-driven WindowGroup（Task 6）：每个窗口绑定一个 WindowID，
        // 由 WindowSceneHost 创建对应 WindowSession 并注入 ContentView。
        // 同一 WindowID 的窗口会被 SwiftUI 复用/前置而非重建（见 WindowID 注释）。
        WindowGroup(
            "Markdown Reader",
            id: WindowSceneID.document,
            for: WindowID.self
        ) { $windowID in
            // defaultValue 提供 WindowID；$windowID 为非可选 Binding<WindowID>
            WindowSceneHost(windowID: windowID, coordinator: windowCoordinator)
               // .onOpenURL 在 macOS 15+ 不触发 file-open 事件
               // 保留作为安全网，以防未来 macOS 版本行为变化
               .onOpenURL { url in
                    // Task 8：通过 Coordinator 统一路由
                    windowCoordinator.enqueue(OpenRequest(url: url, source: .external))
               }
                // 热启动时路由到现有窗口，而非创建新窗口
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                // 自动更新弹窗（应用级 UpdateViewModel.shared）
                .sheet(isPresented: $updateViewModel.isShowingUpdateSheet) {
                    UpdateView(viewModel: updateViewModel)
                }
                // Task 13：应用级一次性服务（WebView 预热 + 自动更新检查）
                // 由 AppStartupCoordinator 幂等执行，不在每窗口 .task 重复。
                .task {
                    AppStartupCoordinator.shared.performAppLevelStartupOnce()
                }
                // 监听手动检查更新通知
                .onReceive(NotificationCenter.default.publisher(for: .checkForUpdates)) { _ in
                    updateViewModel.checkForUpdatesManually()
                }
        } defaultValue: {
            WindowID()
        }
        .restorationBehavior(.disabled)
        // .handlesExternalEvents(matching:) scene modifier 已移除
        // 冷启动时 ContentView.task 通过 UserDefaults 读取 AppDelegate 写入的文件路径，
        // 无需 SwiftUI 为外部事件创建额外窗口，避免出现双窗口问题
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)
        .windowResizability(.automatic)
        // Task 7：窗口级菜单命令经 FocusedValues 路由到焦点窗口，
        // 应用级命令（About / 检查更新 / 帮助 / 清除最近记录）保留应用服务调用。
        .commands {
            MarkdownReaderCommands(language: language)

            // 打开最近子菜单（文件打开入口由 Task 8 统一路由，此处保留 recent 菜单结构）
            CommandGroup(after: .newItem) {
                openRecentMenu
            }

            // 回归修复（需求 §7.3 / MW-11）：补全标准 Window 菜单——列出主窗口、
            // 激活目标窗口，并保留 Minimize / Zoom / Bring All to Front。
            CommandGroup(replacing: .windowList) {
                windowListMenu
            }
            CommandGroup(replacing: .windowArrangement) {
                standardWindowArrangementMenu
            }
        }
    }

    // MARK: - Window 菜单

    /// Window 菜单：列出所有可见主窗口，点击激活对应窗口。
    @ViewBuilder
    private var windowListMenu: some View {
        let visible = windowCoordinator.visibleWindowIDs()
        if visible.isEmpty {
            Text(L10n.tr(.openRecentEmpty, language: language))
                .disabled(true)
        } else {
            ForEach(visible, id: \.rawValue) { windowID in
                Button(windowTitle(for: windowID)) {
                    windowCoordinator.activate(windowID: windowID)
                }
            }
        }
    }

    /// 标准窗口排列项：Minimize / Zoom / Bring All to Front。
    @ViewBuilder
    private var standardWindowArrangementMenu: some View {
        Button(L10n.tr(.windowMenuMinimize, language: language)) {
            NSApp.keyWindow?.miniaturize(nil)
        }
        .keyboardShortcut("m", modifiers: .command)
        .disabled(NSApp.keyWindow == nil)

        Button(L10n.tr(.windowMenuZoom, language: language)) {
            NSApp.keyWindow?.zoom(nil)
        }
        .disabled(NSApp.keyWindow == nil)

        Divider()

        Button(L10n.tr(.windowMenuBringAllToFront, language: language)) {
            NSApp.arrangeInFront(nil)
        }
    }

    /// 返回某窗口在 Window 菜单中的显示标题（区分文件/目录/Untitled）。
    private func windowTitle(for windowID: WindowID) -> String {
        guard let session = windowCoordinator.sessions[windowID] else {
            return "Markdown Reader"
        }
        let appVM = session.appViewModel
        let docVM = session.documentViewModel
        if docVM.isUntitled {
            return docVM.fileName.isEmpty ? "Untitled" : docVM.fileName
        }
        if appVM.isSingleFileMode, let url = appVM.singleFileURL {
            return url.lastPathComponent
        }
        if let workspaceURL = appVM.workspaceFileURL {
            return workspaceURL.lastPathComponent
        }
        if appVM.rootDirectories.count > 1 {
            return L10n.tr(.workspaceUntitledName, language: SettingsModel.shared.languagePref.resolvedLanguage)
        }
        if let dir = appVM.rootDirectory {
            return dir.lastPathComponent
        }
        if let url = docVM.currentFileURL {
            return url.lastPathComponent
        }
        return "Markdown Reader"
    }
}

// MARK: - Notification Names

extension Notification.Name {
    // 回归修复：多窗口改造后窗口级命令已迁移到 FocusedValues（WindowCommandTarget）或
    // 所属 session 直接调用，不再使用全局 NotificationCenter 广播。下面仅保留仍有合法
    // 调用方的应用级 / 跨场景通知；已失去调用方的窗口级广播常量已删除，避免后续误用。

    /// 恢复上次打开位置（冷启动由 AppDelegate 发起，所有窗口监听，但仅无资源的窗口响应）。
    static let restoreLastLocation = Notification.Name("com.markdownreader.restoreLastLocation")
    /// 重置到欢迎页（Dock 重开等场景）。
    static let resetToWelcome = Notification.Name("com.markdownreader.resetToWelcome")
    /// 应用级：检查更新（菜单触发，UpdateViewModel 监听）。
    static let checkForUpdates = Notification.Name("com.markdownreader.checkForUpdates")
}


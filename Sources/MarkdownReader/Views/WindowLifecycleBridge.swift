import SwiftUI
import AppKit

/// 窗口生命周期桥接器（Task 6）。
///
/// 以 0 尺寸 NSViewRepresentable 挂在 ContentView 背景，负责：
/// 1. 窗口挂载时把真实 `NSWindow` 回填给 `session.window`，并通知 Coordinator 关联；
/// 2. 窗口即将关闭时调用 `session.dispose()`，释放所有权与注册项。
///
/// 不依赖 NSWindowDelegate 的 `windowWillClose`（已有 `WindowCloseGuard` 占用代理），
/// 而是用 `NSWindow.willCloseNotification` 观察具体窗口，避免代理冲突。
struct WindowLifecycleBridge: View {
    let session: WindowSession

    var body: some View {
        LifecycleAnchor(session: session)
            .frame(width: 0, height: 0)
    }
}

private struct LifecycleAnchor: NSViewRepresentable {
    let session: WindowSession

    func makeNSView(context: Context) -> NSView {
        let view = LifecycleAnchorView()
        view.session = session
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? LifecycleAnchorView)?.session = session
    }

    private final class LifecycleAnchorView: NSView {
        weak var session: WindowSession?
        // 观察者注册表。viewDidMoveToWindow 每次切换窗口时先清空旧观察者，
        // 不依赖 deinit 清理（Swift 6 下非 Sendable 属性不可在 deinit 中访问）。
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 离开旧窗口：同步移除观察者
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers.removeAll()

            guard let window, let session else { return }

           // 1. 回填 NSWindow 给 session，并通知 Coordinator 关联窗口
           session.window = window
           session.coordinator?.attach(window: window, to: session.id)

            // Task 10：绑定 undoStore 到 NSWindow，使 swizzled getter 无需全局状态
            window.undoStore = session.undoStore

            // Task 11：安装本窗口专属的文件拖拽 overlay。
            // overlay 回调直接路由到 Coordinator 并携带本 session 的 windowID，
            // 不再发全局通知（dragHoverChanged/unsupportedFileTypeDropped）。
            installDropOverlay(in: window, for: session)

            // 2. 观察该窗口关闭，同步触发 dispose（Task 3）。
            //    `willCloseNotification` 在窗口真正开始关闭时同步投递（queue: .main，主线程）。
            //    此处直接同步 dispose，确保收到通知后、任何下一次路由判断前，该窗口已从
            //    registeredIDs / sessions / windows / 资源所有权表移除。
            //    不再用 `Task { @MainActor }` 推迟一个 tick——推迟会让关闭中的窗口在路由快照中
            //    短暂残留为「空白可复用窗口」，导致资源被错误复用。
            //    Swift 6 无法从 `queue: .main` 闭包自动推导 MainActor 隔离，用
            //    `MainActor.assumeIsolated` 显式声明此时已在主线程。
            let close = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.session?.dispose()
                }
            }
            observers = [close]
        }

        /// 安装窗口级拖拽 overlay（Task 11）。
        /// overlay 持有 session 回调：hover 与 unsupported 只更新本窗口 DetailView，
        /// 打开经 Coordinator 路由（preferredWindowID = 本窗口，空白时复用）。
        private func installDropOverlay(in window: NSWindow, for session: WindowSession) {
            guard let contentView = window.contentView,
                  let themeFrame = contentView.superview else { return }
            // 已存在则不重复安装
            if themeFrame.subviews.contains(where: { $0 is WindowDropOverlayView }) { return }

            let overlay = WindowDropOverlayView()
            overlay.session = session
            themeFrame.addSubview(overlay)
            overlay.frame = themeFrame.bounds
            overlay.autoresizingMask = [.width, .height]
        }
    }
}

// MARK: - 窗口级文件拖拽 overlay（Task 11）

/// 每窗口一份的拖拽 overlay，替代 AppDelegate 全局安装 + 全局通知。
/// hover/open/unsupported 回调直接作用于所属 session，不经 NotificationCenter。
final class WindowDropOverlayView: NSView {

    private static let supportedExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]

    /// 所属会话。弱引用避免环；session 释放后回调为 no-op。
    weak var session: WindowSession?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
    }

    override func draw(_ dirtyRect: NSRect) {}

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard canAcceptDrag(sender) else { return [] }
        session?.appViewModel.isDropTargeted = true
        updateDropZone(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // 悬停位置可能在侧边栏与内容区之间移动，实时更新高亮区域
        updateDropZone(sender)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        session?.appViewModel.isDropTargeted = false
        session?.appViewModel.isSidebarDropTargeted = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        session?.appViewModel.isDropTargeted = false
        session?.appViewModel.isSidebarDropTargeted = false

        let pasteboard = sender.draggingPasteboard
        let urls: [URL]
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self],
                                                   options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !fileURLs.isEmpty {
            urls = fileURLs
        } else if let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String],
                  !paths.isEmpty {
            urls = paths.map { URL(fileURLWithPath: $0) }
        } else {
            return false
        }
        guard !urls.isEmpty else { return false }

        // 落在侧边栏区域：目录 → 添加文件夹到工作区；文件仍走统一路由打开。
        // 侧边栏是 SwiftUI 子树，本 overlay 位于其上层会优先收到拖拽，
        // 因此分流必须在本层完成（SwiftUI dropDestination 无法抢占）。
        if dropIsInsideSidebar(sender), let session {
            var fileURLsToOpen: [URL] = []
            for url in urls {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                   isDir.boolValue {
                    session.addDroppedFolder(url)
                } else {
                    fileURLsToOpen.append(url)
                }
            }
            if !fileURLsToOpen.isEmpty {
                session.coordinator?.enqueue(
                    OpenRequest(urls: fileURLsToOpen, source: .dragDrop, preferredWindowID: session.id)
                )
            }
            return true
        }

        // Task 11：经 Coordinator 路由，preferredWindowID 为本窗口（空白时复用，否则新窗口）
        let request = OpenRequest(urls: urls, source: .dragDrop, preferredWindowID: session?.id)
        session?.coordinator?.enqueue(request)
        return true
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    /// 拖拽落点是否位于侧边栏区域内（仅比较横向坐标，与翻转坐标系无关）。
    private func dropIsInsideSidebar(_ sender: any NSDraggingInfo) -> Bool {
        guard let session,
              session.appViewModel.isSidebarVisible,
              session.appViewModel.sidebarWidth > 0,
              let contentView = session.window?.contentView else { return false }
        // draggingLocation 为窗口坐标系（左下角原点），转换到 contentView 后取 x
        let locationInContent = contentView.convert(sender.draggingLocation, from: nil)
        return locationInContent.x >= 0 && locationInContent.x <= session.appViewModel.sidebarWidth
    }

    /// 根据悬停位置更新拖拽高亮区域（侧边栏 vs 内容区）。
    private func updateDropZone(_ sender: any NSDraggingInfo) {
        session?.appViewModel.isSidebarDropTargeted = dropIsInsideSidebar(sender)
    }

    private func canAcceptDrag(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if pasteboard.canReadObject(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        if pasteboard.types?.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType")) == true {
            return true
        }
        return false
    }
}

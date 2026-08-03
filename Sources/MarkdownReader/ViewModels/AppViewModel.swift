import SwiftUI
import MarkdownReaderKit

/// 设置标签页，供 AppViewModel 和 ContentView 使用
enum SettingsTab: String, CaseIterable {
    case general
    case appearance
}

/// 全局应用状态，管理窗口级别的状态
@MainActor
@Observable
final class AppViewModel {

    // MARK: - 目录状态

    /// 当前打开的根目录
    var rootDirectory: URL? {
        didSet { updateWindowTitle() }
    }

    /// 是否为单文件模式（直接打开单个文件，无目录树）
    var isSingleFileMode: Bool = false

    /// 单文件模式下打开的文件 URL
    var singleFileURL: URL?

    // MARK: - 选中状态

    /// 当前选中的文件节点
    var selectedFile: FileNode?

    // MARK: - Sidebar 状态

    /// Sidebar 是否可见（首次启动默认隐藏）
    var isSidebarVisible: Bool = false

    /// Sidebar 所属的目录上下文。
    ///
    /// `SidebarView` 为规避 AppKit hit-testing 问题会一直保留在视图树中，并以 0 宽度隐藏。
    /// 从欢迎页首次进入目录模式时，SwiftUI 偶尔会保留这份 0 宽度布局；以根目录作为身份
    /// 可在目录上下文变化时重建 Sidebar 子树，同时避免普通显隐操作反复销毁视图。
    var sidebarPresentationIdentity: String {
        rootDirectory?.standardizedFileURL.path ?? "welcome"
    }

    /// Sidebar 当前宽度
    var sidebarWidth: CGFloat = 240

    /// Sidebar 默认宽度
    static let defaultSidebarWidth: CGFloat = 240

    /// Sidebar 最小宽度
    static let minSidebarWidth: CGFloat = 150

    /// Sidebar 最大宽度
    static let maxSidebarWidth: CGFloat = 400

    /// Sidebar 自动隐藏阈值
    static let sidebarHideThreshold: CGFloat = 140

    // MARK: - 大纲状态

    /// 大纲侧边栏是否可见
    var isOutlineVisible: Bool = false

    /// 编辑模式是否启用左右分栏实时预览（默认关闭，由标题栏按钮切换）
    var isSplitPreviewEnabled: Bool = false

    /// 大纲侧边栏宽度
    var outlineWidth: CGFloat = 200

    /// 大纲侧边栏默认宽度
    static let defaultOutlineWidth: CGFloat = 200

    /// 大纲侧边栏最小宽度
    static let minOutlineWidth: CGFloat = 150

    /// 大纲侧边栏最大宽度
    static let maxOutlineWidth: CGFloat = 350

    // MARK: - 设置状态

    /// 是否显示设置界面（窗口内状态切换，而非弹窗）
    var isShowingSettings: Bool = false

    /// 设置界面的当前标签页
    var settingsTab: SettingsTab = .general

    // MARK: - 窗口标题

    /// 窗口标题
    var windowTitle: String = "Markdown Reader"

    // MARK: - 全屏状态

    /// 是否处于全屏模式
    var isFullScreen: Bool = false

    // MARK: - 查找替换状态

    /// 查找面板是否可见
    var isFindBarVisible: Bool = false

    // MARK: - 拖拽状态（Task 11：窗口级）

    /// 文件拖拽悬停于本窗口。由本窗口的 WindowDropOverlayView 直接写入，
    /// 不再经全局通知，确保多窗口下只高亮被拖入的窗口。
    var isDropTargeted: Bool = false

    // MARK: - 命令面板状态

    /// 命令面板是否可见
    var isCommandPaletteVisible: Bool = false

    // MARK: - 方法

    /// 切换 Sidebar 显隐
    func toggleSidebar() {
        withAnimation(.spring(duration: 0.25)) {
            isSidebarVisible.toggle()
            if isSidebarVisible {
                sidebarWidth = Self.defaultSidebarWidth
            }
        }
    }

    /// 切换大纲侧边栏显隐
    func toggleOutline() {
        withAnimation(.spring(duration: 0.25)) {
            isOutlineVisible.toggle()
            if isOutlineVisible {
                outlineWidth = Self.defaultOutlineWidth
            }
        }
    }

    /// 切换编辑模式分栏预览
    func toggleSplitPreview() {
        withAnimation(.spring(duration: 0.25)) {
            isSplitPreviewEnabled.toggle()
        }
    }

    /// 切换查找面板显隐
    func toggleFindBar(expandReplace: Bool = false) {
        withAnimation(.easeOut(duration: 0.2)) {
            isFindBarVisible.toggle()
        }
    }

    /// 显示查找面板
    func showFindBar(expandReplace: Bool = false) {
        withAnimation(.easeOut(duration: 0.2)) {
            isFindBarVisible = true
        }
    }

    /// 隐藏查找面板
    func hideFindBar() {
        withAnimation(.easeOut(duration: 0.2)) {
            isFindBarVisible = false
        }
    }

    /// 显示命令面板
    func showCommandPalette() {
        withAnimation(.easeOut(duration: 0.15)) {
            isCommandPaletteVisible = true
        }
    }

    /// 隐藏命令面板
    func hideCommandPalette() {
        withAnimation(.easeOut(duration: 0.15)) {
            isCommandPaletteVisible = false
        }
    }

    /// 切换命令面板
    func toggleCommandPalette() {
        if isCommandPaletteVisible {
            hideCommandPalette()
        } else {
            showCommandPalette()
        }
    }

    /// 进入设置界面
    func showSettings(tab: SettingsTab = .general) {
        settingsTab = tab
        withAnimation(.easeInOut(duration: 0.2)) {
            isShowingSettings = true
        }
    }

    /// 退出设置界面
    func hideSettings() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isShowingSettings = false
        }
    }

    /// 切换设置界面（Cmd+, 快捷键使用）
    func toggleSettings() {
        if isShowingSettings {
            hideSettings()
        } else {
            showSettings()
        }
    }

    /// 更新 Sidebar 宽度（拖拽时调用）
    func updateSidebarWidth(_ width: CGFloat) {
        sidebarWidth = width
    }

    /// 处理拖拽结束，判断是否隐藏 Sidebar
    func handleDragEnded() {
        if sidebarWidth < Self.sidebarHideThreshold {
            withAnimation(.spring(duration: 0.25)) {
                isSidebarVisible = false
                sidebarWidth = Self.defaultSidebarWidth
            }
        } else {
            // 限制宽度范围
            sidebarWidth = max(Self.minSidebarWidth, min(Self.maxSidebarWidth, sidebarWidth))
        }
    }

    /// 更新大纲侧边栏宽度（拖拽时调用）
    func updateOutlineWidth(_ width: CGFloat) {
        outlineWidth = width
    }

    /// 处理大纲侧边栏拖拽结束，限制宽度范围
    func handleOutlineDragEnded() {
        outlineWidth = max(Self.minOutlineWidth, min(Self.maxOutlineWidth, outlineWidth))
    }

    /// 打开目录
    ///
    /// 目录模式下目录树是主要操作入口，因此无论此前 Sidebar 是否隐藏，
    /// 打开目录成功后必须保证 Sidebar 可见。
    /// - 已显示 Sidebar：保留用户调整过的宽度，不重置；
    /// - 从隐藏切到显示：若宽度无效（被收起操作压到阈值以下），恢复默认宽度。
    func openDirectory(_ url: URL) {
        rootDirectory = url
        isSingleFileMode = false
        singleFileURL = nil
        selectedFile = nil
        // 目录模式恢复 Sidebar
        if !isSidebarVisible {
            // OpenPanel 的 sheet 正在结束时启动宽度动画，SwiftUI 偶尔会把 Sidebar
            // 留在动画起点（0 宽度），直到用户手动显隐两次才重新布局。
            // 自动进入目录模式需要确定性布局，因此同步显示；用户主动 Cmd+\ 仍使用动画。
            isSidebarVisible = true
            if sidebarWidth < Self.minSidebarWidth {
                sidebarWidth = Self.defaultSidebarWidth
            }
        }
    }

    /// 打开单个文件（单文件模式，Sidebar 默认隐藏但可手动打开）
    func openSingleFile(_ url: URL) {
        // 先设置单文件模式属性，再清空 rootDirectory
        // 因为 rootDirectory 的 didSet 会调用 updateWindowTitle()
        // 如果先清空 rootDirectory，此时 isSingleFileMode/singleFileURL 尚未设置
        // 会导致窗口标题无法正确显示文件名
        isSingleFileMode = true
        singleFileURL = url
        selectedFile = nil
        rootDirectory = nil
        if isSidebarVisible {
            withAnimation(.spring(duration: 0.25)) {
                isSidebarVisible = false
            }
        }
    }

    // MARK: - 私有方法

    var hasUnsavedUntitled: Bool = false
    var untitledFileName: String = ""

    private func updateWindowTitle() {
        if hasUnsavedUntitled {
            windowTitle = "Markdown Reader — \(untitledFileName)"
        } else if isSingleFileMode, let url = singleFileURL {
            windowTitle = "Markdown Reader — \(url.lastPathComponent)"
        } else if let dir = rootDirectory {
            windowTitle = "Markdown Reader — \(dir.lastPathComponent)"
        } else {
            windowTitle = "Markdown Reader"
        }
    }
}

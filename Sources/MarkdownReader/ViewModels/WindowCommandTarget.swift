import SwiftUI

/// 窗口命令目标（Task 7）。
///
/// FocusedValues 的载体：菜单命令经 SwiftUI 焦点系统路由到当前焦点窗口的 target，
/// target 弱引用所绑定的 `WindowSession`，命令只作用于该 session。
///
/// 视图层（DetailView/WebViewMarkdownView）把 reload/exportPDF/find/zoom 等需要
/// UI 上下文的 handler 注册到 target，使菜单命令也能触达这些仅存在于视图层的能力。
@MainActor
final class WindowCommandTarget {
    weak var session: WindowSession?

    /// 视图层注册的命令回调。nil 表示该命令在当前窗口无可用 handler。
    var reloadHandler: (() -> Void)?
    var exportPDFHandler: (() -> Void)?
    var findHandler: ((FindCommand) -> Void)?
    var zoomHandler: ((ZoomCommand) -> Void)?

    init(session: WindowSession?) {
        self.session = session
    }

    /// 用于 SwiftUI `onChange` 追踪 target 身份变化（窗口切换时重注册 handler）。
    var objectIdentifier: ObjectIdentifier { ObjectIdentifier(self) }

    /// 执行窗口级命令。session 已释放时为 no-op。
    func perform(_ command: WindowCommand) {
        guard let session else { return }
        switch command {
       case .newFile:
           session.handleNewFile()
        case .openPanel:
            session.openFromPanel()
        case .save:
            session.handleSave()
        case .saveAs:
            session.handleSaveAs()
        case .exportPDF:
            exportPDFHandler?()
        case .reloadFile:
            reloadHandler?()
        case .toggleSidebar:
            session.appViewModel.toggleSidebar()
        case .toggleSettings:
            session.appViewModel.toggleSettings()
        case .toggleCommandPalette:
            session.appViewModel.toggleCommandPalette()
        case .switchDisplayMode(let mode):
            session.documentViewModel.switchDisplayMode(mode)
        case .zoomIn:
            zoomHandler?(.in)
        case .zoomOut:
            zoomHandler?(.out)
        case .zoomReset:
            zoomHandler?(.reset)
        case .findInDocument:
            findHandler?(.find)
        case .findNext:
            findHandler?(.findNext)
        case .findPrevious:
            findHandler?(.findPrevious)
        case .findAndReplace:
            findHandler?(.findAndReplace)
        }
    }

    /// 创建空白窗口（应用级能力，经 Coordinator 路由）。
    func openBlankWindow() {
        session?.coordinator?.openBlankWindow()
    }
}

// MARK: - 子命令

/// 查找子命令。
enum FindCommand: Sendable {
    case find
    case findNext
    case findPrevious
    case findAndReplace
}

/// 缩放子命令。
enum ZoomCommand: Sendable {
    case `in`
    case out
    case reset
}

// MARK: - FocusedValues

/// 兼容 Command Line Tools 工具链：不依赖 SwiftUI `@Entry` 宏（CLTs 缺少 SwiftUIMacros 插件）。
private struct WindowCommandTargetKey: FocusedValueKey {
    typealias Value = WindowCommandTarget
}

extension FocusedValues {
    /// 焦点窗口的命令目标。菜单命令读取此值并转发。
    var windowCommandTarget: WindowCommandTarget? {
        get { self[WindowCommandTargetKey.self] }
        set { self[WindowCommandTargetKey.self] = newValue }
    }
}

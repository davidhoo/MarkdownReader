import Foundation
import MarkdownReaderKit

/// 窗口级命令枚举（Task 7）。
///
/// 替代原本无目标的 `Notification.Name` 广播：菜单命令通过 FocusedValues 路由到
/// 焦点窗口的 `WindowCommandTarget`，由 target 转发给所绑定的 `WindowSession`。
/// 同一命令只作用于当前焦点窗口，不广播给全部窗口。
enum WindowCommand: Sendable {
    case newFile
    case openPanel
    case save
    case saveAs
    case addFolderToWorkspace
    case saveWorkspace
    case saveWorkspaceAs
    case exportPDF
    case reloadFile
    case toggleSidebar
    case toggleSettings
    case toggleCommandPalette
    case switchDisplayMode(DisplayMode)
    case zoomIn
    case zoomOut
    case zoomReset
    case findInDocument
    case findNext
    case findPrevious
    case findAndReplace
}

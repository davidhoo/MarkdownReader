import SwiftUI
import MarkdownReaderKit

/// 窗口级菜单命令（Task 7 / 回归修复）。
///
/// 关键约束（回归根因 1）：`@FocusedValue(\.windowCommandTarget)` 必须在 `Commands`
/// 结构体级声明并读取，**禁止**在按钮 closure 内临时创建。临时 property wrapper 无法
/// 稳定获得 SwiftUI 焦点环境，会导致 `windowCommandTarget` 通常为 `nil`，命令静默
/// 成为 no-op。
///
/// 命令只作用于当前焦点窗口（由 `WindowSceneHost` 唯一发布的 scene 级 target）。
/// 应用级命令（About / 检查更新 / 清除最近记录 / 帮助 / 新建窗口）仍走应用服务或
/// Coordinator。
struct MarkdownReaderCommands: Commands {

    /// 当前界面语言（非视图场景）。
    let language: Language

    /// 焦点窗口的命令目标。结构体级声明，使菜单项据此启用/禁用与转发。
    @FocusedValue(\.windowCommandTarget) private var target: WindowCommandTarget?

    var body: some Commands {
        // 文件菜单：新建 + 新建窗口 + 打开 + 保存 + 另存为 + 导出 PDF
        CommandGroup(replacing: .newItem) {
            Button(L10n.tr(.menuNewFile, language: language)) {
                target?.perform(.newFile)
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(target == nil)

            Button(L10n.tr(.menuNewWindow, language: language)) {
                // 新建窗口为应用级能力：经 Coordinator 创建空白窗口。
                target?.openBlankWindow() ?? AppDelegate.coordinator.openBlankWindow()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button(L10n.tr(.open, language: language) + "...") {
                target?.perform(.openPanel)
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(target == nil)

            Button(L10n.tr(.titleBarSave, language: language)) {
                target?.perform(.save)
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(target == nil)

            Button(L10n.tr(.menuSaveAs, language: language)) {
                target?.perform(.saveAs)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(target == nil)

            Divider()

            Button(L10n.tr(.menuAddFolderToWorkspace, language: language)) {
                target?.perform(.addFolderToWorkspace)
            }
            .disabled(target == nil)

            Button(L10n.tr(.menuSaveWorkspace, language: language)) {
                target?.perform(.saveWorkspace)
            }
            .disabled(target == nil)

            Button(L10n.tr(.menuSaveWorkspaceAs, language: language)) {
                target?.perform(.saveWorkspaceAs)
            }
            .disabled(target == nil)

            Divider()

            Button(L10n.tr(.exportPDF, language: language)) {
                target?.perform(.exportPDF)
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(target == nil)
        }

        // 替换系统默认 Save/Save As：仅保留关闭（Cmd+W），保存面板走自定义路由
        CommandGroup(replacing: .saveItem) {
            Button(L10n.tr(.closeWindow, language: language)) {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: .command)
        }

        // 设置菜单：Cmd+, 切换窗口内设置；检查更新为应用级
        CommandGroup(replacing: .appSettings) {
            Button(L10n.tr(.settingsMenuLabel, language: language)) {
                target?.perform(.toggleSettings)
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(target == nil)

            Button(L10n.tr(.checkForUpdates, language: language)) {
                NotificationCenter.default.post(name: .checkForUpdates, object: nil)
            }
        }

        // 关于（应用级）
        CommandGroup(replacing: .appInfo) {
            Button(L10n.tr(.aboutTitle, language: language)) {
                AboutWindowController.show(language: language)
            }
        }

        // 视图菜单
        CommandGroup(after: .toolbar) {
            Button(L10n.tr(.titleBarToggleSidebar, language: language)) {
                target?.perform(.toggleSidebar)
            }
            .keyboardShortcut("\\", modifiers: .command)
            .disabled(target == nil)

            Button(L10n.tr(.commandPaletteTitle, language: language)) {
                target?.perform(.toggleCommandPalette)
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(target == nil)

            Divider()

            Button(L10n.tr(.displayModeRendered, language: language)) {
                target?.perform(.switchDisplayMode(.rendered))
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(target == nil)

            Button(L10n.tr(.displayModeRaw, language: language)) {
                target?.perform(.switchDisplayMode(.raw))
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(target == nil)

            Divider()

            Button(L10n.tr(.viewZoomIn, language: language)) {
                target?.perform(.zoomIn)
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(target == nil)

            Button(L10n.tr(.viewZoomOut, language: language)) {
                target?.perform(.zoomOut)
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(target == nil)

            Button(L10n.tr(.viewZoomReset, language: language)) {
                target?.perform(.zoomReset)
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(target == nil)
        }

        // 查找菜单
        CommandMenu(L10n.tr(.findBarFind, language: language)) {
            Button(L10n.tr(.findBarFind, language: language) + "\u{2026}") {
                target?.perform(.findInDocument)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(target == nil)

            Button(L10n.tr(.findBarFindNext, language: language)) {
                target?.perform(.findNext)
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(target == nil)

            Button(L10n.tr(.findBarFindPrevious, language: language)) {
                target?.perform(.findPrevious)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(target == nil)

            Button(L10n.tr(.findBarFindAndReplace, language: language) + "\u{2026}") {
                target?.perform(.findAndReplace)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(target == nil)
        }

        // 帮助菜单（应用级）
        CommandGroup(replacing: .help) {
            Button(L10n.tr(.helpMarkdownReader, language: language)) {
                if let url = URL(string: "https://davidhoo.github.io/MarkdownReader/help.html") {
                    NSWorkspace.shared.open(url)
                }
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}

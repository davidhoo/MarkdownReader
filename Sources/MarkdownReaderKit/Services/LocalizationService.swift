import SwiftUI

// MARK: - 本地化服务

/// 简易本地化服务，参照 buddy-macos 的 i18n 字典方案
/// 使用扁平 key-value 结构，支持插值 {n}
public enum L10n {

    // MARK: - Key 定义

    /// 所有本地化键，与 buddy-macos 的 settings key 结构对齐
    public enum Key: String, CaseIterable, Sendable {
        // 应用名称
        case appName

        // 设置 - 菜单/导航
        case settingsMenuLabel
        case settingsBackToApp

        // 设置 - 标签页
        case settingsTabGeneral
        case settingsTabAppearance

        // 设置 - 通用
        case settingsGeneralLanguageTitle
        case settingsGeneralLanguageDesc
        case settingsGeneralDisplayTitle
        case settingsGeneralDisplayMode
        case settingsGeneralDefaultSplitPreview

        // 设置 - 渲染宽度
        case settingsGeneralRenderedWidthTitle
        case settingsGeneralRenderedWidthDesc
        case settingsGeneralMaxWidthFollowsWindow

        // 设置 - 启动
        case settingsGeneralStartupTitle
        case settingsGeneralReopenLastLocation

        // 设置 - 文件树
        case settingsGeneralFileTreeTitle
        case settingsGeneralShowHiddenFiles
        case settingsGeneralShowNonMarkdownFiles

        // 设置 - 默认打开程序
        case settingsGeneralDefaultOpenerTitle
        case settingsGeneralDefaultOpenerDesc
        case settingsGeneralSetAsDefault
        case settingsGeneralIsDefault
        case settingsGeneralSetDefaultFailed

        // 设置 - 命令行工具
        case settingsGeneralCommandLineTitle
        case settingsGeneralCommandLineDesc
        case settingsGeneralCommandLineInstalled
        case settingsGeneralCommandLineInstallFailed
        case settingsGeneralCommandLineUninstallFailed

        // 设置 - Quick Look 预览
        case settingsGeneralQuickLookTitle
        case settingsGeneralQuickLookDesc
        case settingsGeneralQuickLookEnabled

        // 设置 - 外观 - 主题模式
        case settingsAppearanceThemeTitle
        case settingsAppearanceThemeDesc
        case settingsAppearanceModeLight
        case settingsAppearanceModeLightDesc
        case settingsAppearanceModeDark
        case settingsAppearanceModeDarkDesc
        case settingsAppearanceModeSystem
        case settingsAppearanceModeSystemDesc

        // 设置 - 外观 - 配色方案
        case settingsAppearanceSchemeTitle
        case settingsAppearanceSchemeDesc

        // 设置 - 外观 - 自定义颜色
        case settingsAppearanceCustomTitle
        case settingsAppearanceCustomDesc
        case settingsAppearanceCustomSurface
        case settingsAppearanceCustomInk
        case settingsAppearanceCustomAccent
        case settingsAppearanceCustomSuccess
        case settingsAppearanceCustomDanger

        // 设置 - 外观 - 对比度
        case settingsAppearanceContrastTitle
        case settingsAppearanceContrastDesc
        case settingsAppearanceContrastLow
        case settingsAppearanceContrastHigh

        // 设置 - 外观 - 字体排版（保留）
        case settingsAppearanceTypographyTitle
        case settingsAppearanceSourceFontSize
        case settingsAppearanceContentPadding

        // 语言选项
        case languageAuto
        case languageZhCN
        case languageZhTW
        case languageEn

        // 显示模式
        case displayModeRendered
        case displayModeRaw

        // 通用操作
        case open
        case save
        case reset
        case confirm

        // 菜单
        case menuNewFile
        case closeWindow

        // 未保存更改提醒
        case unsavedChangesTitle
        case unsavedChangesMessage
        case unsavedSave
        case unsavedDontSave
        case unsavedCancel

        // 文件外部删除提醒
        case fileDeletedTitle
        case fileDeletedMessage
        case fileDeletedSaveAs
        case fileDeletedDiscard

        // 文件外部修改提醒
        case fileModifiedExternallyTitle
        case fileModifiedExternallyMessage
        case fileModifiedExternallyReload
        case fileModifiedExternallyDontRemind

        // 打开最近
        case openRecent
        case openRecentEmpty
        case openRecentFiles
        case openRecentFolders
        case clearRecentItems

        // 标题栏
        case titleBarToggleSidebar
        case titleBarDisplayMode
        case titleBarOpen
        case titleBarNewFile
        case titleBarSave
        case titleBarReload
        case titleBarToggleOutline
        case titleBarToggleSplitPreview
        case titleBarCopyPath
        case titleBarPathCopied

        // 大纲
        case outlineTitle
        case outlineEmpty

        // 侧边栏
        case loading
        case emptyDirectoryMessage
        case sidebarSettings
        case sidebarSettingsButton

        // 欢迎页
        case welcomeOpenFolder
        case welcomePressCmdO
        case selectFileHint
        case welcomeDropHint

        // 右键菜单
        case contextMenuNewFile
        case contextMenuNewSubdirectory
        case contextMenuRename
        case contextMenuMoveTo
        case contextMenuDelete
        case contextMenuReload
        case contextMenuCopyPath

        // 右键菜单 - 对话框
        case contextMenuOpenInFinder

        // 右键菜单 - 对话框
        case renameTitle
        case renameMessage
        case renameEmptyName
        case renameNameExists
        case deleteTitle
        case deleteMessage
        case deleteDirectoryMessage
        case moveSelectFolder

        // 自动更新
        case updateAvailableTitle
        case updateAvailableVersion
        case updateChecking
        case updateUpToDate
        case updateDownload
        case updateDownloading
        case updateDownloadComplete
        case updateInstall
        case updateInstallAndRestart
        case updateInstalling
        case updateLater
        case updateSkipVersion
        case updateCancel
        case updateError
        case updateModeAuto
        case updateModeManual
        case checkForUpdates

        // 查找替换
        case findBarSearchPlaceholder
        case findBarReplacePlaceholder
        case findBarFindNext
        case findBarFindPrevious
        case findBarReplace
        case findBarReplaceAll
        case findBarNoResults
        case findBarCaseSensitive
        case findBarWholeWord
        case findBarRegularExpression
        case findBarFind
        case findBarFindAndReplace

        // 导出 PDF
        case exportPDF
        case titleBarExportPDF
        case exportPDFSuccess
        case exportPDFFailed

        // 拖拽
        case unsupportedFileTypeAlert
        // 缩放
        case viewZoomIn
        case viewZoomOut
        case viewZoomReset
        case aboutTitle
        case aboutDescription
        case aboutRendering
        case aboutMermaid
        case aboutPlantUML
        case aboutKatex
        case aboutPrism
        case aboutQuickLook
        case aboutEdit
        case aboutFileTree
        case aboutOutline
        case aboutThemes
        case aboutI18n
        case aboutCLI
        case aboutPDF
        case aboutFindReplace
        case aboutZoom
        case aboutCredits
        case aboutWebsite
        case helpMenuLabel
        case helpMarkdownReader
        case commandPaletteTitle
        case commandPalettePlaceholder
        case commandPaletteNoResults
        case commandPaletteOpenFile
        case commandPaletteOpenFolder
        case commandPaletteFilePlaceholder
        case commandPaletteCommandTitle

        // 目录树 - 跨窗口所有权标记（Task 9）
        case fileOwnedByAnotherWindow

        // 多窗口菜单（回归修复）
        case menuNewWindow
        case menuSaveAs
        case windowMenuMinimize
        case windowMenuZoom
        case windowMenuBringAllToFront
        case windowMenu
    }

    // MARK: - 翻译字典

    private static let en: [Key: String] = [
        .appName: "Markdown Reader",
        .settingsMenuLabel: "Settings\u{2026}",
        .settingsBackToApp: "Back to App",
        .settingsTabGeneral: "General",
        .settingsTabAppearance: "Appearance",
        .settingsGeneralLanguageTitle: "Language",
        .settingsGeneralLanguageDesc: "Choose the interface language. \"Auto\" follows your system.",
        .settingsGeneralDisplayTitle: "Display",
        .settingsGeneralDisplayMode: "Default display mode",
        .settingsGeneralDefaultSplitPreview: "Split view by default when editing",
        .settingsGeneralRenderedWidthTitle: "Rendered Width",
        .settingsGeneralRenderedWidthDesc: "Control the maximum width of rendered content. When off, a fixed width is used.",
        .settingsGeneralMaxWidthFollowsWindow: "Follow window width",
        .settingsGeneralStartupTitle: "Startup",
        .settingsGeneralReopenLastLocation: "Reopen last location on launch",
        .settingsGeneralFileTreeTitle: "File Tree",
        .settingsGeneralShowHiddenFiles: "Show hidden files",
        .settingsGeneralShowNonMarkdownFiles: "Show non-Markdown files",
        .settingsGeneralDefaultOpenerTitle: "Default Markdown Opener",
        .settingsGeneralDefaultOpenerDesc: "Set Markdown Reader as the default application for opening .md, .markdown, .mdown, .mkd files.",
        .settingsGeneralSetAsDefault: "Set as Default",
        .settingsGeneralIsDefault: "Markdown Reader is the default Markdown opener",
        .settingsGeneralSetDefaultFailed: "Failed to set as default opener. Please try again.",
        .settingsGeneralCommandLineTitle: "Command Line Tool",
        .settingsGeneralCommandLineDesc: "Install the `mdr` command to open files from Terminal. Example: mdr README.md",
        .settingsGeneralCommandLineInstalled: "mdr command is available in Terminal",
        .settingsGeneralCommandLineInstallFailed: "Failed to install command line tool. Please try again.",
        .settingsGeneralCommandLineUninstallFailed: "Failed to uninstall command line tool. Please try again.",
        .settingsGeneralQuickLookTitle: "Quick Look Preview",
        .settingsGeneralQuickLookDesc: "Enable Markdown rendering in Finder Quick Look (press Space to preview).",
        .settingsGeneralQuickLookEnabled: "Enable Quick Look preview",
        .settingsAppearanceThemeTitle: "Theme",
        .settingsAppearanceThemeDesc: "Choose the application appearance mode.",
        .settingsAppearanceModeLight: "Light",
        .settingsAppearanceModeLightDesc: "Always use light appearance",
        .settingsAppearanceModeDark: "Dark",
        .settingsAppearanceModeDarkDesc: "Always use dark appearance",
        .settingsAppearanceModeSystem: "System",
        .settingsAppearanceModeSystemDesc: "Follow system setting",
        .settingsAppearanceSchemeTitle: "Color Scheme",
        .settingsAppearanceSchemeDesc: "Choose a preset color scheme for the current mode.",
        .settingsAppearanceCustomTitle: "Custom Colors",
        .settingsAppearanceCustomDesc: "Customize individual color tokens. Changes override the current scheme.",
        .settingsAppearanceCustomSurface: "Surface",
        .settingsAppearanceCustomInk: "Ink",
        .settingsAppearanceCustomAccent: "Accent",
        .settingsAppearanceCustomSuccess: "Success",
        .settingsAppearanceCustomDanger: "Danger",
        .settingsAppearanceContrastTitle: "Contrast",
        .settingsAppearanceContrastDesc: "Adjust the contrast between background and foreground layers.",
        .settingsAppearanceContrastLow: "Low",
        .settingsAppearanceContrastHigh: "High",
        .settingsAppearanceTypographyTitle: "Typography",
        .settingsAppearanceSourceFontSize: "Source font size",
        .settingsAppearanceContentPadding: "Content padding",
        .languageAuto: "Auto / Auto Detect",
        .languageZhCN: "Simplified Chinese",
        .languageZhTW: "Traditional Chinese",
        .languageEn: "English",
        .displayModeRendered: "Rendered",
        .displayModeRaw: "Raw",
        .open: "Open",
        .save: "Save",
        .reset: "Reset",
        .confirm: "OK",
        .menuNewFile: "New File",
        .closeWindow: "Close Window",
        .unsavedChangesTitle: "Unsaved Changes",
        .unsavedChangesMessage: "Your changes will be lost if you don't save them. Do you want to save before closing?",
        .unsavedSave: "Save",
        .unsavedDontSave: "Don't Save",
        .unsavedCancel: "Cancel",
        .fileDeletedTitle: "File Deleted",
        .fileDeletedMessage: "The file \"{name}\" was deleted externally. You have unsaved changes.",
        .fileDeletedSaveAs: "Save As\u{2026}",
        .fileDeletedDiscard: "Discard Changes",
        .openRecent: "Open Recent",
        .openRecentEmpty: "No Recent Items",
        .openRecentFiles: "Files",
        .openRecentFolders: "Folders",
        .clearRecentItems: "Clear Menu",
        .titleBarToggleSidebar: "Toggle Sidebar (⌘\\)",
        .titleBarDisplayMode: "Display Mode",
        .titleBarOpen: "Open (⌘O)",
        .titleBarNewFile: "New File",
        .titleBarSave: "Save (⌘S)",
        .titleBarReload: "Reload",
        .titleBarToggleOutline: "Toggle Outline",
        .titleBarToggleSplitPreview: "Toggle Split Preview",
        .titleBarCopyPath: "Copy Path",
        .titleBarPathCopied: "Path Copied",
        .fileModifiedExternallyTitle: "File Modified Externally",
        .fileModifiedExternallyMessage: "The file has been modified by another application. Reloading will discard your current changes.",
        .fileModifiedExternallyReload: "Reload",
        .fileModifiedExternallyDontRemind: "Don't remind me again",
        .outlineTitle: "Outline",
        .outlineEmpty: "No headings",
        .loading: "Loading...",
        .emptyDirectoryMessage: "No Markdown files in this directory",
        .sidebarSettings: "Settings (⌘,)",
        .sidebarSettingsButton: "Settings",
        .welcomeOpenFolder: "Open a folder to get started",
        .welcomePressCmdO: "Press Cmd+O or click Open in toolbar",
        .welcomeDropHint: "or drag a file or folder here",
        .selectFileHint: "Select a file to preview",
        .contextMenuNewFile: "New File",
        .contextMenuNewSubdirectory: "New Subdirectory",
        .contextMenuRename: "Rename",
        .contextMenuMoveTo: "Move to\u{2026}",
        .contextMenuDelete: "Move to Trash",
        .contextMenuReload: "Reload",
        .contextMenuCopyPath: "Copy Path",
        .contextMenuOpenInFinder: "Reveal in Finder",
        .renameTitle: "Rename",
        .renameMessage: "Enter a new name for \"{name}\":",
        .renameEmptyName: "Name cannot be empty.",
        .renameNameExists: "An item with this name already exists.",
        .deleteTitle: "Move to Trash",
        .deleteMessage: "Are you sure you want to move \"{name}\" to the Trash?",
        .deleteDirectoryMessage: "Are you sure you want to move \"{name}\" and all its contents to the Trash?",
        .moveSelectFolder: "Select Destination Folder",
        .updateAvailableTitle: "Update Available",
        .updateAvailableVersion: "Version {version}",
        .updateChecking: "Checking for updates\u{2026}",
        .updateUpToDate: "Markdown Reader is up to date.",
        .updateDownload: "Download",
        .updateDownloading: "Downloading update\u{2026}",
        .updateDownloadComplete: "Download complete. Click Install to continue.",
        .updateInstall: "Install",
        .updateInstallAndRestart: "Install & Restart",
        .updateInstalling: "Installing update\u{2026}",
        .updateLater: "Later",
        .updateSkipVersion: "Skip This Version",
        .updateCancel: "Cancel",
        .updateError: "Update check failed.",
        .updateModeAuto: "Auto install & restart",
        .updateModeManual: "Manual install required",
        .checkForUpdates: "Check for Updates\u{2026}",
        .findBarSearchPlaceholder: "Search",
        .findBarReplacePlaceholder: "Replace",
        .findBarFindNext: "Find Next",
        .findBarFindPrevious: "Find Previous",
        .findBarReplace: "Replace",
        .findBarReplaceAll: "Replace All",
        .findBarNoResults: "No results",
        .findBarCaseSensitive: "Match Case",
        .findBarWholeWord: "Match Whole Word",
        .findBarRegularExpression: "Use Regular Expression",
        .findBarFind: "Find",
        .findBarFindAndReplace: "Find and Replace",
        .exportPDF: "Export PDF\u{2026}",
        .titleBarExportPDF: "Export PDF",
        .exportPDFSuccess: "PDF exported successfully",
        .exportPDFFailed: "Failed to export PDF",
        .unsupportedFileTypeAlert: "Unsupported file type (.{ext}). Only Markdown files can be opened.",
        .viewZoomIn: "Zoom In",
        .viewZoomOut: "Zoom Out",
        .viewZoomReset: "Actual Size",
        .aboutTitle: "About Markdown Reader",
        .aboutDescription: "A quiet native macOS Markdown reader — not another editor.",
        .aboutRendering: "cmark-gfm + WKWebView rendering with full GFM extensions",
        .aboutMermaid: "Mermaid diagrams: flowcharts, sequences, gantt charts and more",
        .aboutPlantUML: "PlantUML diagrams rendered as SVG (requires network)",
        .aboutKatex: "KaTeX rendering for LaTeX inline and block math",
        .aboutPrism: "Prism.js syntax highlighting for 30+ languages",
        .aboutQuickLook: "Finder Quick Look preview for Markdown files",
        .aboutEdit: "Edit source directly, Cmd+S to save, auto-retain unsaved changes",
        .aboutFileTree: "Recursive file tree with keyboard navigation and context menu",
        .aboutOutline: "Auto-extracted heading outline for quick navigation",
        .aboutThemes: "33 themes (20 dark + 13 light) with custom colors and contrast",
        .aboutI18n: "Simplified Chinese, Traditional Chinese, English",
        .aboutCLI: "mdr command-line tool to open files from Terminal",
        .aboutPDF: "Export rendered content to PDF",
        .aboutFindReplace: "Find & replace with regex support",
        .aboutZoom: "Zoom in/out, range 0.3–3.0, auto-restore on reload",
        .aboutCredits: "Built with SwiftUI, cmark-gfm, WKWebView, KaTeX, Mermaid, Prism.js",
        .aboutWebsite: "Website",
        .helpMenuLabel: "Help",
        .helpMarkdownReader: "Markdown Reader Help",
        .commandPaletteTitle: "Command Palette",
        .commandPalettePlaceholder: "Search files and commands\u{2026}",
        .commandPaletteNoResults: "No results found",
        .commandPaletteOpenFile: "Open File\u{2026}",
        .commandPaletteOpenFolder: "Open Folder\u{2026}",
        .commandPaletteFilePlaceholder: "Search files by name\u{2026}",
        .commandPaletteCommandTitle: "Command Palette\u{2026}",
        .fileOwnedByAnotherWindow: "Open in another window",
        .menuNewWindow: "New Window",
        .menuSaveAs: "Save As\u{2026}",
        .windowMenuMinimize: "Minimize",
        .windowMenuZoom: "Zoom",
        .windowMenuBringAllToFront: "Bring All to Front",
        .windowMenu: "Window",
    ]

    private static let zhCN: [Key: String] = [
        .appName: "Markdown Reader",
        .settingsMenuLabel: "设置\u{2026}",
        .settingsBackToApp: "返回应用",
        .settingsTabGeneral: "通用",
        .settingsTabAppearance: "外观",
        .settingsGeneralLanguageTitle: "界面语言",
        .settingsGeneralLanguageDesc: "选择应用界面的语言。「自动检测」会跟随系统。",
        .settingsGeneralDisplayTitle: "显示",
        .settingsGeneralDisplayMode: "默认显示模式",
        .settingsGeneralDefaultSplitPreview: "编辑时默认分栏",
        .settingsGeneralRenderedWidthTitle: "渲染宽度",
        .settingsGeneralRenderedWidthDesc: "控制渲染内容的最大宽度。关闭时使用固定宽度。",
        .settingsGeneralMaxWidthFollowsWindow: "跟随窗口宽度",
        .settingsGeneralStartupTitle: "启动",
        .settingsGeneralReopenLastLocation: "启动时重新打开上次位置",
        .settingsGeneralFileTreeTitle: "文件树",
        .settingsGeneralShowHiddenFiles: "显示隐藏文件",
        .settingsGeneralShowNonMarkdownFiles: "显示非 Markdown 文件",
        .settingsGeneralDefaultOpenerTitle: "默认 Markdown 打开程序",
        .settingsGeneralDefaultOpenerDesc: "将 Markdown Reader 设置为 .md、.markdown、.mdown、.mkd 文件的默认打开程序。",
        .settingsGeneralSetAsDefault: "设为默认",
        .settingsGeneralIsDefault: "Markdown Reader 已是默认 Markdown 打开程序",
        .settingsGeneralSetDefaultFailed: "设置默认打开程序失败，请重试。",
        .settingsGeneralCommandLineTitle: "命令行工具",
        .settingsGeneralCommandLineDesc: "安装 mdr 命令，可在终端中打开文件。例如：mdr README.md",
        .settingsGeneralCommandLineInstalled: "mdr 命令已在终端中可用",
        .settingsGeneralCommandLineInstallFailed: "安装命令行工具失败，请重试。",
        .settingsGeneralCommandLineUninstallFailed: "卸载命令行工具失败，请重试。",
        .settingsGeneralQuickLookTitle: "Quick Look 预览",
        .settingsGeneralQuickLookDesc: "在 Finder 中按空格键预览 Markdown 文件的渲染效果。",
        .settingsGeneralQuickLookEnabled: "启用 Quick Look 预览",
        .settingsAppearanceThemeTitle: "主题",
        .settingsAppearanceThemeDesc: "选择应用的外观模式。",
        .settingsAppearanceModeLight: "浅色",
        .settingsAppearanceModeLightDesc: "始终使用浅色外观",
        .settingsAppearanceModeDark: "深色",
        .settingsAppearanceModeDarkDesc: "始终使用深色外观",
        .settingsAppearanceModeSystem: "跟随系统",
        .settingsAppearanceModeSystemDesc: "跟随系统设置",
        .settingsAppearanceSchemeTitle: "配色方案",
        .settingsAppearanceSchemeDesc: "为当前模式选择预设配色方案。",
        .settingsAppearanceCustomTitle: "自定义颜色",
        .settingsAppearanceCustomDesc: "自定义各颜色令牌。修改将覆盖当前方案的对应颜色。",
        .settingsAppearanceCustomSurface: "背景色",
        .settingsAppearanceCustomInk: "文字色",
        .settingsAppearanceCustomAccent: "强调色",
        .settingsAppearanceCustomSuccess: "成功色",
        .settingsAppearanceCustomDanger: "危险色",
        .settingsAppearanceContrastTitle: "对比度",
        .settingsAppearanceContrastDesc: "调整背景与前景层之间的对比度。",
        .settingsAppearanceContrastLow: "低",
        .settingsAppearanceContrastHigh: "高",
        .settingsAppearanceTypographyTitle: "字体与排版",
        .settingsAppearanceSourceFontSize: "源码字号",
        .settingsAppearanceContentPadding: "内容边距",
        .languageAuto: "自动检测",
        .languageZhCN: "简体中文",
        .languageZhTW: "繁體中文",
        .languageEn: "English",
        .displayModeRendered: "渲染",
        .displayModeRaw: "编辑",
        .open: "打开",
        .save: "保存",
        .reset: "重置",
        .confirm: "确认",
        .menuNewFile: "新建文件",
        .closeWindow: "关闭窗口",
        .unsavedChangesTitle: "未保存的更改",
        .unsavedChangesMessage: "如果不保存，您的更改将会丢失。关闭前是否保存？",
        .unsavedSave: "保存",
        .unsavedDontSave: "不保存",
        .unsavedCancel: "取消",
        .fileDeletedTitle: "文件已被删除",
        .fileDeletedMessage: "文件「{name}」已被外部删除，您有未保存的更改。",
        .fileDeletedSaveAs: "另存为\u{2026}",
        .fileDeletedDiscard: "放弃更改",
        .openRecent: "打开最近使用",
        .openRecentEmpty: "无最近打开的项",
        .openRecentFiles: "文件",
        .openRecentFolders: "文件夹",
        .clearRecentItems: "清除菜单",
        .titleBarToggleSidebar: "切换侧边栏 (⌘\\)",
        .titleBarDisplayMode: "显示模式",
        .titleBarOpen: "打开 (⌘O)",
        .titleBarNewFile: "新建文件",
        .titleBarSave: "保存 (⌘S)",
        .titleBarReload: "重新加载",
        .titleBarToggleOutline: "切换大纲",
        .titleBarToggleSplitPreview: "切换分栏预览",
        .titleBarCopyPath: "复制路径",
        .titleBarPathCopied: "路径已复制",
        .fileModifiedExternallyTitle: "文件已被外部修改",
        .fileModifiedExternallyMessage: "文件已被其他应用修改，重新加载将丢弃当前未保存的更改。",
        .fileModifiedExternallyReload: "重新加载",
        .fileModifiedExternallyDontRemind: "以后不再提醒",
        .outlineTitle: "大纲",
        .outlineEmpty: "暂无标题",
        .loading: "加载中...",
        .emptyDirectoryMessage: "该目录下无 Markdown 文件",
        .sidebarSettings: "设置 (⌘,)",
        .sidebarSettingsButton: "设置",
        .welcomeOpenFolder: "打开文件夹开始阅读",
        .welcomePressCmdO: "按 Cmd+O 或点击工具栏中的打开按钮",
        .welcomeDropHint: "或拖拽文件/文件夹到此处",
        .selectFileHint: "选择文件以预览",
        .contextMenuNewFile: "新建文档",
        .contextMenuNewSubdirectory: "新建子目录",
        .contextMenuRename: "重命名",
        .contextMenuMoveTo: "移动到\u{2026}",
        .contextMenuDelete: "移到废纸篓",
        .contextMenuReload: "重新加载",
        .contextMenuCopyPath: "复制路径",
        .contextMenuOpenInFinder: "在访达中打开",
        .renameTitle: "重命名",
        .renameMessage: "输入「{name}」的新名称：",
        .renameEmptyName: "名称不能为空。",
        .renameNameExists: "已存在同名项目。",
        .deleteTitle: "移到废纸篓",
        .deleteMessage: "确定要将「{name}」移到废纸篓吗？",
        .deleteDirectoryMessage: "确定要将「{name}」及其所有内容移到废纸篓吗？",
        .moveSelectFolder: "选择目标文件夹",
        .updateAvailableTitle: "发现新版本",
        .updateAvailableVersion: "版本 {version}",
        .updateChecking: "正在检查更新\u{2026}",
        .updateUpToDate: "Markdown Reader 已是最新版本。",
        .updateDownload: "下载",
        .updateDownloading: "正在下载更新\u{2026}",
        .updateDownloadComplete: "下载完成，点击「安装」继续。",
        .updateInstall: "安装",
        .updateInstallAndRestart: "安装并重启",
        .updateInstalling: "正在安装更新\u{2026}",
        .updateLater: "稍后",
        .updateSkipVersion: "跳过此版本",
        .updateCancel: "取消",
        .updateError: "检查更新失败。",
        .updateModeAuto: "自动安装并重启",
        .updateModeManual: "需手动安装",
        .checkForUpdates: "检查更新\u{2026}",
        .findBarSearchPlaceholder: "搜索",
        .findBarReplacePlaceholder: "替换",
        .findBarFindNext: "查找下一个",
        .findBarFindPrevious: "查找上一个",
        .findBarReplace: "替换",
        .findBarReplaceAll: "全部替换",
        .findBarNoResults: "无结果",
        .findBarCaseSensitive: "区分大小写",
        .findBarWholeWord: "全词匹配",
        .findBarRegularExpression: "使用正则表达式",
        .findBarFind: "查找",
        .findBarFindAndReplace: "查找和替换",
        .exportPDF: "导出 PDF\u{2026}",
        .titleBarExportPDF: "导出 PDF",
        .exportPDFSuccess: "PDF 导出成功",
        .exportPDFFailed: "PDF 导出失败",
        .unsupportedFileTypeAlert: "不支持的文件类型（.{ext}）。仅支持打开 Markdown 文件。",
        .viewZoomIn: "放大",
        .viewZoomOut: "缩小",
        .viewZoomReset: "实际大小",
        .aboutTitle: "关于 Markdown Reader",
        .aboutDescription: "一个安静的原生 macOS Markdown 阅读器——不是又一个编辑器。",
        .aboutRendering: "cmark-gfm + WKWebView 渲染引擎，完整 GFM 扩展语法",
        .aboutMermaid: "Mermaid 图表：流程图、时序图、甘特图等",
        .aboutPlantUML: "PlantUML 图表自动渲染为 SVG（需要网络）",
        .aboutKatex: "KaTeX 渲染 LaTeX 行内和块级公式",
        .aboutPrism: "Prism.js 30+ 语言语法高亮",
        .aboutQuickLook: "Finder 中按空格预览 Markdown 渲染效果",
        .aboutEdit: "直接编辑原文，Cmd+S 保存，自动保留未保存内容",
        .aboutFileTree: "递归文件树，键盘导航，右键菜单",
        .aboutOutline: "自动提取标题大纲，点击快速跳转",
        .aboutThemes: "33 套主题（20 深色 + 13 浅色），自定义配色和对比度",
        .aboutI18n: "简体中文、繁体中文、英文",
        .aboutCLI: "mdr 命令行工具，终端直接打开文件",
        .aboutPDF: "渲染内容导出为 PDF",
        .aboutFindReplace: "查找替换，支持正则表达式",
        .aboutZoom: "视图缩放，范围 0.3–3.0，自动恢复缩放级别",
        .aboutCredits: "基于 SwiftUI、cmark-gfm、WKWebView、KaTeX、Mermaid、Prism.js 构建",
        .aboutWebsite: "网站",
        .helpMenuLabel: "帮助",
        .helpMarkdownReader: "Markdown Reader 帮助",
        .commandPaletteTitle: "命令面板",
        .commandPalettePlaceholder: "搜索文件和命令\u{2026}",
        .commandPaletteNoResults: "未找到结果",
        .commandPaletteOpenFile: "打开文件\u{2026}",
        .commandPaletteOpenFolder: "打开文件夹\u{2026}",
        .commandPaletteFilePlaceholder: "按名称搜索文件\u{2026}",
        .commandPaletteCommandTitle: "命令面板\u{2026}",
        .fileOwnedByAnotherWindow: "已在另一窗口打开",
        .menuNewWindow: "新建窗口",
        .menuSaveAs: "另存为\u{2026}",
        .windowMenuMinimize: "最小化",
        .windowMenuZoom: "缩放",
        .windowMenuBringAllToFront: "将全部窗口前置",
        .windowMenu: "窗口",
    ]

    private static let zhTW: [Key: String] = [
        .appName: "Markdown Reader",
        .settingsMenuLabel: "設定\u{2026}",
        .settingsBackToApp: "返回應用",
        .settingsTabGeneral: "一般",
        .settingsTabAppearance: "外觀",
        .settingsGeneralLanguageTitle: "介面語言",
        .settingsGeneralLanguageDesc: "選擇應用介面的語言。「自動偵測」會跟隨系統。",
        .settingsGeneralDisplayTitle: "顯示",
        .settingsGeneralDisplayMode: "預設顯示模式",
        .settingsGeneralDefaultSplitPreview: "編輯時預設分欄",
        .settingsGeneralRenderedWidthTitle: "渲染寬度",
        .settingsGeneralRenderedWidthDesc: "控制渲染內容的最大寬度。關閉時使用固定寬度。",
        .settingsGeneralMaxWidthFollowsWindow: "跟隨視窗寬度",
        .settingsGeneralStartupTitle: "啟動",
        .settingsGeneralReopenLastLocation: "啟動時重新開啟上次位置",
        .settingsGeneralFileTreeTitle: "檔案樹",
        .settingsGeneralShowHiddenFiles: "顯示隱藏檔案",
        .settingsGeneralShowNonMarkdownFiles: "顯示非 Markdown 檔案",
        .settingsGeneralDefaultOpenerTitle: "預設 Markdown 開啟程式",
        .settingsGeneralDefaultOpenerDesc: "將 Markdown Reader 設為 .md、.markdown、.mdown、.mkd 檔案的預設開啟程式。",
        .settingsGeneralSetAsDefault: "設為預設",
        .settingsGeneralIsDefault: "Markdown Reader 已是預設 Markdown 開啟程式",
        .settingsGeneralSetDefaultFailed: "設定預設開啟程式失敗，請重試。",
        .settingsGeneralCommandLineTitle: "命令列工具",
        .settingsGeneralCommandLineDesc: "安裝 mdr 命令，可在終端機中開啟檔案。例如：mdr README.md",
        .settingsGeneralCommandLineInstalled: "mdr 命令已在終端機中可用",
        .settingsGeneralCommandLineInstallFailed: "安裝命令列工具失敗，請重試。",
        .settingsGeneralCommandLineUninstallFailed: "解除安裝命令列工具失敗，請重試。",
        .settingsGeneralQuickLookTitle: "Quick Look 預覽",
        .settingsGeneralQuickLookDesc: "在 Finder 中按空白鍵預覽 Markdown 檔案的渲染效果。",
        .settingsGeneralQuickLookEnabled: "啟用 Quick Look 預覽",
        .settingsAppearanceThemeTitle: "主題",
        .settingsAppearanceThemeDesc: "選擇應用的外觀模式。",
        .settingsAppearanceModeLight: "淺色",
        .settingsAppearanceModeLightDesc: "始終使用淺色外觀",
        .settingsAppearanceModeDark: "深色",
        .settingsAppearanceModeDarkDesc: "始終使用深色外觀",
        .settingsAppearanceModeSystem: "跟隨系統",
        .settingsAppearanceModeSystemDesc: "跟隨系統設定",
        .settingsAppearanceSchemeTitle: "配色方案",
        .settingsAppearanceSchemeDesc: "為目前模式選擇預設配色方案。",
        .settingsAppearanceCustomTitle: "自訂顏色",
        .settingsAppearanceCustomDesc: "自訂各顏色令牌。修改將覆蓋目前方案的對應顏色。",
        .settingsAppearanceCustomSurface: "背景色",
        .settingsAppearanceCustomInk: "文字色",
        .settingsAppearanceCustomAccent: "強調色",
        .settingsAppearanceCustomSuccess: "成功色",
        .settingsAppearanceCustomDanger: "危險色",
        .settingsAppearanceContrastTitle: "對比度",
        .settingsAppearanceContrastDesc: "調整背景與前景層之間的對比度。",
        .settingsAppearanceContrastLow: "低",
        .settingsAppearanceContrastHigh: "高",
        .settingsAppearanceTypographyTitle: "字體與排版",
        .settingsAppearanceSourceFontSize: "原始碼字號",
        .settingsAppearanceContentPadding: "內容邊距",
        .languageAuto: "自動偵測",
        .languageZhCN: "简体中文",
        .languageZhTW: "繁體中文",
        .languageEn: "English",
        .displayModeRendered: "渲染",
        .displayModeRaw: "編輯",
        .open: "開啟",
        .save: "儲存",
        .reset: "重設",
        .confirm: "確認",
        .menuNewFile: "新增檔案",
        .closeWindow: "關閉視窗",
        .unsavedChangesTitle: "未儲存的變更",
        .unsavedChangesMessage: "如果不儲存，您的變更將會遺失。關閉前是否儲存？",
        .unsavedSave: "儲存",
        .unsavedDontSave: "不儲存",
        .unsavedCancel: "取消",
        .fileDeletedTitle: "檔案已被刪除",
        .fileDeletedMessage: "檔案「{name}」已被外部刪除，您有未儲存的變更。",
        .fileDeletedSaveAs: "另存為\u{2026}",
        .fileDeletedDiscard: "放棄變更",
        .openRecent: "開啟最近使用",
        .openRecentEmpty: "無最近開啟的項目",
        .openRecentFiles: "檔案",
        .openRecentFolders: "資料夾",
        .clearRecentItems: "清除選單",
        .titleBarToggleSidebar: "切換側邊欄 (⌘\\)",
        .titleBarDisplayMode: "顯示模式",
        .titleBarOpen: "開啟 (⌘O)",
        .titleBarNewFile: "新增檔案",
        .titleBarSave: "儲存 (⌘S)",
        .titleBarReload: "重新載入",
        .titleBarToggleOutline: "切換大綱",
        .titleBarToggleSplitPreview: "切換分欄預覽",
        .titleBarCopyPath: "複製路徑",
        .titleBarPathCopied: "路徑已複製",
        .fileModifiedExternallyTitle: "檔案已被外部修改",
        .fileModifiedExternallyMessage: "檔案已被其他應用修改，重新載入將捨棄目前未儲存的變更。",
        .fileModifiedExternallyReload: "重新載入",
        .fileModifiedExternallyDontRemind: "以後不再提醒",
        .outlineTitle: "大綱",
        .outlineEmpty: "暫無標題",
        .loading: "載入中...",
        .emptyDirectoryMessage: "此目錄下無 Markdown 檔案",
        .sidebarSettings: "設定 (⌘,)",
        .sidebarSettingsButton: "設定",
        .welcomeOpenFolder: "開啟資料夾開始閱讀",
        .welcomePressCmdO: "按 Cmd+O 或點擊工具列中的開啟按鈕",
        .welcomeDropHint: "或拖拽檔案/資料夾到此處",
        .selectFileHint: "選擇檔案以預覽",
        .contextMenuNewFile: "新增檔案",
        .contextMenuNewSubdirectory: "新增子目錄",
        .contextMenuRename: "重新命名",
        .contextMenuMoveTo: "移動到\u{2026}",
        .contextMenuDelete: "移到垃圾桶",
        .contextMenuReload: "重新載入",
        .contextMenuCopyPath: "複製路徑",
        .contextMenuOpenInFinder: "在 Finder 中打開",
        .renameTitle: "重新命名",
        .renameMessage: "輸入「{name}」的新名稱：",
        .renameEmptyName: "名稱不能為空。",
        .renameNameExists: "已存在同名項目。",
        .deleteTitle: "移到垃圾桶",
        .deleteMessage: "確定要將「{name}」移到垃圾桶嗎？",
        .deleteDirectoryMessage: "確定要將「{name}」及其所有內容移到垃圾桶嗎？",
        .moveSelectFolder: "選擇目標資料夾",
        .updateAvailableTitle: "發現新版本",
        .updateAvailableVersion: "版本 {version}",
        .updateChecking: "正在檢查更新\u{2026}",
        .updateUpToDate: "Markdown Reader 已是最新版本。",
        .updateDownload: "下載",
        .updateDownloading: "正在下載更新\u{2026}",
        .updateDownloadComplete: "下載完成，點擊「安裝」繼續。",
        .updateInstall: "安裝",
        .updateInstallAndRestart: "安裝並重新啟動",
        .updateInstalling: "正在安裝更新\u{2026}",
        .updateLater: "稍後",
        .updateSkipVersion: "跳過此版本",
        .updateCancel: "取消",
        .updateError: "檢查更新失敗。",
        .updateModeAuto: "自動安裝並重新啟動",
        .updateModeManual: "需手動安裝",
        .checkForUpdates: "檢查更新\u{2026}",
        .findBarSearchPlaceholder: "搜尋",
        .findBarReplacePlaceholder: "取代",
        .findBarFindNext: "尋找下一個",
        .findBarFindPrevious: "尋找上一個",
        .findBarReplace: "取代",
        .findBarReplaceAll: "全部取代",
        .findBarNoResults: "無結果",
        .findBarCaseSensitive: "區分大小寫",
        .findBarWholeWord: "全字匹配",
        .findBarRegularExpression: "使用規則表達式",
        .findBarFind: "尋找",
        .findBarFindAndReplace: "尋找和取代",
        .exportPDF: "匯出 PDF\u{2026}",
        .titleBarExportPDF: "匯出 PDF",
        .exportPDFSuccess: "PDF 匯出成功",
        .exportPDFFailed: "PDF 匯出失敗",
        .unsupportedFileTypeAlert: "不支援的檔案類型（.{ext}）。僅支援開啟 Markdown 檔案。",
        .viewZoomIn: "放大",
        .viewZoomOut: "縮小",
        .viewZoomReset: "實際大小",
        .aboutTitle: "關於 Markdown Reader",
        .aboutDescription: "一個安靜的原生 macOS Markdown 閱讀器——不是又一個編輯器。",
        .aboutRendering: "cmark-gfm + WKWebView 渲染引擎，完整 GFM 擴展語法",
        .aboutMermaid: "Mermaid 圖表：流程圖、時序圖、甘特圖等",
        .aboutPlantUML: "PlantUML 圖表自動渲染為 SVG（需要網路）",
        .aboutKatex: "KaTeX 渲染 LaTeX 行內和區塊公式",
        .aboutPrism: "Prism.js 30+ 語言語法高亮",
        .aboutQuickLook: "Finder 中按空白鍵預覽 Markdown 渲染效果",
        .aboutEdit: "直接編輯原始內容，Cmd+S 儲存，自動保留未儲存變更",
        .aboutFileTree: "遞迴檔案樹，鍵盤導航，右鍵選單",
        .aboutOutline: "自動提取標題大綱，點擊快速跳轉",
        .aboutThemes: "33 套主題（20 深色 + 13 淺色），自訂配色和對比度",
        .aboutI18n: "简体中文、繁體中文、English",
        .aboutCLI: "mdr 命令列工具，終端機直接開啟檔案",
        .aboutPDF: "渲染內容匯出為 PDF",
        .aboutFindReplace: "尋找取代，支援規則表達式",
        .aboutZoom: "檢視縮放，範圍 0.3–3.0，自動恢復縮放級別",
        .aboutCredits: "基於 SwiftUI、cmark-gfm、WKWebView、KaTeX、Mermaid、Prism.js 建構",
        .aboutWebsite: "網站",
        .helpMenuLabel: "說明",
        .helpMarkdownReader: "Markdown Reader 說明",
        .commandPaletteTitle: "命令面板",
        .commandPalettePlaceholder: "搜尋檔案和命令\u{2026}",
        .commandPaletteNoResults: "未找到結果",
        .commandPaletteOpenFile: "開啟檔案\u{2026}",
        .commandPaletteOpenFolder: "開啟資料夾\u{2026}",
        .commandPaletteFilePlaceholder: "按名稱搜尋檔案\u{2026}",
        .commandPaletteCommandTitle: "命令面板\u{2026}",
        .fileOwnedByAnotherWindow: "已在另一視窗開啟",
        .menuNewWindow: "新增視窗",
        .menuSaveAs: "另存為\u{2026}",
        .windowMenuMinimize: "最小化",
        .windowMenuZoom: "縮放",
        .windowMenuBringAllToFront: "將全部視窗帶至最前",
        .windowMenu: "視窗",
    ]

    // MARK: - 查找

    private static func dictionary(for language: Language) -> [Key: String] {
        switch language {
        case .zhCN: zhCN
        case .zhTW: zhTW
        case .en: en
        }
    }

    public static func tr(_ key: Key, language: Language) -> String {
        dictionary(for: language)[key] ?? key.rawValue
    }

    public static func tr(_ key: Key, language: Language, args: [String: String]) -> String {
        var result = tr(key, language: language)
        for (k, v) in args {
            result = result.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return result
    }
}

// MARK: - SwiftUI Environment 支持

private struct LanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue: Language = .en
}

extension EnvironmentValues {
    public var language: Language {
        get { self[LanguageEnvironmentKey.self] }
        set { self[LanguageEnvironmentKey.self] = newValue }
    }
}

extension View {
    public func withLanguage(_ language: Language) -> some View {
        environment(\.language, language)
    }
}

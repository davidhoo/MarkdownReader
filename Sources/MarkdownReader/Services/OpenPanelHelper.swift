import SwiftUI
import MarkdownReaderKit
import UniformTypeIdentifiers

/// 打开面板工具，提供统一的 NSOpenPanel / NSSavePanel 调用逻辑
///
/// Task 8：`chooseResource`/`chooseDirectory` 改为窗口级 sheet（`beginSheetModal(for:)`），
/// 不再使用全局 `runModal` + `isPanelShowing` 重入保护。面板状态由各窗口自行维护。
enum OpenPanelHelper {

    /// Markdown 相关的 UTType 列表，用于文件选择面板过滤
    static let markdownContentTypes: [UTType] = {
        var types: [UTType] = []
        if let markdownType = UTType("net.daringfireball.markdown") {
            types.append(markdownType)
        }
        if let txtType = UTType(filenameExtension: "txt") {
            types.append(txtType)
        }
        for ext in ["md", "markdown", "mdown", "mkd"] {
            if let ut = UTType(filenameExtension: ext), !types.contains(ut) {
                types.append(ut)
            }
        }
        return types
    }()

    /// 工作区文件的 UTType（未注册时回退按扩展名构造）
    static var workspaceContentType: UTType? {
        UTType("com.markdownreader.workspace") ?? UTType(filenameExtension: "mdworkspace")
    }

    /// 显示打开面板（窗口级 sheet），用户选择后返回 URL。
    @MainActor
    static func chooseResource(
        for window: NSWindow,
        language: Language
    ) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.tr(.open, language: language)
        var types: [UTType] = [.folder] + Self.markdownContentTypes
        if let workspaceType = Self.workspaceContentType {
            types.append(workspaceType)
        }
        panel.allowedContentTypes = types

        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// 显示打开文件夹面板（窗口级 sheet），仅允许选择目录。
    @MainActor
    static func chooseDirectory(
        for window: NSWindow,
        language: Language
    ) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.tr(.open, language: language)
        panel.allowedContentTypes = [.folder]

        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// 显示导出 PDF 面板，让用户选择保存位置
    /// 回归修复：附着到发起操作的 `window`（窗口级 sheet），不再用应用级 `runModal()`。
    @MainActor
    static func showExportPDFPanel(
        for window: NSWindow? = nil,
        language: Language,
        defaultDirectory: URL? = nil,
        suggestedName: String = "Untitled.pdf"
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.prompt = L10n.tr(.exportPDF, language: language)
        panel.allowedContentTypes = [UTType(filenameExtension: "pdf")].compactMap { $0 }
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true

        if let dir = defaultDirectory {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                panel.directoryURL = dir
            } else if dir.pathExtension.isEmpty == false {
                panel.directoryURL = dir.deletingLastPathComponent()
            }
        }

        // 有窗口上下文时作为窗口级 sheet，否则回退应用级（headless/测试）。
        if let window {
            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { response in
                    if response == .OK, let url = panel.url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            return url
        }
        return nil
    }

    /// 显示另存为面板，让用户选择保存位置
    /// 回归修复：附着到发起操作的 `window`（窗口级 sheet），不再用应用级 `runModal()`。
    @MainActor
    static func showSavePanel(
        for window: NSWindow? = nil,
        language: Language,
        defaultDirectory: URL? = nil,
        suggestedName: String = "Untitled.md"
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.prompt = L10n.tr(.save, language: language)
        panel.allowedContentTypes = Self.markdownContentTypes
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true

        if let dir = defaultDirectory {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                panel.directoryURL = dir
            } else if dir.pathExtension.isEmpty == false {
                panel.directoryURL = dir.deletingLastPathComponent()
            }
        }

        if let window {
            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { response in
                    if response == .OK, let url = panel.url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            return url
        }
        return nil
    }

    /// 显示工作区保存面板（仅允许 .mdworkspace）。
    @MainActor
    static func showWorkspaceSavePanel(
        for window: NSWindow? = nil,
        language: Language,
        defaultDirectory: URL? = nil,
        suggestedName: String = "Workspace.mdworkspace"
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.prompt = L10n.tr(.menuSaveWorkspace, language: language)
        if let workspaceType = Self.workspaceContentType {
            panel.allowedContentTypes = [workspaceType]
        }
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true

        if let dir = defaultDirectory {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                panel.directoryURL = dir
            } else if dir.pathExtension.isEmpty == false {
                panel.directoryURL = dir.deletingLastPathComponent()
            }
        }

        if let window {
            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { response in
                    if response == .OK, let url = panel.url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            return url
        }
        return nil
    }
}

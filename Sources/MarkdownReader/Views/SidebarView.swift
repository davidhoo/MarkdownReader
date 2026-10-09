import SwiftUI
import MarkdownReaderKit

/// 左侧 Sidebar 目录树视图
struct SidebarView: View {
    let fileTreeViewModel: FileTreeViewModel
    let appViewModel: AppViewModel
    let documentViewModel: DocumentViewModel
    /// Task 9：用于跨窗口所有权标记（文件行「已在另一窗口打开」）。
    let session: WindowSession
    /// 回归修复：本窗口控件直接调用所属 session 的命令目标，不通过 FocusedValue 反查。
    let commandTarget: WindowCommandTarget?
    @Environment(\.language) private var language
    @Environment(\.themeColors) private var themeColors

    var body: some View {
        VStack(spacing: 0) {
            // 顶部区域：自定义红绿灯 + Sidebar 隐藏按钮 + 打开按钮 + 新建文件按钮（50px）
            HStack(spacing: 0) {
                // 自定义红绿灯按钮
                TrafficLightButtons()
                    .padding(.leading, 12)

                // Sidebar 隐藏按钮
                Button {
                    appViewModel.toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 14))
                        .foregroundStyle(themeColors.fgSecondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr(.titleBarToggleSidebar, language: language))
                .padding(.leading, 8)

               // 打开按钮（与菜单 Cmd+O 功能一致，直接调用避免 WindowGroup 多实例重复弹窗）
               Button {
                    // 回归修复：直接调用本窗口命令目标，不通过 FocusedValue 反查。
                    commandTarget?.perform(.openPanel)
               } label: {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(themeColors.fgSecondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr(.titleBarOpen, language: language))
                .padding(.leading, 4)

                // 新建文件按钮
                Button {
                    // 回归修复：直接调用本窗口命令目标，不通过 FocusedValue 反查。
                    commandTarget?.perform(.newFile)
                } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 14))
                        .foregroundStyle(themeColors.fgSecondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr(.titleBarNewFile, language: language))
                .padding(.leading, 4)

                // 添加文件夹到工作区按钮
                Button {
                    commandTarget?.perform(.addFolderToWorkspace)
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 14))
                        .foregroundStyle(themeColors.fgSecondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr(.menuAddFolderToWorkspace, language: language))
                .padding(.leading, 4)

                Spacer()
            }
            .frame(height: 50)
            .background(WindowDragArea())

            if appViewModel.isSingleFileMode {
                singleFileView
            } else if fileTreeViewModel.isLoading {
                ProgressView(L10n.tr(.loading, language: language))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = fileTreeViewModel.errorMessage {
                ErrorView(message: error)
            } else if fileTreeViewModel.nodes.isEmpty {
                emptyDirectoryView
            } else {
                directoryTreeView
            }

            // 底部固定区域：Settings 按钮（参考 Buddy 底部固定设置入口）
            settingsButton
        }
        .background(themeColors.bgSubtle)
        // 注：拖拽目录到侧边栏添加文件夹的分流由窗口级 WindowDropOverlayView 按落点完成
        // （overlay 位于 SwiftUI 子树之上会优先收到拖拽，此处不重复注册 dropDestination）。
        .overlay {
            // 拖拽悬停于侧边栏区域：虚线高亮 + 「添加文件夹到工作区」提示。
            if appViewModel.isDropTargeted && appViewModel.isSidebarDropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(themeColors.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(3)

                    Text(L10n.tr(.menuAddFolderToWorkspace, language: language))
                        .font(.system(size: 12))
                        .foregroundStyle(themeColors.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(themeColors.bgSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(themeColors.accent, lineWidth: 1)
                        )
                }
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - 单文件列表

    private var singleFileView: some View {
        List {
            if let url = appViewModel.singleFileURL {
                Button {
                    // Task 9：单文件模式下文件即本窗口资源，直接选择。
                    fileTreeViewModel.selectedFileURL = url
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 14))
                            .foregroundStyle(themeColors.fgSecondary)
                        Text(url.lastPathComponent)
                            .font(.system(size: 13))
                            .foregroundStyle(themeColors.ink)
                            .lineLimit(1)
                        if documentViewModel.isFileDirty(at: url) {
                            Text("*")
                                .font(.system(size: 13))
                                .foregroundStyle(themeColors.accent)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    fileTreeViewModel.selectedFileURL == url ? themeColors.accentSoft : Color.clear
                )
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.automatic)
        .background(OverlayScrollerHelper())
    }

    // MARK: - 目录树（使用递归 DisclosureGroup 渲染嵌套结构）

    private var directoryTreeView: some View {
        List {
            ForEach(fileTreeViewModel.nodes) { node in
                FileNodeRow(node: node, fileTreeViewModel: fileTreeViewModel, documentViewModel: documentViewModel, session: session, isWorkspaceRoot: true)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.automatic)
        .background(OverlayScrollerHelper())
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .up:
                _ = fileTreeViewModel.moveSelection(direction: -1)
            case .down:
                _ = fileTreeViewModel.moveSelection(direction: 1)
            default:
                break
            }
        }
        .onKeyPress(.return) {
            if let url = fileTreeViewModel.selectedFileURL,
               let node = findNode(in: fileTreeViewModel.nodes, url: url) {
                if node.isDirectory {
                    fileTreeViewModel.toggleExpand(url)
                } else {
                    fileTreeViewModel.selectFile(node)
                }
            }
            return .handled
        }
    }

    // MARK: - 空目录提示

    private var emptyDirectoryView: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 32))
                .foregroundStyle(themeColors.fgMuted)
            Text(L10n.tr(.emptyDirectoryMessage, language: language))
                .font(.subheadline)
                .foregroundStyle(themeColors.fgSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部设置按钮

    private var settingsButton: some View {
        Button {
            appViewModel.showSettings()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(themeColors.fgSecondary)
                Text(L10n.tr(.sidebarSettingsButton, language: language))
                    .font(.system(size: 13))
                    .foregroundStyle(themeColors.fgSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.tr(.sidebarSettings, language: language))
    }

    // MARK: - 辅助方法

    private func findNode(in nodes: [FileNode], url: URL) -> FileNode? {
        for node in nodes {
            if node.path == url { return node }
            if node.isDirectory, let children = node.children {
                if let found = findNode(in: children, url: url) {
                    return found
                }
            }
        }
        return nil
    }
}

/// Sidebar 实际布局的 AppKit 锚点。
///
/// 探针不参与交互或状态管理；其 NSView 跟随 Sidebar 子树生命周期和几何尺寸，
/// 让回归测试能验证根目录变化确实触发重建，而普通显隐仍复用同一子树。
struct SidebarLayoutProbe: NSViewRepresentable {
    static let viewIdentifier = NSUserInterfaceItemIdentifier("markdownreader.sidebar-layout-probe")

    func makeNSView(context: Context) -> NSView {
        let view = SidebarLayoutProbeView()
        view.identifier = Self.viewIdentifier
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SidebarLayoutProbeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - 递归目录节点视图

/// 支持展开/折叠绑定的递归目录节点视图
struct FileNodeRow: View {
    let node: FileNode
    let fileTreeViewModel: FileTreeViewModel
    let documentViewModel: DocumentViewModel
    /// Task 9：用于跨窗口所有权标记。目录行不使用，但文件行需要。
    let session: WindowSession
    /// 是否为工作区顶层根节点（仅根行显示「从工作区移除」菜单）
    var isWorkspaceRoot: Bool = false
    @Environment(\.themeColors) private var themeColors
    @Environment(\.language) private var language

    /// 是否为当前选中项
    private var isSelected: Bool {
        fileTreeViewModel.selectedFileURL == node.path
    }

    /// 自定义选中背景（模仿系统选中样式：左侧留空、圆角、accentSoft）
    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            // 先加圆角，再整体加 padding，确保圆角可见
            themeColors.accentSoft
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 28)
                .padding(.trailing, 6)
                .padding(.vertical, 2)
        } else {
            Color.clear
        }
    }

    var body: some View {
        if let children = node.children, !children.isEmpty {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { fileTreeViewModel.isExpanded(node.path) },
                    set: { _ in fileTreeViewModel.toggleExpand(node.path) }
                )
            ) {
                ForEach(children) { child in
                    FileNodeRow(node: child, fileTreeViewModel: fileTreeViewModel, documentViewModel: documentViewModel, session: session)
                }
            } label: {
                FileRowView(node: node, fileTreeViewModel: fileTreeViewModel, documentViewModel: documentViewModel, session: session, isWorkspaceRoot: isWorkspaceRoot)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // 点击目录标签区域切换展开/折叠
                        fileTreeViewModel.toggleExpand(node.path)
                    }
                    .contextMenu { directoryContextMenu }
            }
            .listRowBackground(selectionBackground)
        } else {
            // 文件行使用 Button 确保可靠选中
            Button {
                fileTreeViewModel.selectFile(node)
            } label: {
                FileRowView(node: node, fileTreeViewModel: fileTreeViewModel, documentViewModel: documentViewModel, session: session)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .listRowBackground(selectionBackground)
            .contextMenu { fileContextMenu }
        }
    }

    // MARK: - 目录右键菜单

    /// 目录的右键菜单：新建文档、新建子目录、在访达中打开、复制路径、重命名、移动到、删除
    @ViewBuilder
    private var directoryContextMenu: some View {
        Button {
            fileTreeViewModel.createNewFileInDirectory(node.path)
        } label: {
            Label(L10n.tr(.contextMenuNewFile, language: language), systemImage: "doc.badge.plus")
        }
        Button {
            fileTreeViewModel.createSubdirectory(in: node.path)
        } label: {
            Label(L10n.tr(.contextMenuNewSubdirectory, language: language), systemImage: "folder.badge.plus")
        }
        Divider()
        Button {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: node.path.path)
        } label: {
            Label(L10n.tr(.contextMenuOpenInFinder, language: language), systemImage: "folder")
        }
        Divider()
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(node.path.path, forType: .string)
        } label: {
            Label(L10n.tr(.contextMenuCopyPath, language: language), systemImage: "doc.on.doc")
        }
        Divider()
        Button {
            fileTreeViewModel.renameItem(node)
        } label: {
            Label(L10n.tr(.contextMenuRename, language: language), systemImage: "pencil")
        }
        Button {
            fileTreeViewModel.moveItem(node)
        } label: {
            Label(L10n.tr(.contextMenuMoveTo, language: language), systemImage: "folder.and.arrow.down")
        }
        Divider()
        Button {
            fileTreeViewModel.deleteItem(node)
        } label: {
            Label(L10n.tr(.contextMenuDelete, language: language), systemImage: "trash")
        }

        // 工作区顶层根：从工作区移除（不删除磁盘文件）
        if isWorkspaceRoot && session.appViewModel.isWorkspaceMode {
            Divider()
            Button {
                session.removeFolderFromWorkspace(node.path)
            } label: {
                Label(L10n.tr(.workspaceRemoveFolder, language: language), systemImage: "folder.badge.minus")
            }
        }
    }

    // MARK: - 文件右键菜单

    /// 文件的右键菜单：重新加载、复制路径、在访达中打开、新建文档、重命名、移动到、删除
    @ViewBuilder
    private var fileContextMenu: some View {
        // 重新加载：仅对当前打开且被外部修改的文件可用
        Button {
            // 回归修复：直接调用本窗口命令目标，不通过 FocusedValue 反查。
            fileTreeViewModel.session?.commandTarget.perform(.reloadFile)
        } label: {
            Label(L10n.tr(.contextMenuReload, language: language), systemImage: "arrow.clockwise")
        }
        .disabled(
            documentViewModel.currentFileURL != node.path
                || !documentViewModel.isFileModifiedExternally
        )
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(node.path.path, forType: .string)
        } label: {
            Label(L10n.tr(.contextMenuCopyPath, language: language), systemImage: "doc.on.doc")
        }
        Divider()
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([node.path])
        } label: {
            Label(L10n.tr(.contextMenuOpenInFinder, language: language), systemImage: "folder")
        }
        Divider()
        Button {
            // 在文件所在目录下新建文档
            fileTreeViewModel.createNewFileInDirectory(node.path.deletingLastPathComponent())
        } label: {
            Label(L10n.tr(.contextMenuNewFile, language: language), systemImage: "doc.badge.plus")
        }
        Divider()
        Button {
            fileTreeViewModel.renameItem(node)
        } label: {
            Label(L10n.tr(.contextMenuRename, language: language), systemImage: "pencil")
        }
        Button {
            fileTreeViewModel.moveItem(node)
        } label: {
            Label(L10n.tr(.contextMenuMoveTo, language: language), systemImage: "folder.and.arrow.down")
        }
        Divider()
        Button {
            fileTreeViewModel.deleteItem(node)
        } label: {
            Label(L10n.tr(.contextMenuDelete, language: language), systemImage: "trash")
        }
    }
}

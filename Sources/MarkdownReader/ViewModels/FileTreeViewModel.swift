import SwiftUI
import MarkdownReaderKit

/// 目录树视图模型，管理目录树数据和展开/折叠状态
@MainActor
@Observable
final class FileTreeViewModel {

    // MARK: - 状态

    /// 目录树根节点
    var nodes: [FileNode] = []

    /// 已展开的目录 URL 集合
    var expandedDirs: Set<URL> = []

    /// 当前选中的文件 URL
    var selectedFileURL: URL?

    /// 是否正在加载
    var isLoading: Bool = false

    /// 错误信息
    var errorMessage: String?

    /// 是否为空目录（无 Markdown 文件）
    var isEmptyDirectory: Bool = false

    /// 当前界面语言（右键菜单对话框使用）
    var language: Language = .en

    // MARK: - 依赖

    private let fileService: FileService

    /// 设置模型（用于读取文件树过滤设置）
    var settings: SettingsModel

    /// 文档视图模型（弱引用，用于协调重命名/删除/移动时的编辑状态）
    weak var documentViewModel: DocumentViewModel?

    /// 回归修复：持有所属 session（弱引用），使右键菜单等无环境上下文的回调能直接
    /// 调用本窗口命令目标，不通过 FocusedValue 反查。由 WindowSession.init 注入。
    weak var session: WindowSession?

    /// 文件系统监控器
    private let fileSystemWatcher = FileSystemWatcher()

    /// 是否正在刷新（防止并发刷新）
    private var isRefreshing = false

    /// 是否有待处理的刷新请求
    private var needsRefresh = false

    /// 防止切换或关闭目录后，旧扫描结果重新安装监控。
    private var directoryGeneration = UUID()

    // MARK: - 初始化

    init(fileService: FileService = FileService(), settings: SettingsModel = SettingsModel.shared) {
        self.fileService = fileService
        self.settings = settings
    }

    // MARK: - 方法

    /// 加载目录树
    /// - Parameter directory: 根目录 URL
    func loadDirectory(_ directory: URL) async {
        directoryGeneration = UUID()
        let generation = directoryGeneration
        isRefreshing = false
        needsRefresh = false
        isLoading = true
        errorMessage = nil
        isEmptyDirectory = false

        // 停止之前的监控
        fileSystemWatcher.stopWatching()

        do {
            let children = try await fileService.scanDirectory(
                directory,
                showHiddenFiles: settings.showHiddenFiles,
                showNonMarkdownFiles: settings.showNonMarkdownFiles
            )
            guard directoryGeneration == generation else { return }
            isEmptyDirectory = !fileService.directoryContainsMarkdown(
                directory,
                showHiddenFiles: settings.showHiddenFiles
            )

            // 根目录作为一级节点显示，子目录内容作为其 children
            let rootNode = FileNode(
                name: directory.lastPathComponent,
                path: directory,
                isDirectory: true,
                children: children
            )
            nodes = [rootNode]

            // 默认展开根目录（显示第一级目录和文件）
            expandedDirs.insert(directory)
        } catch {
            guard directoryGeneration == generation else { return }
            errorMessage = error.localizedDescription
            nodes = []
        }

        isLoading = false

        // 开始监控目录变化
        startWatching(directory)
    }

    /// 刷新目录树（由文件系统监控触发，不显示加载状态，保留展开和选中状态）
    func refreshDirectory() async {
        if isRefreshing {
            // 已有刷新在进行中，标记需要再次刷新
            needsRefresh = true
            return
        }

        guard let dir = rootDirectory else { return }
        let generation = directoryGeneration

        // 检查根目录是否仍然存在
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            // 根目录已被删除或移动
            clearDirectory()
            errorMessage = "目录已被删除或移动"
            return
        }

        isRefreshing = true

        do {
            let children = try await fileService.scanDirectory(
                dir,
                showHiddenFiles: settings.showHiddenFiles,
                showNonMarkdownFiles: settings.showNonMarkdownFiles
            )
            guard directoryGeneration == generation else { return }

            let rootNode = FileNode(
                name: dir.lastPathComponent,
                path: dir,
                isDirectory: true,
                children: children
            )
            nodes = [rootNode]

            // 清理已不存在的展开目录
            let allPaths = Set(collectAllPaths(from: nodes))
            expandedDirs = expandedDirs.intersection(allPaths)
            expandedDirs.insert(dir)

            // 如果选中的文件已不存在，清除选中
            // 仅当选中文件的路径位于当前根目录下时才清除
            // 单文件模式下，选中文件可能不在根目录树中，不应被清除
            if let selected = selectedFileURL,
               selected.path.hasPrefix(dir.path + "/"),
               !allPaths.contains(selected) {
                selectedFileURL = nil
            }

            isEmptyDirectory = !fileService.directoryContainsMarkdown(
                dir,
                showHiddenFiles: settings.showHiddenFiles
            )
            errorMessage = nil
            // 链接新增、删除或改指后，以本次扫描得到的真实目录重建监控范围。
            startWatching(dir)
        } catch {
            guard directoryGeneration == generation else { return }
            // 刷新失败时不覆盖已有数据，仅记录错误
        }

        isRefreshing = false

        // 如果刷新期间有新的变更，再次刷新
        if needsRefresh {
            needsRefresh = false
            Task { @MainActor in
                await refreshDirectory()
            }
        }
    }

    /// 停止文件监控并清空目录树
    /// - Parameter clearSelection: 是否清除选中状态，默认 true。
    ///   切换单文件模式时传 false，避免 selectedFileURL 瞬时 nil 翻转触发 SelectionChangeModifier。
    func clearDirectory(clearSelection: Bool = true) {
        directoryGeneration = UUID()
        fileSystemWatcher.stopWatching()
        nodes = []
        expandedDirs = []
        if clearSelection {
            selectedFileURL = nil
        }
        errorMessage = nil
        isLoading = false
        isEmptyDirectory = false
        isRefreshing = false
        needsRefresh = false
    }

    /// 切换目录展开/折叠
    func toggleExpand(_ url: URL) {
        if expandedDirs.contains(url) {
            expandedDirs.remove(url)
        } else {
            expandedDirs.insert(url)
        }
    }

    /// 判断目录是否已展开
    func isExpanded(_ url: URL) -> Bool {
        expandedDirs.contains(url)
    }

    /// 选中文件（包括非 .md 文件，以触发错误提示）。
    /// Task 9：经 session.requestFileSelection 路由，所有权冲突时不改选中项。
    /// 通过 `onSelectFile` 回调交由持有 session 的视图层执行路由，避免 VM 反向依赖 Coordinator。
    var onSelectFileViaSession: ((URL) -> Void)?

    func selectFile(_ node: FileNode) {
        if node.isDirectory { return }
        // 优先经 session 路由（多窗口）；无 session 回调时回退直接赋值（兼容测试/单窗口）。
        if let route = onSelectFileViaSession {
            route(node.path)
        } else {
            selectedFileURL = node.path
        }
    }

    /// 获取扁平化的可见节点列表（用于键盘导航）
    func flattenedVisibleNodes() -> [FileNode] {
        var result: [FileNode] = []
        for node in nodes {
            result.append(node)
            if node.isDirectory, expandedDirs.contains(node.path), let children = node.children {
                result.append(contentsOf: flattenChildren(children))
            }
        }
        return result
    }

    /// 在扁平列表中移动选中项
    func moveSelection(direction: Int) -> FileNode? {
        let flat = flattenedVisibleNodes()
        guard !flat.isEmpty else { return nil }

        let currentIndex: Int
        if let currentURL = selectedFileURL,
           let idx = flat.firstIndex(where: { $0.path == currentURL }) {
            currentIndex = idx
        } else {
            currentIndex = -1
        }

        let newIndex = max(0, min(flat.count - 1, currentIndex + direction))
        let node = flat[newIndex]

        if node.isDirectory {
            toggleExpand(node.path)
        } else {
            selectFile(node)
        }

        return node
    }

    // MARK: - 新建文件

    /// 在指定目录下创建新的 Markdown 文件
    /// - Parameter directory: 目标目录 URL，若为 nil 则使用根目录
    /// - Returns: 新建文件的 URL，失败返回 nil
    func createNewFile(in directory: URL? = nil) -> URL? {
        let targetDir = directory ?? rootDirectory
        guard let dir = targetDir else { return nil }

        // 生成不重名的文件名
        var fileName = "Untitled.md"
        var fileURL = dir.appendingPathComponent(fileName)
        var counter = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileName = "Untitled \(counter).md"
            fileURL = dir.appendingPathComponent(fileName)
            counter += 1
        }

        // 创建空文件
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            return nil
        }

        // 刷新目录树（使用 refreshDirectory 避免重启监控器）
        Task {
            await refreshDirectory()
            // 选中新建的文件
            selectedFileURL = fileURL
        }

        return fileURL
    }

    /// 根目录 URL（供外部访问）
    var rootDirectory: URL? {
        nodes.first?.path
    }

    // MARK: - 文件监控

    /// 开始监控目录变化
    private func startWatching(_ directory: URL) {
        let urls = fileService.directoryWatchURLs(root: directory, nodes: nodes)
        fileSystemWatcher.startWatching(urls: urls) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshDirectory()
            }
        }
    }

    /// 收集所有节点路径（用于清理展开状态和选中状态）
    private func collectAllPaths(from nodes: [FileNode]) -> [URL] {
        var paths: [URL] = []
        for node in nodes {
            paths.append(node.path)
            if let children = node.children {
                paths.append(contentsOf: collectAllPaths(from: children))
            }
        }
        return paths
    }

    // MARK: - 私有方法

    private func flattenChildren(_ children: [FileNode]) -> [FileNode] {
        var result: [FileNode] = []
        for node in children {
            result.append(node)
            if node.isDirectory, expandedDirs.contains(node.path), let subChildren = node.children {
                result.append(contentsOf: flattenChildren(subChildren))
            }
        }
        return result
    }

    // MARK: - 右键菜单操作

    /// 在指定目录下新建 Markdown 文件（右键菜单用，与工具栏逻辑一致）
    /// - Parameter directory: 目标目录 URL
    func createNewFileInDirectory(_ directory: URL) {
        _ = createNewFile(in: directory)
    }

    /// 在指定目录下新建子目录
    /// - Parameter parentDirectory: 父目录 URL
    func createSubdirectory(in parentDirectory: URL) {
        // 生成不重名的目录名
        var dirName = "New Folder"
        var dirURL = parentDirectory.appendingPathComponent(dirName)
        var counter = 1
        while FileManager.default.fileExists(atPath: dirURL.path) {
            dirName = "New Folder \(counter)"
            dirURL = parentDirectory.appendingPathComponent(dirName)
            counter += 1
        }

        do {
            try fileService.createDirectory(in: parentDirectory, name: dirName)
            Task {
                await refreshDirectory()
                // 展开父目录以显示新建的子目录
                expandedDirs.insert(parentDirectory)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 重命名文件或目录
    /// - Parameter node: 要重命名的节点
    func renameItem(_ node: FileNode) {
        let alert = NSAlert()
        alert.messageText = L10n.tr(.renameTitle, language: language)
        alert.informativeText = L10n.tr(.renameMessage, language: language, args: ["name": node.name])
        alert.alertStyle = .informational

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = node.name
        // 如果是文件，选中不含扩展名的部分
        if !node.isDirectory {
            let nameWithoutExt = node.name.replacingOccurrences(
                of: ".\(node.path.pathExtension)",
                with: "",
                options: .anchored
            )
            let extRange = NSRange(location: 0, length: nameWithoutExt.utf16.count)
            // 延迟选中文件名（不含扩展名），确保文本框已准备好
            DispatchQueue.main.async {
                if let editor = textField.currentEditor() {
                    editor.selectedRange = extRange
                }
            }
        }
        alert.accessoryView = textField

        alert.addButton(withTitle: L10n.tr(.confirm, language: language))
        alert.addButton(withTitle: L10n.tr(.unsavedCancel, language: language))

        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"

        // 确保 NSAlert 在前台
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        guard response == .alertFirstButtonReturn else { return }

        let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            showError(L10n.tr(.renameEmptyName, language: language))
            return
        }
        guard newName != node.name else { return }

        // 检查同名项是否已存在
        let newURL = node.path.deletingLastPathComponent().appendingPathComponent(newName)
        if FileManager.default.fileExists(atPath: newURL.path) {
            showError(L10n.tr(.renameNameExists, language: language))
            return
        }

        do {
            let renamedURL = try fileService.renameItem(at: node.path, to: newName)
            // 更新 DocumentViewModel 的引用
            if let docVM = documentViewModel {
                docVM.handleFileRenamed(from: node.path, to: renamedURL)
            }
            // 更新选中状态
            if selectedFileURL == node.path {
                selectedFileURL = renamedURL
            }
            // 更新展开状态
            if node.isDirectory {
                if expandedDirs.contains(node.path) {
                    expandedDirs.remove(node.path)
                    expandedDirs.insert(renamedURL)
                }
            }
            Task {
                await refreshDirectory()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 删除文件或目录（移到废纸篓）
    /// - Parameter node: 要删除的节点
    func deleteItem(_ node: FileNode) {
        let alert = NSAlert()
        alert.alertStyle = .warning

        if node.isDirectory {
            alert.messageText = L10n.tr(.deleteTitle, language: language)
            alert.informativeText = L10n.tr(.deleteDirectoryMessage, language: language, args: ["name": node.name])
        } else {
            alert.messageText = L10n.tr(.deleteTitle, language: language)
            alert.informativeText = L10n.tr(.deleteMessage, language: language, args: ["name": node.name])
        }

        alert.addButton(withTitle: L10n.tr(.contextMenuDelete, language: language))
        alert.addButton(withTitle: L10n.tr(.unsavedCancel, language: language))

        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        guard response == .alertFirstButtonReturn else { return }

        do {
            // 如果删除的是当前正在编辑的文件，先保存或清理编辑状态
            if let docVM = documentViewModel {
                docVM.handleFileDeleted(at: node.path)
            }
            try fileService.trashItem(at: node.path)
            // 清除选中状态
            if selectedFileURL == node.path || (node.isDirectory && selectedFileURL?.path.hasPrefix(node.path.path + "/") == true) {
                selectedFileURL = nil
            }
            // 清除展开状态
            if node.isDirectory {
                expandedDirs = expandedDirs.filter { !$0.path.hasPrefix(node.path.path + "/") && $0 != node.path }
            }
            Task {
                await refreshDirectory()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 移动文件或目录到其他位置
    /// - Parameter node: 要移动的节点
    func moveItem(_ node: FileNode) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.tr(.moveSelectFolder, language: language)
        panel.directoryURL = rootDirectory

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        // 不能移动到自身或自身子目录
        if destination.path.hasPrefix(node.path.path) {
            return
        }
        // 检查目标位置是否已存在同名项
        let destinationPath = destination.appendingPathComponent(node.name)
        if FileManager.default.fileExists(atPath: destinationPath.path) {
            showError(L10n.tr(.renameNameExists, language: language))
            return
        }

        do {
            let movedURL = try fileService.moveItem(at: node.path, to: destination)
            // 更新 DocumentViewModel 的引用
            if let docVM = documentViewModel {
                docVM.handleFileMoved(from: node.path, to: movedURL)
            }
            // 更新选中状态
            if selectedFileURL == node.path {
                selectedFileURL = movedURL
            }
            // 清理展开状态中的旧路径
            if node.isDirectory {
                let oldExpanded = expandedDirs.filter { $0.path.hasPrefix(node.path.path) }
                for oldURL in oldExpanded {
                    expandedDirs.remove(oldURL)
                    let relativePath = oldURL.path.replacingOccurrences(of: node.path.path, with: movedURL.path)
                    expandedDirs.insert(URL(fileURLWithPath: relativePath))
                }
            }
            Task {
                await refreshDirectory()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 显示错误提示
    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

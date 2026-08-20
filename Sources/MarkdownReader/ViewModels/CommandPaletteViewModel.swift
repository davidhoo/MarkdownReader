import SwiftUI
import MarkdownReaderKit

/// 命令面板文件条目
struct CommandPaletteFileItem: Identifiable {
    let id: String
    let url: URL
    let relativePath: String
    let fileName: String
}

/// 命令面板视图模型（仅文件搜索模式）
@MainActor
@Observable
final class CommandPaletteViewModel {

    // MARK: - 状态

    /// 搜索文本
    var searchText: String = ""

    /// 过滤后的结果列表
    var filteredItems: [CommandPaletteFileItem] = []

    /// 当前选中索引
    var selectedIndex: Int = 0

    /// 是否可见
    var isVisible: Bool = false
    /// 防止 handleSearchTextChanged 重入
    private var isUpdatingSearch: Bool = false

    // MARK: - 缓存

    /// 缓存的所有文件列表（避免每次输入变化都递归遍历文件树）
    private var cachedFiles: [CommandPaletteFileItem] = []

    /// 缓存对应的根目录列表（工作区根集合变化时使缓存失效）
    private var cachedRootDirs: [URL] = []

    // MARK: - 依赖

   var appViewModel: AppViewModel?
   var fileTreeViewModel: FileTreeViewModel?
   var documentViewModel: DocumentViewModel?
   var settings: SettingsModel?
    weak var coordinator: WindowCoordinator?
    var windowID: WindowID?

    // MARK: - 初始化

    init() {}

    /// 设置依赖（由 ContentView 在挂载时调用）
    func configure(
        appViewModel: AppViewModel,
        fileTreeViewModel: FileTreeViewModel,
        documentViewModel: DocumentViewModel,
        settings: SettingsModel
    ) {
        self.appViewModel = appViewModel
        self.fileTreeViewModel = fileTreeViewModel
        self.documentViewModel = documentViewModel
        self.settings = settings
    }

    // MARK: - 方法

    /// 显示命令面板
    func show() {
        searchText = ""
        selectedIndex = 0
        invalidateFileCache()
        updateFilteredItems()
        isVisible = true
    }

    /// 隐藏命令面板
    func hide() {
        isVisible = false
        searchText = ""
    }

    /// 选择当前项（回车键使用）
    func selectCurrent() {
        // 优先检查搜索文本是否可直接作为路径打开
        if tryOpenAsDirectPath() { return }
        guard selectedIndex < filteredItems.count else { return }
        let item = filteredItems[selectedIndex]
        selectItem(item)
    }

    /// 选择指定项（直接传 item，避免索引错位）
    func selectItem(_ item: CommandPaletteFileItem) {
        hide()
        openFile(item.url)
    }
 
    /// 尝试将搜索文本作为路径直接打开
    /// - 绝对路径（/ 或 ~/ 开头）：文件存在且为 Markdown 则直接打开，目录则打开目录
    /// - 相对路径：拼接根目录，文件存在且为 Markdown 则直接打开
    /// - Returns: 是否成功打开
    private func tryOpenAsDirectPath() -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return false }
 
        // 绝对路径处理
        if query.hasPrefix("/") || query.hasPrefix("~") {
            let expandedPath = NSString(string: query).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
 
            if isDir.boolValue {
                // 打开目录
                hide()
                coordinator?.enqueue(OpenRequest(url: url, source: .commandPalette, preferredWindowID: windowID))
                return true
            } else if FileService.isKnownMarkdownExtension(url) {
                // 打开 Markdown 文件
                hide()
                openFile(url)
                return true
            }
            return false
        }
 
        // 相对路径处理：拼接根目录
        if let rootDir = appViewModel?.rootDirectory ?? fileTreeViewModel?.rootDirectory {
            let url = rootDir.appendingPathComponent(query)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
 
            if isDir.boolValue {
                // 打开子目录（在当前根目录下）
                hide()
                // 相对路径目录：在文件树中选中该目录下的文件
                // 或者打开为新的根目录 — 这里选择打开目录
                coordinator?.enqueue(OpenRequest(url: url, source: .commandPalette, preferredWindowID: windowID))
                return true
            } else if FileService.isKnownMarkdownExtension(url) {
                hide()
                openFile(url)
                return true
            }
        }
 
        return false
    }

    /// 上移选中
    func moveUp() {
        if selectedIndex > 0 {
            selectedIndex -= 1
        } else {
            selectedIndex = max(0, filteredItems.count - 1)
        }
    }

    /// 下移选中
    func moveDown() {
        if selectedIndex < filteredItems.count - 1 {
            selectedIndex += 1
        } else {
            selectedIndex = 0
        }
    }

    // MARK: - 私有方法

    /// 处理搜索文本变化（由 View 层 onChange 调用，确保 @Observable 下 didSet 不可靠时仍能触发更新）
    func handleSearchTextChanged() {
        guard !isUpdatingSearch else { return }
        isUpdatingSearch = true
        defer { isUpdatingSearch = false }
        updateFilteredItems()
    }

    /// 更新过滤结果
    private func updateFilteredItems() {
        if searchText.isEmpty {
            filteredItems = []
        } else {
            filteredItems = searchFiles(query: searchText)
        }
        selectedIndex = filteredItems.isEmpty ? 0 : min(selectedIndex, filteredItems.count - 1)
    }

    /// 使文件缓存失效（目录变化时调用）
    func invalidateFileCache() {
        cachedFiles = []
        cachedRootDirs = []
    }

    /// 搜索文件（工作区多根：跨全部根目录搜索）
    private func searchFiles(query: String) -> [CommandPaletteFileItem] {
        guard let fileTreeVM = fileTreeViewModel else {
            return searchFilesOutsideRoot(query: query)
        }
        let rootDirs = appViewModel?.rootDirectories ?? fileTreeVM.rootDirectories
        guard !rootDirs.isEmpty else {
            return searchFilesOutsideRoot(query: query)
        }

        // 使用缓存
        if cachedRootDirs != rootDirs || cachedFiles.isEmpty {
            cachedFiles = collectAllFiles(from: fileTreeVM.nodes, rootDirs: rootDirs)
            cachedRootDirs = rootDirs
        }
        let allFiles = cachedFiles

        // 使用 fuzzy match 匹配，支持字符间跳跃（如搜 "rm" 匹配 "README.md"）
        let matched = allFiles.compactMap { file -> (file: CommandPaletteFileItem, score: Int)? in
            let score = fuzzyScore(file: file, query: query)
            guard score > 0 else { return nil }
            return (file, score)
        }

        // 按得分降序排序
        let sorted = matched.sorted { $0.score > $1.score }

        return Array(sorted.prefix(20).map { $0.file })
    }

    /// 计算模糊匹配得分（得分越高越相关）
    /// 支持子串匹配和字符间跳跃匹配（fuzzy match）
    /// 评分规则：
    /// - 文件名前缀子串匹配（最高）> 文件名子串包含 > 文件名 fuzzy > 路径匹配
    /// - 匹配位置越靠前得分越高；连续匹配加分
    /// - 路径深度越浅得分越高
    private func fuzzyScore(file: CommandPaletteFileItem, query: String) -> Int {
        let lowerQuery = query.lowercased()
        let lowerName = file.fileName.lowercased()
        let lowerPath = file.relativePath.lowercased()

        var score = 0
        var hasMatch = false

        // 路径精确匹配（最高优先级，如输入 docs/design.md 精确匹配）
        if lowerPath == lowerQuery {
            score += 1200
            hasMatch = true
        }
        // 路径前缀匹配（如输入 docs/d 匹配 docs/design.md）
        else if lowerPath.hasPrefix(lowerQuery) {
            score += 900
            hasMatch = true
            score += max(0, 100 - lowerPath.count)
        }
        // 文件名前缀匹配
        else if lowerName.hasPrefix(lowerQuery) {
            score += 1000
            hasMatch = true
            score += max(0, 100 - lowerName.count)
        }
        // 文件名子串包含匹配（中优先级）
        else if lowerName.contains(lowerQuery) {
            score += 500
            hasMatch = true
            if let range = lowerName.range(of: lowerQuery) {
                let position = lowerName.distance(from: lowerName.startIndex, to: range.lowerBound)
                score += max(0, 50 - position)
            }
        }
        // 文件名 fuzzy match（字符间跳跃匹配）
        else if let fuzzyResult = fuzzyMatch(text: lowerName, query: lowerQuery) {
            score += 300
            hasMatch = true
            score += fuzzyResult.consecutiveBonus
            score += max(0, 40 - fuzzyResult.firstMatchIndex)
        }
        // 路径中子串匹配
        else if lowerPath.contains(lowerQuery) {
            score += 100
            hasMatch = true
            if let range = lowerPath.range(of: lowerQuery) {
                let position = lowerPath.distance(from: lowerPath.startIndex, to: range.lowerBound)
                score += max(0, 30 - position)
            }
        }
        // 路径 fuzzy match
        else if let fuzzyResult = fuzzyMatch(text: lowerPath, query: lowerQuery) {
            score += 80
            hasMatch = true
            score += fuzzyResult.consecutiveBonus
            score += max(0, 20 - fuzzyResult.firstMatchIndex)
        }

        // 路径深度惩罚
        let depth = file.relativePath.components(separatedBy: "/").count - 1
        score -= depth * 10

        // 无匹配返回 -1，有匹配时确保不被深度惩罚压到负数
        return hasMatch ? max(score, 0) : -1
    }

    /// 字符间跳跃模糊匹配
    private func fuzzyMatch(text: String, query: String) -> (consecutiveBonus: Int, firstMatchIndex: Int)? {
        guard !query.isEmpty && !text.isEmpty else { return nil }

        var queryIdx = query.startIndex
        var textIdx = text.startIndex
        var consecutiveCount = 0
        var consecutiveMax = 0
        var firstMatchIndex = -1

        while queryIdx < query.endIndex && textIdx < text.endIndex {
            if query[queryIdx] == text[textIdx] {
                if firstMatchIndex < 0 {
                    firstMatchIndex = text.distance(from: text.startIndex, to: textIdx)
                }
                consecutiveCount += 1
                consecutiveMax = max(consecutiveMax, consecutiveCount)
                queryIdx = query.index(after: queryIdx)
            } else {
                consecutiveCount = 0
            }
            textIdx = text.index(after: textIdx)
        }

        guard queryIdx == query.endIndex else { return nil }

        let consecutiveBonus = consecutiveMax * 15
        return (consecutiveBonus: consecutiveBonus, firstMatchIndex: firstMatchIndex >= 0 ? firstMatchIndex : 999)
    }

    /// 无根目录时搜索文件
    private func searchFilesOutsideRoot(query: String) -> [CommandPaletteFileItem] {
        let expandedPath = NSString(string: query).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expandedPath)

        if query.hasPrefix("/") || query.hasPrefix("~") {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)
                if !isDir.boolValue {
                    return [CommandPaletteFileItem(
                        id: fileURL.path,
                        url: fileURL,
                        relativePath: fileURL.lastPathComponent,
                        fileName: fileURL.lastPathComponent
                    )]
                }
            }
            return []
        }

        return []
    }

    /// 递归收集所有 Markdown 文件节点（相对路径按所属根计算，多根以「根名/相对路径」区分）
    private func collectAllFiles(from nodes: [FileNode], rootDirs: [URL]) -> [CommandPaletteFileItem] {
        let resolvedRoots = rootDirs.map { $0.resolvingSymlinksInPath() }
        var results: [CommandPaletteFileItem] = []
        for node in nodes {
            if node.isDirectory {
                if let children = node.children {
                    results.append(contentsOf: collectAllFiles(from: children, rootDirs: rootDirs))
                }
            } else {
                guard FileService.isKnownMarkdownExtension(node.path) else { continue }
                let resolvedNodePath = node.path.resolvingSymlinksInPath()
                // 找到所属根，计算相对路径；带根名前缀避免多根同名文件混淆
                let matchedRoot = resolvedRoots.first {
                    resolvedNodePath.path.hasPrefix($0.path + "/")
                }
                let relativePath: String
                if let root = matchedRoot {
                    let rel = String(resolvedNodePath.path.dropFirst(root.path.count + 1))
                    let rootName = root.lastPathComponent
                    relativePath = rootDirs.count > 1 ? "\(rootName)/\(rel)" : rel
                } else {
                    relativePath = node.path.lastPathComponent
                }
                results.append(CommandPaletteFileItem(
                    id: node.path.path,
                    url: node.path,
                    relativePath: relativePath,
                    fileName: node.name
                ))
            }
        }
        return results
    }

    /// 打开文件
    private func openFile(_ url: URL) {
        guard let appVM = appViewModel,
              let fileTreeVM = fileTreeViewModel else { return }

        // 解析符号链接后再比较路径，确保软链接路径和真实路径都能正确匹配
        let resolvedURL = url.resolvingSymlinksInPath()
        let inSomeRoot = appVM.rootDirectories.contains { rootDir in
            let resolvedRootDir = rootDir.resolvingSymlinksInPath()
            return resolvedURL.path.hasPrefix(resolvedRootDir.path + "/")
        }
        if inSomeRoot {
            // 回归修复：目录内文件复用与目录树点击同一套窗口内导航规则
            // （requestFileSelection），所有权冲突时激活 owner、不改本窗口选中项。
            fileTreeVM.onSelectFileViaSession?(url) ?? {
                fileTreeVM.selectedFileURL = url
            }()
            return
        }
        // 不在当前工作区根目录下，通过 Coordinator 路由（外部打开去重）
        coordinator?.enqueue(OpenRequest(url: url, source: .commandPalette, preferredWindowID: windowID))
    }
}

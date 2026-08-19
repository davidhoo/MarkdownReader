import SwiftUI
import MarkdownReaderKit

/// 文档视图模型，管理当前文档状态和文件读取
@MainActor
@Observable
final class DocumentViewModel {

    /// 窗口级 Undo 存储（Task 10），由 WindowSession 注入。
    weak var undoStore: WindowUndoStore?

    // MARK: - 状态

    /// 内容版本号，每次程序化更新（reload/load）时递增
    /// 用于通知视图层强制刷新，避免 @Observable 因内容相同而跳过更新
    var contentVersion: Int = 0

    /// 当前文档内容
    var content: String = "" {
        didSet {
            // 内容变更时标记为脏（跳过首次加载时的赋值）
            if currentFileURL != nil && !isLoading {
                markDirtyIfNeeded()
            }
        }
    }

    /// 当前文件 URL
    var currentFileURL: URL? {
        didSet { syncHasDocument() }
    }

    /// 当前文件名
    var fileName: String = ""

    /// 显示模式
    var displayMode: DisplayMode = .rendered

    /// 当前文件是否为纯文本模式（非 Markdown 的 .txt 文件）
    /// 纯文本模式下禁止切换到渲染模式
    var isPlainTextMode: Bool = false

    /// 是否正在加载
    var isLoading: Bool = false

    /// 错误信息
    var fileError: FileError? {
        didSet { syncHasDocument() }
    }

    /// 内容是否有未保存的修改
    var isDirty: Bool = false

    /// 当前文件是否为未保存的新建文件（位于临时目录）
    var isUntitled: Bool = false

    var hasDocument: Bool = false

    /// 文件是否被外部编辑器修改
    var isFileModifiedExternally: Bool = false

    /// 是否正在保存（用于忽略自己保存触发的文件系统事件）
    private(set) var isSaving: Bool = false

    /// 是否正在显示保存面板（防止重复弹窗）
    var isSavePanelShowing: Bool = false

    /// 当前 ContentView 所在窗口是否为 key 窗口。
    /// 仅 key 窗口处理 .saveFile / .saveAsFile / .newFile，避免 macOS 26 多窗口场景下
    /// 隐藏的第二窗口重复响应通知、重复弹出保存面板。
    var isKeyWindow: Bool = false

    /// 新建文件的临时目录
    static let untitledDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MarkdownReader")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 是否有任何未保存的文件（包括当前文件和缓存中的文件）
    var hasAnyDirtyFile: Bool {
        if isDirty { return true }
        for (url, content) in contentCache {
            if let snapshot = diskContentSnapshot[url], content != snapshot {
                return true
            }
        }
        return false
    }

    /// 当前文档的大纲项
    var outlineItems: [OutlineItem] = []

    /// 显式按行跳转请求（非 nil 时触发目的视图滚动到该源码行，滚动后应清空）。
    /// **仅**服务大纲点击、查找上一个/下一个、标题跳转等显式按行跳转；
    /// Raw ↔ Rendered 模式切换的位置交接走 `ScrollTransfer`，不发布此请求。
    /// 统一 1-based `SourceLine`，避免单位混淆。
    var scrollToSourceLineRequest: SourceLine?

    /// Raw 编辑器当前可见区域顶部的源码行（1-based），仅活跃 Raw 编辑器滚动时更新。
    /// 被大纲高亮等既有逻辑读取；模式切换不读取它——位置以主动采样锚点为准。
    var rawVisibleSourceLine: SourceLine = .first

    /// 渲染视图当前可见区域顶部的源码行（1-based），Rendered 模式下由 WebView 滚动回调更新。
    /// 被大纲高亮等既有逻辑读取；模式切换不读取它——位置以主动采样锚点为准。
    var renderedVisibleSourceLine: SourceLine = .first

    // MARK: - 模式切换位置交接（ScrollTransfer）
    //
    // 仅供单栏 Raw ↔ Rendered 模式切换使用，不复用也不替换既有 `scrollToSourceLineRequest`
    // （后者继续服务大纲/查找/标题跳转）。`ScrollTransfer` 携带目标模式、内容版本和 UUID，
    // 只有目的视图在三者全部匹配时才能回执清除；隐藏视图不得抢先消费或清除。

    /// 一次性模式切换交接。`beginScrollTransfer` 生成新 UUID 覆盖旧交接；
    /// 目的视图应用定位后以相同 UUID 回执。
    var scrollTransfer: ScrollTransfer?

    /// 开启一次模式切换交接，返回带新 UUID 的 transfer。新交接覆盖任何未回执的旧交接。
    @discardableResult
    func beginScrollTransfer(
        destination: DisplayMode,
        anchor: SourceScrollAnchor
    ) -> ScrollTransfer {
        let transfer = ScrollTransfer(
            id: UUID(),
            destination: destination,
            contentVersion: contentVersion,
            anchor: anchor
        )
        scrollTransfer = transfer
        return transfer
    }

    /// 目的视图在定位应用后回执。仅当 id、destination、contentVersion 全部匹配当前交接
    /// 时才清除；过期内容、过期模式或快速 A→B→A 切换产生的旧回执一律丢弃。
    func acknowledgeScrollTransfer(id: UUID, destination: DisplayMode, contentVersion: Int) {
        guard let current = scrollTransfer,
              current.id == id,
              current.destination == destination,
              current.contentVersion == contentVersion else {
            return
        }
        scrollTransfer = nil
    }

    /// Per-file 内容缓存：保存未写入磁盘的编辑内容
    /// 切换文件时保存当前内容，切换回来时恢复缓存内容
    /// 确保 per-file UndoManager 的 undo 动作与内容一致
    private var contentCache: [URL: String] = [:]

    /// Per-file 显示模式缓存：每个文件记住自己的显示模式
    /// 切换文件时保存当前模式，切换回来时恢复，避免模式全局串扰
    private var displayModeCache: [URL: DisplayMode] = [:]

    /// Per-file 磁盘内容快照，用于判断内容是否已修改
    private var diskContentSnapshot: [URL: String] = [:]

    /// 当前打开文件的文件系统监控器
    private let fileWatcher = FileSystemWatcher(debounceInterval: 0.5)

    // MARK: - 依赖

    private let fileService: FileService

    /// 设置模型（用于读取默认显示模式等设置）
    var settings: SettingsModel

    // MARK: - 初始化

    init(fileService: FileService = FileService(), settings: SettingsModel = SettingsModel.shared) {
        self.fileService = fileService
        self.settings = settings
        self.displayMode = settings.defaultDisplayMode
    }

    // MARK: - 方法

    /// 加载文件内容
    /// - Parameter url: 文件 URL
    func loadFile(at url: URL) async {
        // 如果是同一文件且被外部修改
        if currentFileURL == url && isFileModifiedExternally {
            if isDirty {
                // 用户有未保存编辑，不自动 reload，保留当前编辑内容和外部修改标记
                // 由 UI 的 reload 按钮流程处理（含确认弹窗）
                return
            } else {
                // 用户没有编辑，静默 reload 是安全的
                await reloadFromDisk()
                return
            }
        }

        // 幂等保护：如果已经加载了同一文件且内容非空，跳过重复加载
        if currentFileURL == url && !content.isEmpty && fileError == nil {
            return
        }

        // 切换文件前，保存当前文件的编辑内容和显示模式到缓存
        if let currentURL = currentFileURL, currentURL != url, hasDocument {
            contentCache[currentURL] = content
            displayModeCache[currentURL] = displayMode
        }

        if isUntitled, let oldURL = currentFileURL, oldURL != url {
            try? FileManager.default.removeItem(at: oldURL)
            contentCache.removeValue(forKey: oldURL)
            diskContentSnapshot.removeValue(forKey: oldURL)
        }

        // 检查文件类型并决定加载方式
        // .md/.markdown/.mdown/.mkd → 正常 Markdown 加载
        // .txt → 读取内容检测，是 Markdown 则正常加载，否则以纯文本模式加载
        // 其他 → 报 unsupportedFileType 错误
        let ext = url.pathExtension.lowercased()
        var forceRawMode = false

        // 先清除之前的错误状态，确保切换文件时 hasDocument 能正确更新
        // 修复：从不支持格式文件切换到 md 文件时，旧 fileError 未及时清除，
        // 导致 hasDocument 始终为 false，DetailView 继续显示 ErrorView 而非文档内容
        fileError = nil

        if FileService.markdownExtensions.contains(ext) {
            // 已知 Markdown 扩展名，直接加载
        } else if ext == "txt" {
            // .txt 文件需要内容检测
            do {
                let text = try await fileService.readFile(at: url)
                if !FileService.detectMarkdownContent(text) {
                    // 非 Markdown 的 .txt 文件，以纯文本模式加载
                    forceRawMode = true
                }
            } catch {
                fileError = .unsupportedFileType(url.pathExtension)
                content = ""
                currentFileURL = url
                fileName = url.lastPathComponent
                outlineItems = []
                isDirty = false
                isUntitled = false
                return
            }
        } else {
            fileError = .unsupportedFileType(url.pathExtension)
            content = ""
            currentFileURL = url
            fileName = url.lastPathComponent
            outlineItems = []
            isDirty = false
            isUntitled = false
            return
        }

        isLoading = true
        fileError = nil
        isPlainTextMode = forceRawMode

        do {
            let diskContent = try await fileService.readFile(at: url)
            currentFileURL = url
            fileName = url.lastPathComponent
            // 保存之前的快照，用于判断缓存内容是否包含用户编辑
            let previousSnapshot = diskContentSnapshot[url]
            // 保存磁盘内容快照，用于脏状态判断
            diskContentSnapshot[url] = diskContent

            // 判断是否有未保存的编辑：缓存内容与之前的快照不同
            let hasUnsavedEdits: Bool
            if let cached = contentCache[url], let prev = previousSnapshot {
                hasUnsavedEdits = (cached != prev)
            } else {
                hasUnsavedEdits = false
            }

            // 判断磁盘是否被外部修改：磁盘内容与之前的快照不同
            // previousSnapshot 为 nil 表示首次加载此文件，不存在"外部修改"概念
            let diskChangedExternally: Bool
            if let prev = previousSnapshot {
                diskChangedExternally = (diskContent != prev)
            } else {
                diskChangedExternally = false
            }

            if hasUnsavedEdits, let cached = contentCache[url] {
                if diskChangedExternally {
                    // 用户有未保存编辑 且 磁盘也被外部修改 → 冲突场景
                    // 保留用户缓存内容，但标记 isFileModifiedExternally = true
                    // 显示 reload 按钮，让用户决定是否丢弃编辑加载磁盘新内容
                    content = cached
                    isFileModifiedExternally = true
                } else {
                    // 用户有未保存编辑，磁盘未变 → 正常恢复缓存
                    content = cached
                    isFileModifiedExternally = false
                }
            } else {
                // 用户没有编辑，使用磁盘最新内容
                // 无论缓存是否存在，都使用磁盘内容以确保反映外部修改
                content = diskContent
                contentCache[url] = diskContent
                isFileModifiedExternally = false
            }
            // 更新脏状态
            isDirty = (content != diskContent)
            // 加载真实文件时重置 isUntitled
            isUntitled = false
            outlineItems = OutlineService.parse(content)
            // 递增版本号，通知视图层刷新
            contentVersion += 1
            // 恢复目标文件的显示模式
            // 非 Markdown 的 .txt 文件强制使用纯文本模式
            if forceRawMode {
                displayMode = .raw
            } else {
                displayMode = displayModeCache[url] ?? settings.defaultDisplayMode
            }
        } catch let fileError as FileError {
            self.fileError = fileError
            content = ""
            currentFileURL = url
            fileName = url.lastPathComponent
            outlineItems = []
            isDirty = false
            isUntitled = false
        } catch {
            self.fileError = .unknown(error)
            content = ""
            currentFileURL = url
            fileName = url.lastPathComponent
            outlineItems = []
            isDirty = false
            isUntitled = false
        }

        isLoading = false

        // 启动文件监控（排除临时文件）
        startFileWatcher(for: url)
    }

    /// 加载选中的文件节点
    /// - Parameter node: 文件节点
    func loadFileNode(_ node: FileNode) async {
        if !node.isMarkdown {
            fileError = .unsupportedFileType(node.path.pathExtension)
            currentFileURL = node.path
            fileName = node.name
            content = ""
            outlineItems = []
            isUntitled = false
            return
        }
        await loadFile(at: node.path)
    }

    /// 切换显示模式。
    ///
    /// 模式切换的位置交接**只**走 `SourceScrollAnchor` + `ScrollTransfer`（由
    /// `DetailView.handleDisplayModeSwitch` 主动采样后 `beginScrollTransfer`）。
    /// 本方法不再读取 `rawVisibleSourceLine` / `renderedVisibleSourceLine`，
    /// 也不再发布 `scrollToSourceLineRequest`——后者仅供大纲、查找等显式按行跳转。
    /// 真实模式发生变化时，取消先前大纲/查找留下、尚未被消费的旧行号请求，
    /// 防止其在目标视图落位后被异步 replay，覆盖已正确的锚点交接。
    func switchDisplayMode(_ mode: DisplayMode) {
        // 纯文本模式下禁止切换到渲染模式
        if isPlainTextMode && mode == .rendered { return }
        let previousMode = displayMode
        displayMode = mode
        if let url = currentFileURL {
            displayModeCache[url] = mode
        }
        guard previousMode != mode else { return }
        // 真实模式变化：取消遗留的显式按行跳转请求。模式切换的位置以 ScrollTransfer 为准。
        clearScrollRequest()
    }

    /// 请求滚动到指定源码行（大纲导航、查找跳转等显式按行跳转共用）。
    /// 模式切换**不**调用此方法——其位置交接走 `ScrollTransfer`。
    func requestScroll(to sourceLine: SourceLine) {
        scrollToSourceLineRequest = sourceLine
    }

    /// 清除显式按行跳转请求（滚动完成后调用；模式切换时取消遗留请求）。
    func clearScrollRequest() {
        scrollToSourceLineRequest = nil
    }

    @discardableResult
    func createUntitledFile() -> URL? {
        if isUntitled { return nil }

        // 切换前保存当前文件的编辑内容和显示模式
        if let currentURL = currentFileURL, hasDocument {
            contentCache[currentURL] = content
            displayModeCache[currentURL] = displayMode
        }

        let tempDir = Self.untitledDirectory
        let untitledName = "Untitled.md"
        let fileURL = tempDir.appendingPathComponent(untitledName)

        // 创建空文件
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        // 使用 isLoading 阻止 content 的 didSet 触发 markDirtyIfNeeded()
        // 确保所有属性一次性设置完毕后再通知 SwiftUI
        isLoading = true

        currentFileURL = fileURL
        fileName = untitledName
        // 先设置快照，再设置 content，确保 markDirtyIfNeeded 即使被调用也能正确比较
        diskContentSnapshot[fileURL] = ""
        contentCache[fileURL] = ""
        content = ""
        outlineItems = []
        isDirty = false
        isUntitled = true
        fileError = nil
        displayMode = .raw  // 新建文件始终使用 Raw 模式，便于立即开始编辑

        isLoading = false

        // 递增版本号：明确表示这是一次程序化内容替换。
        // `SyntaxHighlightedEditor` 据此用 ViewModel 的空内容覆盖编辑器残留的旧内容，
        // 阻止 first responder 把上一个文件的内容反写回 ViewModel（回归根因 3）。
        contentVersion += 1

        return fileURL
    }

    /// 保存当前文档内容到磁盘
    /// 如果是未保存的新建文件，返回 false 并发送 .saveAsFile 通知
    /// - Returns: 是否保存成功
    @discardableResult
    func save() async -> Bool {
        guard let url = currentFileURL else { return false }

        // 未保存的新建文件需要另存为
        if isUntitled {
            // Task 7：不再 post .saveAsFile 通知。Untitled 保存走 WindowSession.handleSaveAs；
            // 调用方（菜单/标题栏保存按钮）经 FocusedValues 路由。此处返回 false 表示
            // 普通 save 未真正落盘，由上层触发 saveAs 流程。
            return false
        }

        isSaving = true
        defer { isSaving = false }

        do {
            try await fileService.writeFile(at: url, content: content)
            // 更新磁盘快照
            diskContentSnapshot[url] = content
            isDirty = false
            isFileModifiedExternally = false
            // 同步更新缓存
            contentCache[url] = content
            return true
        } catch {
            fileError = .permissionDenied(url)
            return false
        }
    }

    /// 另存为：将内容保存到用户指定的新位置
    /// - Parameter newURL: 用户选择的新保存位置
    /// - Returns: 写入成功返回 `true`；失败返回 `false` 并设置 `fileError`，保留原 Untitled 内容。
    ///
    /// 失败时不修改任何状态（不切换 currentFileURL、不清 isUntitled），调用方据此决定是否
    /// 关闭窗口 / 清未保存标记 / 迁移所有权。副作用只能在成功后执行（见 Task 1 设计）。
    @discardableResult
    func saveAs(to newURL: URL) async -> Bool {
        isSaving = true
        defer { isSaving = false }

        let oldURL = currentFileURL
        do {
            try await fileService.writeFile(at: newURL, content: content)
        } catch {
            // 写入失败：保留原内容与 Untitled 状态，仅呈现错误，不关闭、不清标记
            fileError = .permissionDenied(newURL)
            return false
        }

        // 清理旧的临时文件
        if isUntitled, let old = oldURL {
            try? FileManager.default.removeItem(at: old)
            contentCache.removeValue(forKey: old)
            diskContentSnapshot.removeValue(forKey: old)
        }

        // 更新文件引用
        currentFileURL = newURL
        fileName = newURL.lastPathComponent
        diskContentSnapshot[newURL] = content
        contentCache[newURL] = content
        isDirty = false
        isUntitled = false
        fileError = nil
        // 启动对新保存文件的外部变更监控
        startFileWatcher(for: newURL)
        return true
    }

    /// 检查内容是否与磁盘快照不同，更新脏状态
    private func markDirtyIfNeeded() {
        guard let url = currentFileURL else {
            isDirty = false
            return
        }
        if let snapshot = diskContentSnapshot[url] {
            isDirty = (content != snapshot)
        } else {
            // 无快照时视为未修改，防止 isDirty 保持过时的值
            isDirty = false
        }
    }

    /// 同步 hasDocument 存储属性，确保 @Observable 可靠追踪
    /// 在 currentFileURL / fileError 的 didSet 中自动调用
    private func syncHasDocument() {
        hasDocument = (currentFileURL != nil && fileError == nil)
    }

    /// 检查指定文件是否有未保存的修改
    /// 比较缓存内容（或当前内容）与磁盘快照，判断文件是否处于脏状态
    /// - Parameter url: 文件 URL
    /// - Returns: 是否有未保存的修改
    func isFileDirty(at url: URL) -> Bool {
        // 当前正在编辑的文件，直接使用 isDirty
        if url == currentFileURL {
            return isDirty
        }
        // 非当前文件，比较缓存内容与磁盘快照
        guard let cached = contentCache[url], let snapshot = diskContentSnapshot[url] else {
            return false
        }
        return cached != snapshot
    }

    /// 清除当前文档
    func clearDocument() {
        // 清理未保存新建文件的临时文件
        if isUntitled, let url = currentFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        stopFileWatcher()
        content = ""
        currentFileURL = nil
        fileName = ""
        fileError = nil
        isLoading = false
        isDirty = false
        isUntitled = false
        isPlainTextMode = false
        isFileModifiedExternally = false
        displayMode = settings.defaultDisplayMode
        outlineItems = []
        contentCache.removeAll()
        displayModeCache.removeAll()
        diskContentSnapshot.removeAll()
        // 程序化清空：递增版本号，强制编辑器采用空内容，阻止残留内容反写。
        contentVersion += 1
    }

    /// 取消选中当前文件（保留其他文件的缓存）
    /// 用于外部删除等场景：仅清理当前文件状态，不丢失其他已编辑文件的缓存
    func deselectCurrentFile() {
        stopFileWatcher()
        if let url = currentFileURL {
            contentCache.removeValue(forKey: url)
            displayModeCache.removeValue(forKey: url)
            diskContentSnapshot.removeValue(forKey: url)
        }
        content = ""
        currentFileURL = nil
        fileName = ""
        fileError = nil
        isLoading = false
        isDirty = false
        isUntitled = false
        isPlainTextMode = false
        isFileModifiedExternally = false
        displayMode = settings.defaultDisplayMode
        outlineItems = []
        // 程序化清空：递增版本号，强制编辑器采用空内容，阻止残留内容反写。
        contentVersion += 1
    }

    func discardUntitledFile() {
        guard isUntitled, let url = currentFileURL else { return }
        stopFileWatcher()
        try? FileManager.default.removeItem(at: url)

        contentCache.removeValue(forKey: url)
        diskContentSnapshot.removeValue(forKey: url)
        displayModeCache.removeValue(forKey: url)

        // 完整清理当前 Untitled 文档状态，避免窗口关闭后残留
        // isUntitled == true && isDirty == true，导致后续打开文件误弹未保存提示
        content = ""
        currentFileURL = nil
        fileName = ""
        fileError = nil
        isLoading = false
        isDirty = false
        isUntitled = false
        isPlainTextMode = false
        isFileModifiedExternally = false
        displayMode = settings.defaultDisplayMode
        outlineItems = []
        // 程序化清空：递增版本号，强制编辑器采用空内容，阻止残留内容反写。
        contentVersion += 1
    }

    // MARK: - 文件监控与外部变更检测

    /// 启动对指定文件的外部变更监控
    /// - Parameter url: 要监控的文件 URL
    private func startFileWatcher(for url: URL) {
        // 不监控临时文件
        guard !url.path.hasPrefix(Self.untitledDirectory.path) else {
            fileWatcher.stopWatching()
            return
        }

        // 监控文件所在目录（FSEventStream 不支持直接监控单个文件）
        let directory = url.deletingLastPathComponent()
        fileWatcher.startWatching(url: directory) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.checkExternalFileChange()
            }
        }
    }

    /// 停止文件监控
    private func stopFileWatcher() {
        fileWatcher.stopWatching()
    }

    /// 检查当前文件是否被外部修改
    private func checkExternalFileChange() async {
        guard let url = currentFileURL,
              !isUntitled,
              !isSaving,
              !url.path.hasPrefix(Self.untitledDirectory.path) else { return }

        do {
            let diskContent = try await fileService.readFile(at: url)
            // 与当前内存内容比较：若磁盘内容与内存一致，无需任何操作
            // 这涵盖了保存后 FSEventStream 延迟回调的场景（isSaving 已重置但快照已更新）
            if diskContent == content {
                // 磁盘与内存一致，同步快照以防漂移
                diskContentSnapshot[url] = diskContent
                return
            }
            // 磁盘内容与内存不同，属于外部修改
            // 简化判断：到达此处必然 diskContent != content（第 510 行已排除相等情况）
            // 不再使用 diskContent != snapshot 守卫，因为 loadFile() 从缓存恢复内容时
            // 会将 snapshot 设为当前磁盘内容，导致 snapshot == diskContent 而守卫失效
            if !isDirty {
                // 用户未修改过，自动静默刷新
                // 先更新快照，再设置 content，防止 didSet 中 markDirtyIfNeeded() 误判
                diskContentSnapshot[url] = diskContent
                contentCache[url] = diskContent
                content = diskContent
                outlineItems = OutlineService.parse(diskContent)
                isDirty = false
                // 递增版本号，通知视图层刷新
                contentVersion += 1
                // 清空 undo 栈：内容已被外部替换，旧 undo 历史已无意义
                undoStore?.undoManager(for: url)?.removeAllActions()
            } else {
                // 用户有修改，显示刷新按钮
                isFileModifiedExternally = true
            }
        } catch {
            // 文件可能已被删除，忽略错误
        }
    }

    /// 从磁盘重新加载当前文件（丢弃当前修改）
    func reloadFromDisk() async {
        guard let url = currentFileURL else { return }

        isLoading = true
        isFileModifiedExternally = false

        do {
            let diskContent = try await fileService.readFile(at: url)
            // 先更新快照和缓存，再设置 content，防止 didSet 中 markDirtyIfNeeded() 误判
            diskContentSnapshot[url] = diskContent
            contentCache[url] = diskContent
            content = diskContent
            isDirty = false
            outlineItems = OutlineService.parse(diskContent)
            // 清空 undo 栈：reload 意味着放弃当前修改回到磁盘状态，旧 undo 历史已无意义
            undoStore?.undoManager(for: url)?.removeAllActions()
            // 递增版本号，强制通知视图层刷新
            // 即使磁盘内容与当前 content 相同，视图也需要重新渲染
            contentVersion += 1
        } catch {
            fileError = .unknown(error)
        }

        isLoading = false
    }

    // MARK: - 文件系统操作协调

    /// 处理文件被重命名的场景，更新内部缓存和当前文件引用
    /// - Parameters:
    ///   - oldURL: 重命名前的 URL
    ///   - newURL: 重命名后的 URL
    func handleFileRenamed(from oldURL: URL, to newURL: URL) {
        // 迁移缓存
        if let cached = contentCache[oldURL] {
            contentCache.removeValue(forKey: oldURL)
            contentCache[newURL] = cached
        }
        if let snapshot = diskContentSnapshot[oldURL] {
            diskContentSnapshot.removeValue(forKey: oldURL)
            diskContentSnapshot[newURL] = snapshot
        }
        if let mode = displayModeCache[oldURL] {
            displayModeCache.removeValue(forKey: oldURL)
            displayModeCache[newURL] = mode
        }

        // 更新当前编辑的文件引用
        if currentFileURL == oldURL {
            currentFileURL = newURL
            fileName = newURL.lastPathComponent
            // 同一目录重命名，目录监控仍有效，但重启以确保路径一致性
            startFileWatcher(for: newURL)
        }
    }

    /// 处理文件被删除的场景，清理编辑状态
    /// - Parameter url: 被删除文件的 URL
    func handleFileDeleted(at url: URL) {
        // 清理缓存
        contentCache.removeValue(forKey: url)
        diskContentSnapshot.removeValue(forKey: url)
        displayModeCache.removeValue(forKey: url)

        // 如果当前正在编辑被删除的文件，先保存再清理
        if currentFileURL == url {
            if isDirty {
                // 有未保存修改：另存为临时文件保留内容
                let tempURL = Self.untitledDirectory.appendingPathComponent(fileName)
                try? content.write(to: tempURL, atomically: true, encoding: .utf8)
                currentFileURL = tempURL
                isUntitled = true
                diskContentSnapshot[tempURL] = content
                contentCache[tempURL] = content
            } else {
                // 无未保存修改：直接清理
                deselectCurrentFile()
            }
        }
    }

    /// 处理文件被移动的场景，更新内部缓存和当前文件引用
    /// - Parameters:
    ///   - oldURL: 移动前的 URL
    ///   - newURL: 移动后的 URL
    func handleFileMoved(from oldURL: URL, to newURL: URL) {
        // 迁移缓存（与重命名逻辑一致）
        if let cached = contentCache[oldURL] {
            contentCache.removeValue(forKey: oldURL)
            contentCache[newURL] = cached
        }
        if let snapshot = diskContentSnapshot[oldURL] {
            diskContentSnapshot.removeValue(forKey: oldURL)
            diskContentSnapshot[newURL] = snapshot
        }
        if let mode = displayModeCache[oldURL] {
            displayModeCache.removeValue(forKey: oldURL)
            displayModeCache[newURL] = mode
        }

        // 更新当前编辑的文件引用
        if currentFileURL == oldURL {
            currentFileURL = newURL
            fileName = newURL.lastPathComponent
            startFileWatcher(for: newURL)
        }

        // 如果当前编辑的文件在被移动的目录内，也更新引用
        if let current = currentFileURL, current.path.hasPrefix(oldURL.path + "/") {
            let relativePath = current.path.replacingOccurrences(of: oldURL.path, with: newURL.path)
            let newCurrentURL = URL(fileURLWithPath: relativePath)
            currentFileURL = newCurrentURL
            fileName = newCurrentURL.lastPathComponent
            startFileWatcher(for: newCurrentURL)
        }

        // 迁移目录内所有子文件的缓存
        let keysToMigrate = contentCache.keys.filter { $0.path.hasPrefix(oldURL.path + "/") }
        for key in keysToMigrate {
            let relativePath = key.path.replacingOccurrences(of: oldURL.path, with: newURL.path)
            let newKey = URL(fileURLWithPath: relativePath)
            contentCache[newKey] = contentCache.removeValue(forKey: key)
        }
        let snapshotKeysToMigrate = diskContentSnapshot.keys.filter { $0.path.hasPrefix(oldURL.path + "/") }
        for key in snapshotKeysToMigrate {
            let relativePath = key.path.replacingOccurrences(of: oldURL.path, with: newURL.path)
            let newKey = URL(fileURLWithPath: relativePath)
            diskContentSnapshot[newKey] = diskContentSnapshot.removeValue(forKey: key)
        }
        let modeKeysToMigrate = displayModeCache.keys.filter { $0.path.hasPrefix(oldURL.path + "/") }
        for key in modeKeysToMigrate {
            let relativePath = key.path.replacingOccurrences(of: oldURL.path, with: newURL.path)
            let newKey = URL(fileURLWithPath: relativePath)
            displayModeCache[newKey] = displayModeCache.removeValue(forKey: key)
        }
    }
}

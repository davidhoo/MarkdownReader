import Foundation
import AppKit
import SwiftUI
import MarkdownReaderKit

/// 窗口会话：单个主窗口的业务边界。
///
/// 统一持有目前分散在 `ContentView` 中的窗口级对象，使每个窗口拥有独立的
/// 浏览、文档、编辑和视图状态。`WindowSession` 弱引用 `WindowCoordinator`，
/// 避免与 Coordinator 形成引用环（设计文档 §7.1）。
@MainActor
@Observable
final class WindowSession {

    // MARK: - 身份与依赖

    let id: WindowID

    let appViewModel: AppViewModel
    let fileTreeViewModel: FileTreeViewModel
    let documentViewModel: DocumentViewModel
    let commandPaletteViewModel: CommandPaletteViewModel

   /// 命令目标：菜单命令经 FocusedValues 路由到此（Task 7）。
   /// 由 session 持有，弱引用自身，session 释放后自动 no-op。
   let commandTarget: WindowCommandTarget

    /// 窗口级 Undo 存储（Task 10）：替代全局 UndoManagerProvider.shared。
    let undoStore = WindowUndoStore()

    /// 注入的资源身份服务，避免每次调用时新建实例。
    private let identityService: ResourceIdentityService

    weak var coordinator: WindowCoordinator?
    weak var window: NSWindow?

    /// 回归修复：测试注入的终止协调器（携带 fake 交互边界），供 handleNewFile /
    /// handleLinkedMarkdownFile 复用保存确认流程。生产环境为 nil，回退到
    /// `AppDelegate.sharedTerminationCoordinator`。
    var terminationCoordinatorForTesting: ApplicationTerminationCoordinator?

    /// 回归修复：测试注入的 Save As 面板选择闭包，避免 headless 环境调真实
    /// `OpenPanelHelper.showSavePanel`（runModal 会阻塞主线程）。生产环境为 nil，走真实窗口级 sheet。
    var savePanelChooserForTesting: ((URL?, String) async -> URL?)?

    // MARK: - 窗口级状态

    /// 显式空白标记（发现 3：消除派生 isBlank 的竞态窗口）。
    ///
    /// `nil` 表示沿用派生判定（向后兼容）；一旦 open 开始即置为 `false`，
    /// open 失败恢复为 `true`。路由读取 `isBlank` 时优先用显式标记，
    /// 避免 ViewModel 异步刷新过程中三者短暂不一致被路由误判为 blank。
    private var explicitBlankOverride: Bool?

    /// 是否为空白窗口（未打开文件/目录、无 Untitled 待保存文档）。
    var isBlank: Bool {
        if let explicit = explicitBlankOverride {
            return explicit
        }
        return documentViewModel.currentFileURL == nil
            && appViewModel.rootDirectory == nil
            && !documentViewModel.isUntitled
    }

    /// open 操作开始时调用：立即将本窗口标记为非空白，阻止路由在异步加载期间复用它。
    func markOpenStarted() {
        explicitBlankOverride = false
    }

    /// open 操作失败时调用：恢复空白标记，使该窗口仍可被后续打开复用。
    func markOpenFailed() {
        explicitBlankOverride = true
    }

    /// 清除显式标记，回到派生判定（open 成功后 ViewModel 状态已稳定）。
    func clearBlankOverride() {
        explicitBlankOverride = nil
    }

    init(
        id: WindowID,
        settings: SettingsModel = .shared,
        identityService: ResourceIdentityService = ResourceIdentityService(),
        coordinator: WindowCoordinator? = nil
    ) {
        self.id = id
        self.appViewModel = AppViewModel()
        self.fileTreeViewModel = FileTreeViewModel(settings: settings)
        self.documentViewModel = DocumentViewModel(settings: settings)
        self.commandPaletteViewModel = CommandPaletteViewModel()
        self.identityService = identityService
        self.coordinator = coordinator
        self.commandTarget = WindowCommandTarget(session: nil)

        // 连接 ViewModel 间依赖（原 ContentView.task 中的逻辑）
        self.fileTreeViewModel.documentViewModel = documentViewModel
        self.fileTreeViewModel.session = self
       self.commandPaletteViewModel.configure(
           appViewModel: appViewModel,
           fileTreeViewModel: fileTreeViewModel,
           documentViewModel: documentViewModel,
           settings: settings
       )
       self.commandPaletteViewModel.coordinator = coordinator
       self.commandPaletteViewModel.windowID = id
        self.documentViewModel.undoStore = undoStore

        // commandTarget 弱引用本 session（init 后回填，避免 self 未完成初始化）
        self.commandTarget.session = self

        // Task 9：目录树选择经本 session 路由（所有权冲突时激活 owner，不改本窗口选中项）。
        self.fileTreeViewModel.onSelectFileViaSession = { [weak self] url in
            self?.requestFileSelection(url)
        }
    }

   // MARK: - 资源打开

    /// 通过 OpenPanel 选择文件/目录并在本窗口打开（Task 8）。
    /// 使用窗口级 sheet，不再全局 runModal。
    func openFromPanel() {
        guard let window else { return }
        let language = SettingsModel.shared.languagePref.resolvedLanguage
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let url = await OpenPanelHelper.chooseResource(for: window, language: language) else { return }
            coordinator?.enqueue(OpenRequest(url: url, source: .openPanel, preferredWindowID: self.id))
        }
    }

    /// 在本会话内打开文件资源。
    ///
    /// 调用方需已通过 Coordinator 路由确认本会话是合法 owner。
    /// 所有权声明（claim）由路由成功后的调用点统一负责，不在本方法内重复 claim——
    /// 避免与路由引擎形成双保险且用 `try?` 吞掉冲突（历史 bug）。
    func openFile(_ url: URL) async {
        appViewModel.openSingleFile(url)
        fileTreeViewModel.selectedFileURL = url
        await documentViewModel.loadFile(at: url)
    }

    /// 在本会话内以目录模式打开。
    ///
    /// 同 `openFile`，所有权声明由调用点负责。
    func openDirectory(_ url: URL) async {
        appViewModel.openDirectory(url)
        await fileTreeViewModel.loadDirectory(url)
    }

    // MARK: - 目录树选择前路由

    /// Task 13：本窗口是否为 Coordinator 记录的最后活动窗口。
    /// 用于限制 lastOpenedFile/Directory 写入，防止后台窗口覆盖主窗口位置记忆。
    var isLastActiveWindow: Bool {
        coordinator?.lastActiveWindowID == id
    }

    /// Task 13：记录最后打开位置（仅最后活动窗口写入）。
    func recordLastOpened(file: URL?, directory: URL?) {
        let settings = SettingsModel.shared
        settings.recordLastOpened(file: file, directory: directory, isActive: isLastActiveWindow)
    }

    /// 用户在目录树点击文件前的路由（回归修复：目录窗口专用文件切换事务）。
    ///
    /// 目录内文件选择**不进入通用外部打开路由**（`routeFileSelection`/`enqueue`），
    /// 否则已承载根目录的非空白窗口会被路由引擎判为 `.createWindow`，错误地新建窗口。
    /// 改为按产品需求 §6.5 在当前目录窗口内执行文件切换事务：
    ///
    /// 1. 目标文件就是当前文档（同时持有所有权 + currentFileURL + selectedFileURL 三者一致）：
    ///    幂等，不重复加载。
    /// 2. 目标文件由其他窗口持有：保持当前选中项与文档不变，激活 owner 窗口。
    /// 3. 目标文件无其他 owner：
    ///    - 为当前 session 声明目标文件所有权（即使本窗口历史残留持有目标，也重新声明以自愈）；
    ///    - 释放此前在该目录窗口显示的文件所有权（保留根目录所有权）；
    ///    - 更新文件树选择并加载文档。
    ///
    /// 幂等判断必须同时验证「持有 + 当前文档 + 当前选中项」三者一致——仅「本窗口持有」不能提前返回，
    /// 否则 Cmd+N 后旧文件所有权残留会导致再次选择该文件时被误判为幂等而无反应（回归根因 2）。
    ///
    /// 脏 Untitled 时的保存确认由本方法同步驱动（复用 `resolveUnsavedChanges`），
    /// 决策完成前不修改 `selectedFileURL`，避免与视图层弹窗竞态。
    func requestFileSelection(_ url: URL) {
        guard let coordinator else {
            // 无 coordinator 时回退为直接选择（兼容旧测试/单窗口）
            fileTreeViewModel.selectedFileURL = url
            return
        }

        let resource: ResourceIdentity
        do {
            resource = try coordinator.sharedIdentityService.identity(for: url, kind: .file)
        } catch {
            // 类型不支持：不改选中项
            return
        }

        // 1. 目标就是当前文档：幂等（三者一致才算，仅持有不算）。
        let stdURL = url.standardizedFileURL
        if coordinator.isFileOwnedBySelf(url, owner: id),
           documentViewModel.currentFileURL?.standardizedFileURL == stdURL,
           fileTreeViewModel.selectedFileURL?.standardizedFileURL == stdURL {
            return
        }

        // 2. 其他窗口持有该文件：不改本窗口选中项/文档，激活 owner。
        if coordinator.isFileOwnedByAnotherWindow(url, besides: id) {
            if let ownerID = coordinator.owner(of: resource) {
                coordinator.activate(windowID: ownerID)
            }
            return
        }

        // 3. 无其他 owner：在当前目录窗口内打开（目录内导航专用路径）。
        openFileInDirectoryWindow(url: url, resource: resource)
    }

    /// 目录窗口内文件切换事务（无其他 owner 分支）。
    ///
    /// 职责划分（与原 `.openInSession` 设计一致）：session 负责所有权事务与选中项切换，
    /// **文档加载由视图层 `SelectionChangeModifier` 响应 `selectedFileURL` 变化完成**。
    /// 因此本方法不直接 `loadFile`——否则会与视图层 `onChange` 双重加载。
    ///
    /// 脏 Untitled 时先在本方法内完成保存/不保存/取消决策（复用终止协调器），
    /// 决策完成前不触碰 `selectedFileURL`；用户取消或保存失败则保持当前状态。
    /// 决策通过后才声明目标所有权、释放旧真实文件所有权、更新选中项。
    private func openFileInDirectoryWindow(url: URL, resource: ResourceIdentity) {
        guard coordinator != nil else {
            fileTreeViewModel.selectedFileURL = url
            return
        }

        // 脏 Untitled：先完成未保存决策，再进入文件切换事务。
        // 决策完成前不改 selectedFileURL，避免与视图层弹窗/加载竞态。
        if documentViewModel.isUntitled && documentViewModel.isDirty {
            let oldURL = fileTreeViewModel.selectedFileURL
            Task { @MainActor [weak self] in
                guard let self else { return }
                let termCoord = self.terminationCoordinatorForTesting ?? AppDelegate.sharedTerminationCoordinator
                let decision = await termCoord.resolveUnsavedChanges(for: self)
                guard decision == .proceed else {
                    // 取消或保存失败：保持当前 Untitled 状态不变
                    return
                }
                self.commitFileSwitchTransaction(url: url, resource: resource, oldSelectionURL: oldURL)
            }
            return
        }

        commitFileSwitchTransaction(url: url, resource: resource, oldSelectionURL: fileTreeViewModel.selectedFileURL)
    }

    /// 执行文件切换事务的统一收尾：声明目标所有权 → 释放旧真实文件所有权 → 更新选中项。
    /// 文档加载仍由视图层 `SelectionChangeModifier` 响应 `selectedFileURL` 变化完成。
    private func commitFileSwitchTransaction(url: URL, resource: ResourceIdentity, oldSelectionURL: URL?) {
        guard let coordinator else {
            fileTreeViewModel.selectedFileURL = url
            return
        }

        // 声明目标所有权（若被并发抢占则放弃，不改选中项）
        do {
            try coordinator.claim(resource, for: id)
        } catch {
            // 并发抢占：激活实际 owner，保持本窗口状态不变
            if let ownerID = coordinator.owner(of: resource) {
                coordinator.activate(windowID: ownerID)
            }
            return
        }

        // 释放此前在本目录窗口显示的文件所有权（保留根目录所有权）。
        // 同时考虑两种来源的「旧真实文件」：
        // 1. 文档模型当前指向的真实文件（currentFileURL，非 Untitled）；
        // 2. 此前目录窗口选中过的真实文件（oldSelectionURL，非 Untitled 临时文件、非目标本身）——
        //    Cmd+N 后 currentFileURL 已是 Untitled 临时文件，旧真实文件所有权需经此释放。
        // 判定「非 Untitled 临时文件」用 `isUntitled` + 路径前缀双保险：前者覆盖文档模型状态，
        // 后者覆盖 oldSelectionURL（它来自文件树，不经过 isUntitled 判定）。
        let stdURL = url.standardizedFileURL
        let untitledDir = DocumentViewModel.untitledDirectory.standardizedFileURL.path
        func isRealFile(_ candidate: URL) -> Bool {
            let std = candidate.standardizedFileURL
            if std.path == stdURL.path { return false }
            // 排除 Untitled 临时目录下的临时文件
            return !std.path.hasPrefix(untitledDir + "/")
        }
        var released = Set<String>()
        if let oldFileURL = documentViewModel.currentFileURL,
           !documentViewModel.isUntitled,
           isRealFile(oldFileURL) {
            let key = oldFileURL.standardizedFileURL.path
            if released.insert(key).inserted {
                coordinator.releaseFileOwnership(oldFileURL, for: id)
            }
        }
        if let oldSelection = oldSelectionURL, isRealFile(oldSelection) {
            let key = oldSelection.standardizedFileURL.path
            if released.insert(key).inserted {
                coordinator.releaseFileOwnership(oldSelection, for: id)
            }
        }

        // 切换选中项；文档加载由视图层 SelectionChangeModifier 响应变化完成。
        fileTreeViewModel.selectedFileURL = url
    }

    // MARK: - Markdown 内链打开（需求 §6.7，回归修复：移除全局广播）

    /// 渲染页内点击本地 Markdown 链接时由所属 WebView closure 回调本方法。
    /// 只由来源窗口处理：根目录内文件走目录内导航，外部文件首期仍在当前窗口打开，
    /// 但若目标已被其他窗口持有则激活 owner（不在当前窗口重复打开）。
    func handleLinkedMarkdownFile(_ url: URL) {
        // 已是当前文件：幂等
        if documentViewModel.currentFileURL?.standardizedFileURL == url { return }

        // 目标已被其他窗口持有：激活 owner，不在本窗口打开
        if let coordinator, coordinator.isFileOwnedByAnotherWindow(url, besides: id) {
            if let identity = try? coordinator.sharedIdentityService.identity(for: url, kind: .file),
               let ownerID = coordinator.owner(of: identity) {
                coordinator.activate(windowID: ownerID)
            }
            return
        }

        // 脏 Untitled：先询问保存/不保存/取消
        if documentViewModel.isUntitled && documentViewModel.isDirty {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let termCoord = self.terminationCoordinatorForTesting ?? AppDelegate.sharedTerminationCoordinator
                let decision = await termCoord.resolveUnsavedChanges(for: self)
                guard decision == .proceed else { return }
                self.openLinkedMarkdownFile(url)
            }
            return
        }
        openLinkedMarkdownFile(url)
    }

    /// 内链目标无所有权冲突时的实际打开（根目录内走目录内导航，否则当前窗口单文件打开）。
    private func openLinkedMarkdownFile(_ url: URL) {
        if let rootDir = appViewModel.rootDirectory,
           url.standardizedFileURL.path.hasPrefix(rootDir.standardizedFileURL.path + "/") {
            // 根目录内：复用目录内导航事务（声明所有权/释放旧文件/切换选中）
            requestFileSelection(url)
            return
        }

        // 根目录外：首期仍在当前窗口以单文件模式打开（需求 §6.7）。
        // 声明目标所有权，使其他窗口随后点击同一文件时激活本窗口而非重复打开。
        if let coordinator {
            let resource = try? coordinator.sharedIdentityService.identity(for: url, kind: .file)
            if let resource {
                do {
                    try coordinator.claim(resource, for: id)
                    // 释放此前显示的旧文件所有权（非 Untitled、非目标本身）
                    if let oldFileURL = documentViewModel.currentFileURL,
                       !documentViewModel.isUntitled,
                       oldFileURL.standardizedFileURL != url.standardizedFileURL {
                        coordinator.releaseFileOwnership(oldFileURL, for: id)
                    }
                } catch {
                    // 并发抢占：激活实际 owner，不在本窗口打开
                    if let ownerID = coordinator.owner(of: resource) {
                        coordinator.activate(windowID: ownerID)
                    }
                    return
                }
            }
        }
        appViewModel.openSingleFile(url)
        fileTreeViewModel.selectedFileURL = url
        recordLastOpened(file: url, directory: nil)
        SettingsModel.shared.addRecentItem(url: url, isDirectory: false)
        Task { @MainActor [weak self] in
            await self?.documentViewModel.loadFile(at: url)
        }
    }

    // MARK: - 关闭决策

    /// 判断关闭本窗口是否需要 Untitled 保存确认。
    func prepareForClose() -> CloseDecision {
        if documentViewModel.isUntitled && documentViewModel.isDirty {
            return .needsUntitledDecision
        }
        return .close
    }

    /// 释放本会话全部状态：所有权、文件监控、observer 等。
    /// 由 WindowLifecycleBridge.willCloseNotification 同步调用（Task 3）。
    /// 幂等：多次调用安全。`isDisposed` 守卫保证 unregister 只执行一次。
    private var isDisposed = false

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        coordinator?.unregister(windowID: id)
    }

    // MARK: - 窗口级命令（Task 7：替代无目标通知广播）

    /// 新建未保存文件（回归修复：脏 Untitled 时走完整保存/不保存/取消流程）。
    ///
    /// - 脏 Untitled：显示「保存 / 不保存 / 取消」。
    ///   - 保存成功 → 创建新 Untitled；
    ///   - 不保存 → 完整清理旧 Untitled 后创建新 Untitled；
    ///   - 取消或保存失败 → 保持当前内容和窗口不变。
    /// - 非脏状态：直接创建新 Untitled。
    func handleNewFile() {
        if documentViewModel.isUntitled && documentViewModel.isDirty {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let termCoord = self.terminationCoordinatorForTesting ?? AppDelegate.sharedTerminationCoordinator
                let decision = await termCoord.resolveUnsavedChanges(for: self)
                guard decision == .proceed else { return }
                self.createNewUntitled()
            }
            return
        }
        createNewUntitled()
    }

    /// 实际创建一个新 Untitled 文档（清理当前状态后）。
    ///
    /// 回归修复（根因 1）：Cmd+N 成功创建 Untitled 后，必须释放此前本窗口显示的真实文件所有权，
    /// 否则窗口同时持有「旧真实文件 + 新 Untitled 临时文件」，再次选择旧文件时被幂等判断误判。
    /// Untitled 临时文件不进入全局所有权注册表，故只需释放真实文件所有权，根目录所有权保留。
    private func createNewUntitled() {
        // 创建前记录当前真实文件（非 Untitled）URL，用于创建成功后释放所有权。
        let previousRealFileURL: URL? = {
            guard !documentViewModel.isUntitled else { return nil }
            return documentViewModel.currentFileURL
        }()

        guard documentViewModel.createUntitledFile() != nil else { return }

        // 创建成功后释放此前真实文件所有权（保留根目录所有权）。
        // 此前若已是 Untitled（无真实文件），previousRealFileURL 为 nil，跳过。
        if let oldURL = previousRealFileURL, let coordinator {
            coordinator.releaseFileOwnership(oldURL, for: id)
        }

        fileTreeViewModel.selectedFileURL = nil
        appViewModel.selectedFile = nil
        appViewModel.hasUnsavedUntitled = true
        appViewModel.untitledFileName = documentViewModel.fileName
    }

    /// 保存当前文件（含重入保护）。
    /// 回归修复：Untitled 文档走本窗口 Save As 流程（`DocumentViewModel.save()` 对 Untitled
    /// 返回 false，此处据此转 handleSaveAs），不再静默 no-op。
    func handleSave() {
        guard !documentViewModel.isSaving && !documentViewModel.isSavePanelShowing else { return }
        if documentViewModel.isUntitled {
            handleSaveAs()
            return
        }
        Task { @MainActor in await documentViewModel.save() }
    }

    /// 另存为：弹 NSSavePanel（窗口级 sheet），成功后迁移所有权并刷新文件树/最近记录。
    func handleSaveAs() {
        guard !documentViewModel.isSavePanelShowing else { return }
        let settings = SettingsModel.shared
        documentViewModel.isSavePanelShowing = true
        let language = settings.languagePref.resolvedLanguage
        let defaultDir = settings.lastOpenedDirectory ?? settings.lastOpenedFile?.deletingLastPathComponent()
        let suggestedName = documentViewModel.fileName.isEmpty ? "Untitled.md" : documentViewModel.fileName

        let owningWindow = window
        Task { @MainActor [weak self] in
            guard let self else { return }
            let saveURL: URL?
            if let chooser = self.savePanelChooserForTesting {
                saveURL = await chooser(defaultDir, suggestedName)
            } else {
                saveURL = await OpenPanelHelper.showSavePanel(
                    for: owningWindow,
                    language: language,
                    defaultDirectory: defaultDir,
                    suggestedName: suggestedName
                )
            }
            guard let saveURL else {
                self.documentViewModel.isSavePanelShowing = false
                return
            }
            await self.performSaveAs(to: saveURL)
        }
    }

    /// 执行 Save As 落盘与所有权迁移/刷新（由 handleSaveAs 在面板返回后调用）。
    private func performSaveAs(to saveURL: URL) async {
        let settings = SettingsModel.shared
        let oldURL = documentViewModel.currentFileURL
        let success = await documentViewModel.saveAs(to: saveURL)
        // 保存失败：保留 Untitled 内容，仅复位保存面板状态，不迁移所有权/不刷新/不加 recent
        guard success else {
            documentViewModel.isSavePanelShowing = false
            return
        }
        appViewModel.hasUnsavedUntitled = false

        // 所有权迁移：旧 URL → 新 URL（仅当旧 URL 由本窗口持有）
        if let oldURL, let coordinator = self.coordinator {
            try? coordinator.migrateOwnership(from: oldURL, to: saveURL, for: self.id)
        }

        if let rootDir = self.appViewModel.rootDirectory,
           saveURL.path.hasPrefix(rootDir.path + "/") {
            await self.fileTreeViewModel.loadDirectory(rootDir)
            self.fileTreeViewModel.selectedFileURL = saveURL
        }

        settings.recordLastOpened(file: saveURL, directory: nil, isActive: isLastActiveWindow)
        settings.addRecentItem(url: saveURL, isDirectory: false)
        self.documentViewModel.isSavePanelShowing = false
    }
}

// MARK: - CloseDecision

/// 单窗口关闭决策。
enum CloseDecision: Equatable, Sendable {
    case close
    case needsUntitledDecision
    case cancel
}

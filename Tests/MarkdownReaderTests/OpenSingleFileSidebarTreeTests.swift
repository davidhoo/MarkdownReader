import AppKit
import MarkdownReaderKit
import SwiftUI
import XCTest
@testable import MarkdownReader

/// 「打开单文档时，在侧边栏打开当前目录」功能的回归测试。
///
/// 需求：打开某个目录下的 Markdown 文件时，扫描该文件所在目录及其子目录下的
/// 所有 Markdown 文件，在左侧以目录树列出；开关位于「设置 → 通用 → 文件树」。
///
/// 覆盖四层：
/// 1. 设置项默认值与持久化；
/// 2. `AppViewModel` 的模式语义（单文件模式不得污染 `rootDirectory`）；
/// 3. `WindowSession.openFile` 的真实递归扫描、选中与既有文档不被清空；
/// 4. 挂载 `ContentView` 后 Sidebar 的真实渲染分支（AppKit 探针）。
@MainActor
final class OpenSingleFileSidebarTreeTests: TemporaryDirectoryTestCase {

    // MARK: - 测试夹具

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OpenSingleFileSidebarTreeTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        suiteName = nil
        super.tearDown()
    }

    /// 隔离的 UserDefaults 域，避免污染真实用户设置。
    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeSettings(_ defaults: UserDefaults? = nil) -> SettingsModel {
        SettingsModel(
            defaults: defaults ?? makeDefaults(),
            noteRecentDocument: { _ in },
            clearSystemRecentDocuments: {}
        )
    }

    /// 构造一个两层子目录的文档目录：
    /// `docs/a.md`、`docs/note.txt`、`docs/data.json`、`docs/.hidden.md`、
    /// `docs/sub/b.md`、`docs/sub/deep/c.md`
    ///
    /// `data.json` 与 `note.txt` 用于区分两套过滤语义：
    /// - 目录模式尊重「显示非 Markdown 文件」，`.txt` 属于「树中按 Markdown 显示」的
    ///   扩展名（`FileService.treeDisplayExtensions`），开启设置时两者都显示；
    /// - 单文档侧边栏强制 `markdownOnly`，按扩展名严格只留 Markdown，两者都不显示。
    ///
    /// - `topLevelFile` 位于 `docs/` 根，用于验证「文件所在目录 = docs」时的递归扫描；
    /// - `deepFile` 位于 `docs/sub/deep/`，用于验证侧边栏树根跟随文件所在目录。
    private struct DocumentHierarchy {
        let root: URL
        let topLevelFile: URL
        let deepFile: URL
    }

    private func makeDocumentHierarchy() throws -> DocumentHierarchy {
        let docs = try makeDirectory(named: "docs")
        let topLevelFile = try makeFile(named: "a.md", in: docs, content: "# A")
        try makeFile(named: "note.txt", in: docs, content: "plain text")
        try makeFile(named: "data.json", in: docs, content: "{}")
        try makeFile(named: ".hidden.md", in: docs, content: "# hidden")
        let sub = docs.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try makeFile(named: "b.md", in: sub, content: "# B")
        let deep = sub.appendingPathComponent("deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let deepFile = try makeFile(named: "c.md", in: deep, content: "# C")
        return DocumentHierarchy(root: docs, topLevelFile: topLevelFile, deepFile: deepFile)
    }

    private func allPaths(in nodes: [FileNode]) -> Set<String> {
        var result: Set<String> = []
        for node in nodes {
            result.insert(node.path.standardizedFileURL.path)
            if let children = node.children {
                result.formUnion(allPaths(in: children))
            }
        }
        return result
    }

    private func standardPath(_ url: URL?) -> String? {
        url?.standardizedFileURL.path
    }

    /// 创建并登记 session。
    ///
    /// `WindowSession.coordinator` 是弱引用，coordinator 必须由调用方持有，
    /// 否则会在本方法返回时释放，session 退化为「无 coordinator」回退路径。
    private func makeSession(settings: SettingsModel, coordinator: WindowCoordinator) -> WindowSession {
        let session = WindowSession(id: WindowID(), settings: settings, coordinator: coordinator)
        coordinator.register(session: session)
        return session
    }

    /// 递归查找 AppKit 视图树中的某个标识视图。
    private func findView(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        in view: NSView
    ) -> NSView? {
        if view.identifier == identifier { return view }
        for subview in view.subviews {
            if let found = findView(withIdentifier: identifier, in: subview) { return found }
        }
        return nil
    }

    private func settleLayout(_ view: NSView) {
        let deadline = Date().addingTimeInterval(0.5)
        repeat {
            view.needsLayout = true
            view.window?.contentView?.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
    }

    // MARK: - 1. 设置项

    func testSettingDefaultsToDisabledForExistingUsers() {
        let settings = makeSettings()
        XCTAssertFalse(
            settings.openContainingDirectoryForSingleFile,
            "新开关默认必须关闭，保持单文件模式原有行为"
        )
    }

    func testSettingPersistsAcrossInstances() {
        let defaults = makeDefaults()
        let first = makeSettings(defaults)
        first.openContainingDirectoryForSingleFile = true

        let second = makeSettings(defaults)
        XCTAssertTrue(second.openContainingDirectoryForSingleFile, "开关状态必须持久化到 UserDefaults")

        second.openContainingDirectoryForSingleFile = false
        let third = makeSettings(defaults)
        XCTAssertFalse(third.openContainingDirectoryForSingleFile)
    }

    func testSettingLabelIsLocalizedInAllSupportedLanguages() {
        let key = L10n.Key.settingsGeneralOpenContainingDirectoryForSingleFile
        for language in Language.allCases {
            let text = L10n.tr(key, language: language)
            XCTAssertFalse(text.isEmpty, "\(language) 缺少该设置项文案")
            XCTAssertNotEqual(text, key.rawValue, "\(language) 缺少该设置项翻译")
        }
        XCTAssertEqual(
            L10n.tr(key, language: .zhCN),
            "打开单文档时，在侧边栏打开当前目录",
            "简体中文文案必须与需求一致"
        )
    }

    // MARK: - 2. AppViewModel 模式语义

    func testOpenSingleFileWithSidebarTreeUsesContainingDirectory() throws {
        let vm = AppViewModel()
        vm.isSidebarVisible = false
        let hierarchy = try makeDocumentHierarchy()

        vm.openSingleFile(hierarchy.deepFile, openContainingDirectoryInSidebar: true)

        XCTAssertTrue(vm.isSingleFileMode, "仍必须是单文件模式")
        XCTAssertEqual(vm.singleFileURL, hierarchy.deepFile)
        XCTAssertNil(vm.rootDirectory, "单文件模式不得把 rootDirectory 当成目录模式根目录")
        XCTAssertEqual(
            standardPath(vm.sidebarRootDirectory),
            standardPath(hierarchy.root.appendingPathComponent("sub/deep")),
            "侧边栏目录树根目录必须是文件所在目录"
        )
        XCTAssertTrue(vm.isSidebarVisible, "开启该功能后侧边栏必须自动展开")
        XCTAssertTrue(vm.showsSidebarTree)
    }

    func testOpenSingleFileWithoutSidebarTreeKeepsLegacyBehavior() throws {
        let vm = AppViewModel()
        vm.isSidebarVisible = true
        let hierarchy = try makeDocumentHierarchy()

        vm.openSingleFile(hierarchy.deepFile)

        XCTAssertTrue(vm.isSingleFileMode)
        XCTAssertNil(vm.rootDirectory)
        XCTAssertNil(vm.sidebarRootDirectory, "默认（开关关闭）不得预留侧边栏目录树根目录")
        XCTAssertFalse(vm.showsSidebarTree)
        XCTAssertFalse(vm.isSidebarVisible, "开关关闭时必须保持单文件模式隐藏侧边栏的原有行为")
    }

    func testSidebarTreeDirectoryFollowsWindowMode() throws {
        let vm = AppViewModel()
        let hierarchy = try makeDocumentHierarchy()
        let otherDirectory = try makeDirectory(named: "other")

        vm.openSingleFile(hierarchy.deepFile, openContainingDirectoryInSidebar: true)
        XCTAssertEqual(
            standardPath(vm.sidebarTreeDirectory),
            standardPath(hierarchy.root.appendingPathComponent("sub/deep"))
        )

        vm.openDirectory(otherDirectory)
        XCTAssertEqual(
            standardPath(vm.sidebarTreeDirectory),
            standardPath(otherDirectory),
            "目录模式必须改用 rootDirectory 作为侧边栏树根"
        )
        XCTAssertNil(vm.sidebarRootDirectory, "切换到目录模式必须清理单文件侧边栏上下文")
    }

    func testOpenDirectoryClearsSingleFileSidebarTree() throws {
        let vm = AppViewModel()
        let hierarchy = try makeDocumentHierarchy()
        vm.openSingleFile(hierarchy.deepFile, openContainingDirectoryInSidebar: true)
        XCTAssertNotNil(vm.sidebarRootDirectory)

        let dir = try makeDirectory(named: "notes")
        vm.openDirectory(dir)

        XCTAssertNil(vm.sidebarRootDirectory)
        XCTAssertFalse(vm.isSingleFileMode)
        XCTAssertTrue(vm.isSidebarVisible)
    }

    func testWindowTitleFollowsDirectoryAfterLeavingSingleFileMode() throws {
        let vm = AppViewModel()
        let hierarchy = try makeDocumentHierarchy()

        vm.openSingleFile(hierarchy.deepFile, openContainingDirectoryInSidebar: true)
        XCTAssertTrue(
            vm.windowTitle.contains(hierarchy.deepFile.lastPathComponent),
            "单文件模式窗口标题显示文件名"
        )

        let dir = try makeDirectory(named: "notes")
        vm.openDirectory(dir)
        XCTAssertTrue(
            vm.windowTitle.contains(dir.lastPathComponent),
            "切换到目录模式后窗口标题必须更新为目录名，不能被单文件模式的标题卡住"
        )
        XCTAssertFalse(vm.windowTitle.contains(hierarchy.deepFile.lastPathComponent))
    }

    func testSidebarPresentationIdentityDistinguishesSingleFileAndDirectoryContexts() throws {
        let vm = AppViewModel()
        let hierarchy = try makeDocumentHierarchy()

        let welcomeIdentity = vm.sidebarPresentationIdentity
        vm.openSingleFile(hierarchy.deepFile, openContainingDirectoryInSidebar: true)
        let singleFileIdentity = vm.sidebarPresentationIdentity
        XCTAssertNotEqual(
            singleFileIdentity,
            welcomeIdentity,
            "进入单文件目录树必须重建 Sidebar 布局，清除欢迎页遗留的 0 宽度布局"
        )

        // 同目录下换文件：目录上下文未变，不应无谓重建
        let sibling = try makeFile(named: "sibling.md", in: hierarchy.root.appendingPathComponent("sub/deep"), content: "# S")
        vm.openSingleFile(sibling, openContainingDirectoryInSidebar: true)
        XCTAssertEqual(vm.sidebarPresentationIdentity, singleFileIdentity)

        // 目录模式必须与单文件模式使用不同的 Sidebar 上下文
        vm.openDirectory(hierarchy.root)
        XCTAssertNotEqual(vm.sidebarPresentationIdentity, singleFileIdentity)
    }

    func testSidebarPresentationIdentityChangesWhenContainingDirectoryChanges() throws {
        let vm = AppViewModel()
        let hierarchy = try makeDocumentHierarchy()

        vm.openSingleFile(hierarchy.topLevelFile, openContainingDirectoryInSidebar: true)
        let topLevelIdentity = vm.sidebarPresentationIdentity

        vm.openSingleFile(hierarchy.deepFile, openContainingDirectoryInSidebar: true)
        XCTAssertNotEqual(
            vm.sidebarPresentationIdentity,
            topLevelIdentity,
            "文件所在目录变化时必须重建 Sidebar 子树"
        )
    }

    func testApplySingleFileSidebarTreeSettingTogglesSidebarLive() throws {
        let vm = AppViewModel()
        let hierarchy = try makeDocumentHierarchy()
        vm.openSingleFile(hierarchy.deepFile)

        vm.applySingleFileSidebarTreeSetting(enabled: true)
        XCTAssertTrue(vm.isSidebarVisible, "设置改为开启后侧边栏应立即展开")
        XCTAssertEqual(
            standardPath(vm.sidebarRootDirectory),
            standardPath(hierarchy.root.appendingPathComponent("sub/deep"))
        )

        vm.applySingleFileSidebarTreeSetting(enabled: false)
        XCTAssertFalse(vm.isSidebarVisible, "设置改为关闭后侧边栏应立即收起")
        XCTAssertNil(vm.sidebarRootDirectory)
        XCTAssertTrue(vm.isSingleFileMode)
        XCTAssertEqual(vm.singleFileURL, hierarchy.deepFile)
    }

    func testApplySingleFileSidebarTreeSettingIgnoresWelcomeAndDirectoryMode() throws {
        let vm = AppViewModel()

        // 欢迎页：没有单文件，调用不得凭空造出目录上下文
        vm.applySingleFileSidebarTreeSetting(enabled: true)
        XCTAssertNil(vm.sidebarRootDirectory)
        XCTAssertNil(vm.sidebarTreeDirectory)

        // 目录模式：不得改动 rootDirectory
        let dir = try makeDirectory(named: "notes")
        vm.openDirectory(dir)
        vm.applySingleFileSidebarTreeSetting(enabled: true)

        XCTAssertEqual(vm.rootDirectory, dir, "目录模式不得被该设置改动根目录")
        XCTAssertNil(vm.sidebarRootDirectory)
        XCTAssertFalse(vm.isSingleFileMode)
        XCTAssertEqual(standardPath(vm.sidebarTreeDirectory), standardPath(dir))
    }

    // MARK: - 3. WindowSession.openFile 真实扫描

    func testSessionOpenFileScansContainingDirectoryRecursively() async throws {
        let settings = makeSettings()
        settings.openContainingDirectoryForSingleFile = true
        let coordinator = WindowCoordinator()
        let session = makeSession(settings: settings, coordinator: coordinator)
        let hierarchy = try makeDocumentHierarchy()

        await session.openFile(hierarchy.topLevelFile)

        XCTAssertTrue(session.appViewModel.isSingleFileMode)
        XCTAssertTrue(session.appViewModel.isSidebarVisible, "开启功能后打开单文档应展开侧边栏")

        let root = try XCTUnwrap(session.fileTreeViewModel.nodes.first)
        XCTAssertEqual(
            root.path.standardizedFileURL.path,
            hierarchy.root.standardizedFileURL.path,
            "侧边栏树根必须是当前文件所在目录"
        )

        let paths = allPaths(in: session.fileTreeViewModel.nodes)
        XCTAssertTrue(paths.contains(hierarchy.topLevelFile.standardizedFileURL.path))
        XCTAssertTrue(
            paths.contains(hierarchy.root.appendingPathComponent("sub/b.md").standardizedFileURL.path),
            "必须递归扫描子目录"
        )
        XCTAssertTrue(
            paths.contains(hierarchy.deepFile.standardizedFileURL.path),
            "必须递归扫描孙目录"
        )
    }

    func testSessionOpenFileTreeRootIsContainingDirectoryOfDeepFile() async throws {
        let settings = makeSettings()
        settings.openContainingDirectoryForSingleFile = true
        let coordinator = WindowCoordinator()
        let session = makeSession(settings: settings, coordinator: coordinator)
        let hierarchy = try makeDocumentHierarchy()

        await session.openFile(hierarchy.deepFile)

        let root = try XCTUnwrap(session.fileTreeViewModel.nodes.first)
        XCTAssertEqual(
            root.path.standardizedFileURL.path,
            hierarchy.root.appendingPathComponent("sub/deep").standardizedFileURL.path,
            "打开子目录中的文件时，侧边栏树根跟随文件所在目录"
        )

        let paths = allPaths(in: session.fileTreeViewModel.nodes)
        XCTAssertTrue(paths.contains(hierarchy.deepFile.standardizedFileURL.path))
        XCTAssertFalse(
            paths.contains(hierarchy.topLevelFile.standardizedFileURL.path),
            "树根之外的兄弟文档不应出现在侧边栏"
        )
    }

    func testSessionOpenFileSelectsCurrentFile() async throws {
        let settings = makeSettings()
        settings.openContainingDirectoryForSingleFile = true
        let coordinator = WindowCoordinator()
        let session = makeSession(settings: settings, coordinator: coordinator)
        let hierarchy = try makeDocumentHierarchy()

        await session.openFile(hierarchy.topLevelFile)

        XCTAssertEqual(
            standardPath(session.fileTreeViewModel.selectedFileURL),
            standardPath(hierarchy.topLevelFile),
            "当前文件必须在目录树中被选中（高亮）"
        )

        // 根目录必须展开，否则看不到第一层内容
        let expandedPaths = Set(session.fileTreeViewModel.expandedDirs.map { $0.standardizedFileURL.path })
        XCTAssertTrue(expandedPaths.contains(hierarchy.root.standardizedFileURL.path))

        // 文档本身必须已加载（侧边栏扫描不得干扰单文件模式的文档）
        XCTAssertEqual(
            standardPath(session.documentViewModel.currentFileURL),
            standardPath(hierarchy.topLevelFile)
        )
        XCTAssertTrue(session.documentViewModel.hasDocument)
    }

    func testSessionOpenFileWithoutSettingDoesNotScan() async throws {
        let settings = makeSettings()
        let coordinator = WindowCoordinator()
        let session = makeSession(settings: settings, coordinator: coordinator)
        let hierarchy = try makeDocumentHierarchy()

        await session.openFile(hierarchy.deepFile)

        XCTAssertTrue(session.appViewModel.isSingleFileMode)
        XCTAssertFalse(session.appViewModel.isSidebarVisible)
        XCTAssertNil(session.appViewModel.sidebarRootDirectory)
        XCTAssertTrue(session.fileTreeViewModel.nodes.isEmpty, "开关关闭时不得扫描目录")
        XCTAssertEqual(
            standardPath(session.documentViewModel.currentFileURL),
            standardPath(hierarchy.deepFile)
        )
    }

    func testSessionOpenFileKeepsRootDirectoryNilSoWindowStaysReusable() async throws {
        let settings = makeSettings()
        settings.openContainingDirectoryForSingleFile = true
        let coordinator = WindowCoordinator()
        let session = makeSession(settings: settings, coordinator: coordinator)
        let hierarchy = try makeDocumentHierarchy()

        XCTAssertTrue(session.isBlank, "前置：新 session 是空白窗口")

        await session.openFile(hierarchy.topLevelFile)
        session.clearBlankOverride()

        XCTAssertNil(
            session.appViewModel.rootDirectory,
            "单文件模式设置 rootDirectory 会让窗口被误判为目录模式，挂载侧边栏树后仍必须为 nil"
        )
        XCTAssertFalse(session.isBlank)
    }

    func testSessionOpenFileSidebarTreeRespectsHiddenAndNonMarkdownFilters() async throws {
        let settings = makeSettings()
        settings.openContainingDirectoryForSingleFile = true
        settings.showHiddenFiles = false
        settings.showNonMarkdownFiles = false
        let coordinator = WindowCoordinator()
        let session = makeSession(settings: settings, coordinator: coordinator)
        let hierarchy = try makeDocumentHierarchy()

        await session.openFile(hierarchy.topLevelFile)

        let paths = allPaths(in: session.fileTreeViewModel.nodes)
        XCTAssertTrue(paths.contains(hierarchy.topLevelFile.standardizedFileURL.path), "Markdown 文件必须保留")
        XCTAssertFalse(
            paths.contains(hierarchy.root.appendingPathComponent("data.json").standardizedFileURL.path),
            "关闭「显示非 Markdown 文件」后 .json 不得出现"
        )
        XCTAssertFalse(
            paths.contains(hierarchy.root.appendingPathComponent(".hidden.md").standardizedFileURL.path),
            "关闭「显示隐藏文件」后隐藏文件不得出现"
        )
    }

    func testSessionOpenFileSidebarTreeShowsOnlyMarkdownFiles() async throws {
        let settings = makeSettings()
        settings.openContainingDirectoryForSingleFile = true
        // 即使「显示非 Markdown 文件」保持默认开启，单文档侧边栏也只列 Markdown
        XCTAssertTrue(settings.showNonMarkdownFiles, "前置：该设置默认开启")
        let coordinator = WindowCoordinator()
        let session = makeSession(settings: settings, coordinator: coordinator)
        let hierarchy = try makeDocumentHierarchy()

        await session.openFile(hierarchy.topLevelFile)

        let paths = allPaths(in: session.fileTreeViewModel.nodes)
        XCTAssertTrue(paths.contains(hierarchy.topLevelFile.standardizedFileURL.path))
        XCTAssertTrue(
            paths.contains(hierarchy.root.appendingPathComponent("sub/b.md").standardizedFileURL.path),
            "子目录中的 Markdown 文件必须保留"
        )
        XCTAssertTrue(paths.contains(hierarchy.deepFile.standardizedFileURL.path))
        XCTAssertFalse(
            paths.contains(hierarchy.root.appendingPathComponent("data.json").standardizedFileURL.path),
            "单文档侧边栏必须过滤掉非 Markdown 文件"
        )
        XCTAssertFalse(
            paths.contains(hierarchy.root.appendingPathComponent("note.txt").standardizedFileURL.path),
            "单文档侧边栏按扩展名严格过滤，.txt 也不得出现"
        )
    }

    func testDirectoryModeStillHonorsShowNonMarkdownFilesSetting() async throws {
        let settings = makeSettings()
        let coordinator = WindowCoordinator()
        let session = makeSession(settings: settings, coordinator: coordinator)
        let hierarchy = try makeDocumentHierarchy()
        let nonMarkdownPath = hierarchy.root.appendingPathComponent("data.json").standardizedFileURL.path
        let textPath = hierarchy.root.appendingPathComponent("note.txt").standardizedFileURL.path

        // 目录模式 + 设置开启：非 Markdown 文件与潜在 Markdown 的 .txt 都照旧显示
        settings.showNonMarkdownFiles = true
        await session.openDirectory(hierarchy.root)
        XCTAssertTrue(
            allPaths(in: session.fileTreeViewModel.nodes).contains(nonMarkdownPath),
            "目录模式必须继续尊重「显示非 Markdown 文件」设置（开启时显示）"
        )
        XCTAssertTrue(
            allPaths(in: session.fileTreeViewModel.nodes).contains(textPath),
            "目录模式开启该设置时，作为潜在 Markdown 的 .txt 也必须显示"
        )

        // 目录模式 + 设置关闭：过滤掉
        settings.showNonMarkdownFiles = false
        await session.sidebarTreeDirectoryDidChange(to: session.appViewModel.sidebarTreeDirectory)
        XCTAssertFalse(
            allPaths(in: session.fileTreeViewModel.nodes).contains(nonMarkdownPath),
            "目录模式关闭该设置时必须过滤非 Markdown 文件"
        )
    }

    func testSwitchingFromDirectoryModeToSingleFileDropsNonMarkdownFiles() async throws {
        let settings = makeSettings()
        settings.openContainingDirectoryForSingleFile = true
        settings.showNonMarkdownFiles = true
        let coordinator = WindowCoordinator()
        let session = makeSession(settings: settings, coordinator: coordinator)
        let hierarchy = try makeDocumentHierarchy()
        let nonMarkdownPath = hierarchy.root.appendingPathComponent("data.json").standardizedFileURL.path

        await session.openDirectory(hierarchy.root)
        XCTAssertTrue(allPaths(in: session.fileTreeViewModel.nodes).contains(nonMarkdownPath))

        // 同一窗口改以单文件模式打开该目录下的文件：侧边栏上下文不变，但过滤规则变严
        await session.openFile(hierarchy.topLevelFile)
        XCTAssertTrue(session.appViewModel.isSingleFileMode)
        XCTAssertFalse(
            allPaths(in: session.fileTreeViewModel.nodes).contains(nonMarkdownPath),
            "从目录模式切到单文档侧边栏后，非 Markdown 文件必须立即消失"
        )
        XCTAssertTrue(
            allPaths(in: session.fileTreeViewModel.nodes).contains(hierarchy.topLevelFile.standardizedFileURL.path)
        )
    }

    // MARK: - 3b. 侧边栏树内导航与另存为后的窗口标题

    func testTreeNavigationInsideSidebarUpdatesWindowTitle() async throws {
        let settings = makeSettings()
        settings.openContainingDirectoryForSingleFile = true
        let coordinator = WindowCoordinator()
        let session = makeSession(settings: settings, coordinator: coordinator)
        let hierarchy = try makeDocumentHierarchy()

        await session.openFile(hierarchy.topLevelFile)
        XCTAssertTrue(session.appViewModel.windowTitle.contains("a.md"))

        // 在侧边栏目录树中点开子目录中的文件
        session.requestFileSelection(hierarchy.deepFile)

        XCTAssertEqual(
            standardPath(session.appViewModel.singleFileURL),
            standardPath(hierarchy.deepFile),
            "单文件模式下切换文件必须同步 singleFileURL"
        )
        XCTAssertTrue(
            session.appViewModel.windowTitle.contains("c.md"),
            "树内导航后窗口标题必须跟随当前文件，不能停在旧文件名"
        )
        XCTAssertEqual(
            standardPath(session.appViewModel.sidebarRootDirectory),
            standardPath(hierarchy.root),
            "树内导航不得改变侧边栏目录树根"
        )
        XCTAssertEqual(
            standardPath(session.fileTreeViewModel.selectedFileURL),
            standardPath(hierarchy.deepFile)
        )
    }

    func testSaveAsInsideSidebarTreeUpdatesWindowTitleAndSelection() async throws {
        let settings = makeSettings()
        settings.openContainingDirectoryForSingleFile = true
        let coordinator = WindowCoordinator()
        let session = makeSession(settings: settings, coordinator: coordinator)
        let hierarchy = try makeDocumentHierarchy()

        await session.openFile(hierarchy.topLevelFile)
        session.handleNewFile()
        session.documentViewModel.content = "# saved"
        let target = hierarchy.root.appendingPathComponent("saved.md")
        session.savePanelChooserForTesting = { _, _ in target }

        session.handleSaveAs()
        // 等待 Save As 的异步落盘、所有权迁移与目录树刷新完成
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "另存为必须落盘")
        XCTAssertTrue(
            session.appViewModel.windowTitle.contains("saved.md"),
            "另存为后窗口标题必须跟随新文件"
        )
        XCTAssertEqual(
            standardPath(session.appViewModel.singleFileURL),
            standardPath(target),
            "另存为后单文件上下文必须指向新路径"
        )
        XCTAssertEqual(
            standardPath(session.fileTreeViewModel.selectedFileURL),
            standardPath(target),
            "另存为到侧边栏目录范围内必须刷新目录树并选中新文件"
        )
    }

    // MARK: - 4. 侧边栏树加载不得影响当前文档（回归）

    func testSidebarTreeReloadDoesNotClearLoadedDocumentOrSelection() async throws {
        let settings = makeSettings()
        settings.openContainingDirectoryForSingleFile = true
        let coordinator = WindowCoordinator()
        let session = makeSession(settings: settings, coordinator: coordinator)
        let hierarchy = try makeDocumentHierarchy()

        await session.openFile(hierarchy.topLevelFile)
        XCTAssertTrue(session.documentViewModel.hasDocument, "前置：文档已加载")

        // 视图层 DirectoryChangeModifier 驱动的入口（会话侧与视图侧共用同一实现）
        await session.sidebarTreeDirectoryDidChange(to: session.appViewModel.sidebarRootDirectory)

        XCTAssertEqual(
            standardPath(session.documentViewModel.currentFileURL),
            standardPath(hierarchy.topLevelFile),
            "单文件目录树加载不得清空当前文档"
        )
        XCTAssertTrue(session.documentViewModel.hasDocument)
        XCTAssertEqual(
            standardPath(session.fileTreeViewModel.selectedFileURL),
            standardPath(hierarchy.topLevelFile),
            "单文件目录树加载不得清空选中项"
        )
        XCTAssertFalse(session.fileTreeViewModel.nodes.isEmpty)
    }

    func testSidebarTreeContextClearedDoesNotClearSingleFileDocument() async throws {
        let settings = makeSettings()
        settings.openContainingDirectoryForSingleFile = true
        let coordinator = WindowCoordinator()
        let session = makeSession(settings: settings, coordinator: coordinator)
        let hierarchy = try makeDocumentHierarchy()

        await session.openFile(hierarchy.topLevelFile)
        // 关闭该功能：侧边栏目录上下文消失
        session.appViewModel.applySingleFileSidebarTreeSetting(enabled: false)
        await session.sidebarTreeDirectoryDidChange(to: session.appViewModel.sidebarTreeDirectory)

        XCTAssertTrue(session.fileTreeViewModel.nodes.isEmpty, "目录上下文消失后必须清空目录树")
        XCTAssertTrue(session.documentViewModel.hasDocument, "关闭该功能不得关掉当前文档")
        XCTAssertEqual(
            standardPath(session.documentViewModel.currentFileURL),
            standardPath(hierarchy.topLevelFile)
        )
    }

    func testDirectoryModeRootChangeStillClearsDocumentAndSelection() async throws {
        let settings = makeSettings()
        let coordinator = WindowCoordinator()
        let session = makeSession(settings: settings, coordinator: coordinator)

        let first = try makeDirectory(named: "first")
        let firstFile = try makeFile(named: "one.md", in: first, content: "# 1")
        let second = try makeDirectory(named: "second")
        try makeFile(named: "two.md", in: second, content: "# 2")

        await session.openDirectory(first)
        session.fileTreeViewModel.selectedFileURL = firstFile
        await session.documentViewModel.loadFile(at: firstFile)
        XCTAssertTrue(session.documentViewModel.hasDocument)

        session.appViewModel.openDirectory(second)
        await session.sidebarTreeDirectoryDidChange(to: session.appViewModel.sidebarTreeDirectory)

        XCTAssertNil(session.fileTreeViewModel.selectedFileURL, "目录模式换根目录必须清空旧选中项")
        XCTAssertFalse(session.documentViewModel.hasDocument, "目录模式换根目录必须清空旧文档")
        XCTAssertEqual(
            session.fileTreeViewModel.nodes.first?.path.standardizedFileURL.path,
            second.standardizedFileURL.path
        )
    }

    // MARK: - 5. ContentView 挂载后的 Sidebar 真实渲染分支

    func testSidebarSwitchesToDirectoryTreeWhenSettingEnabled() throws {
        let settings = makeSettings()
        let coordinator = WindowCoordinator()
        let session = makeSession(settings: settings, coordinator: coordinator)

        let hostingView = NSHostingView(rootView: ContentView(session: session))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        window.contentView = hostingView
        hostingView.frame = window.contentView?.bounds ?? .zero
        window.orderFrontRegardless()
        window.makeKey()
        settleLayout(hostingView)

        func currentSidebarMode() throws -> String {
            let probe = try XCTUnwrap(
                findView(withIdentifier: SidebarContentProbe.viewIdentifier, in: hostingView)
                    as? SidebarContentProbeView,
                "Sidebar 内容探针必须存在"
            )
            return probe.mode
        }

        let hierarchy = try makeDocumentHierarchy()

        // 前置：开关关闭的单文件模式渲染单文件条目
        session.appViewModel.openSingleFile(hierarchy.topLevelFile)
        settleLayout(hostingView)
        XCTAssertEqual(try currentSidebarMode(), SidebarView.ContentMode.singleFile.rawValue)

        // 开启开关：Sidebar 必须切到目录树，且目录树由视图层 onChange 自动加载
        session.appViewModel.openSingleFile(
            hierarchy.topLevelFile,
            openContainingDirectoryInSidebar: true
        )
        settleLayout(hostingView)
        XCTAssertEqual(
            try currentSidebarMode(),
            SidebarView.ContentMode.directoryTree.rawValue,
            "开启「打开单文档时，在侧边栏打开当前目录」后侧边栏必须渲染目录树"
        )
        XCTAssertFalse(
            session.fileTreeViewModel.nodes.isEmpty,
            "视图层的目录上下文变化必须触发目录树加载"
        )

        // 目录模式仍走目录树分支
        let directory = try makeDirectory(named: "notes")
        try makeFile(named: "n.md", in: directory, content: "# N")
        session.appViewModel.openDirectory(directory)
        settleLayout(hostingView)
        XCTAssertEqual(try currentSidebarMode(), SidebarView.ContentMode.directoryTree.rawValue)
    }

    func testSidebarSwitchesBackToSingleFileEntryWhenSettingDisabled() throws {
        let settings = makeSettings()
        let coordinator = WindowCoordinator()
        let session = makeSession(settings: settings, coordinator: coordinator)

        let hostingView = NSHostingView(rootView: ContentView(session: session))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        window.contentView = hostingView
        hostingView.frame = window.contentView?.bounds ?? .zero
        window.orderFrontRegardless()
        window.makeKey()
        settleLayout(hostingView)

        let hierarchy = try makeDocumentHierarchy()
        session.appViewModel.openSingleFile(
            hierarchy.topLevelFile,
            openContainingDirectoryInSidebar: true
        )
        settleLayout(hostingView)

        session.appViewModel.applySingleFileSidebarTreeSetting(enabled: false)
        settleLayout(hostingView)

        let probe = try XCTUnwrap(
            findView(withIdentifier: SidebarContentProbe.viewIdentifier, in: hostingView)
                as? SidebarContentProbeView
        )
        XCTAssertEqual(
            probe.mode,
            SidebarView.ContentMode.singleFile.rawValue,
            "关闭开关后侧边栏必须回到单文件条目，不能残留目录树"
        )
    }
}

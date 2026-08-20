import XCTest
@testable import MarkdownReader

/// 特征测试：CommandPaletteViewModel 单根搜索现状行为。
///
/// 工作区多根改造前锁定：根内模糊搜索、空查询返回空、根外绝对路径匹配。
@MainActor
final class CommandPaletteViewModelTests: TemporaryDirectoryTestCase {

    /// 测试环境固定：扫描结果带 /private 前缀，归一化输入路径保证同源可比。
    private func normalized(_ url: URL) -> URL {
        url.path.hasPrefix("/var/") ? URL(fileURLWithPath: "/private" + url.path) : url
    }

    private func makeConfiguredPalette() async throws -> (CommandPaletteViewModel, FileTreeViewModel, AppViewModel, URL) {
        let dir = normalized(try makeDirectory(named: "project"))
        try makeFile(named: "README.md", in: dir)
        try makeFile(named: "guide.md", in: dir)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("docs"), withIntermediateDirectories: true)
        let sub = dir.appendingPathComponent("docs")
        try makeFile(named: "design.md", in: sub)

        let appViewModel = AppViewModel()
        let fileTreeViewModel = FileTreeViewModel(settings: SettingsModel.shared)
        let documentViewModel = DocumentViewModel(settings: SettingsModel.shared)

        let palette = CommandPaletteViewModel()
        palette.configure(
            appViewModel: appViewModel,
            fileTreeViewModel: fileTreeViewModel,
            documentViewModel: documentViewModel,
            settings: SettingsModel.shared
        )

        appViewModel.openDirectory(dir)
        await fileTreeViewModel.loadDirectory(dir)

        return (palette, fileTreeViewModel, appViewModel, dir)
    }

    func testSearchMatchesFilesWithinRoot() async throws {
        let (palette, _, _, _) = try await makeConfiguredPalette()

        palette.show()
        palette.searchText = "read"
        palette.handleSearchTextChanged()

        XCTAssertFalse(palette.filteredItems.isEmpty)
        XCTAssertEqual(palette.filteredItems.first?.fileName, "README.md")
    }

    func testEmptyQueryReturnsNoItems() async throws {
        let (palette, _, _, _) = try await makeConfiguredPalette()

        palette.show()

        XCTAssertTrue(palette.filteredItems.isEmpty, "空查询不应返回结果")
        XCTAssertTrue(palette.isVisible)
    }

    func testHideResetsSearchText() async throws {
        let (palette, _, _, _) = try await makeConfiguredPalette()

        palette.show()
        palette.searchText = "guide"
        palette.hide()

        XCTAssertEqual(palette.searchText, "")
        XCTAssertFalse(palette.isVisible)
    }

    func testSearchWithoutRootFallsBackToAbsolutePath() async throws {
        let file = normalized(try makeFile(named: "standalone.md"))
        let palette = CommandPaletteViewModel()
        palette.configure(
            appViewModel: AppViewModel(),
            fileTreeViewModel: FileTreeViewModel(settings: SettingsModel.shared),
            documentViewModel: DocumentViewModel(settings: SettingsModel.shared),
            settings: SettingsModel.shared
        )

        palette.show()
        palette.searchText = file.path
        palette.handleSearchTextChanged()

        XCTAssertEqual(palette.filteredItems.count, 1)
        XCTAssertEqual(palette.filteredItems.first?.url, file)
    }

    func testCacheInvalidatedOnShow() async throws {
        let (palette, fileTree, _, dir) = try await makeConfiguredPalette()

        palette.show()
        palette.searchText = "fresh"
        palette.handleSearchTextChanged()
        XCTAssertTrue(palette.filteredItems.isEmpty)

        // 新增文件后重新打开面板应能搜到（缓存随 show 失效）
        try makeFile(named: "fresh-notes.md", in: dir)
        await fileTree.refreshDirectory()
        palette.show()
        palette.searchText = "fresh"
        palette.handleSearchTextChanged()

        XCTAssertFalse(palette.filteredItems.isEmpty, "重新 show 后缓存应失效并反映新文件")
    }

    // MARK: - 工作区多根：跨根搜索

    /// 构造双根工作区面板：两个根各含同名文件，验证跨根搜索与根名前缀区分。
    private func makeMultiRootPalette() async throws -> (CommandPaletteViewModel, URL, URL) {
        let dirA = normalized(try makeDirectory(named: "proj-alpha"))
        let dirB = normalized(try makeDirectory(named: "proj-beta"))
        try makeFile(named: "notes.md", in: dirA)
        try makeFile(named: "notes.md", in: dirB)
        try makeFile(named: "alpha-only.md", in: dirA)

        let appViewModel = AppViewModel()
        let fileTreeViewModel = FileTreeViewModel(settings: SettingsModel.shared)
        let palette = CommandPaletteViewModel()
        palette.configure(
            appViewModel: appViewModel,
            fileTreeViewModel: fileTreeViewModel,
            documentViewModel: DocumentViewModel(settings: SettingsModel.shared),
            settings: SettingsModel.shared
        )

        appViewModel.openWorkspace(folders: [dirA, dirB], fileURL: nil)
        await fileTreeViewModel.loadWorkspace(folders: [dirA, dirB])

        return (palette, dirA, dirB)
    }

    func testMultiRootSearchFindsFilesAcrossRoots() async throws {
        let (palette, dirA, dirB) = try await makeMultiRootPalette()

        palette.show()
        palette.searchText = "notes"
        palette.handleSearchTextChanged()

        // 两个根下的同名文件都应命中，且是两个不同条目
        XCTAssertEqual(palette.filteredItems.count, 2, "跨根搜索应返回两个根下的同名文件")
        let paths = Set(palette.filteredItems.map(\.url.path))
        XCTAssertEqual(paths, [
            dirA.appendingPathComponent("notes.md").path,
            dirB.appendingPathComponent("notes.md").path,
        ])
    }

    func testMultiRootResultsCarryRootNamePrefix() async throws {
        let (palette, _, _) = try await makeMultiRootPalette()

        palette.show()
        palette.searchText = "notes"
        palette.handleSearchTextChanged()

        let relativePaths = Set(palette.filteredItems.map(\.relativePath))
        XCTAssertTrue(relativePaths.contains("proj-alpha/notes.md"), "多根结果应带根名前缀区分")
        XCTAssertTrue(relativePaths.contains("proj-beta/notes.md"))
    }

    func testSingleRootResultsHaveNoRootNamePrefix() async throws {
        let (palette, _, _, _) = try await makeConfiguredPalette()

        palette.show()
        palette.searchText = "read"
        palette.handleSearchTextChanged()

        XCTAssertEqual(palette.filteredItems.first?.relativePath, "README.md",
                       "单根模式相对路径不带根名前缀")
    }
}

import XCTest
@testable import MarkdownReader

/// 特征测试：FileTreeViewModel 单根目录现状行为。
///
/// 工作区多根改造前锁定现有行为，防止静默 regression。
/// 覆盖：loadDirectory 树结构与默认展开、refreshDirectory 状态保留与清理、
/// createNewFile 默认落点、isEmptyDirectory 判定、moveSelection 键盘导航。
///
/// 注意：临时目录路径可能带 /private 前缀差异，测试一律从加载后的节点树取 URL，
/// 保证与 VM 内部数据同源可比。
@MainActor
final class FileTreeViewModelBaseTests: TemporaryDirectoryTestCase {

    private func makeViewModel() -> FileTreeViewModel {
        FileTreeViewModel(settings: SettingsModel.shared)
    }

    /// 测试环境固定行为：contentsOfDirectory 返回 /private/var 前缀，而临时目录 URL
    /// 带 /var 前缀且 resolvingSymlinksInPath 不归一化。统一把输入路径归一到 /private，
    /// 保证与扫描结果同源可比（前缀匹配类逻辑不受干扰）。
    private func normalized(_ url: URL) -> URL {
        url.path.hasPrefix("/var/") ? URL(fileURLWithPath: "/private" + url.path) : url
    }

    /// 在节点树中按名称查找一级子节点。
    private func child(of vm: FileTreeViewModel, named name: String) -> FileNode? {
        vm.nodes.first?.children?.first { $0.name == name }
    }

    // MARK: - loadDirectory

    func testLoadDirectoryBuildsSingleNodeRootTreeAndExpandsRoot() async throws {
        let dir = normalized(try makeDirectory(named: "docs"))
        try makeFile(named: "A.md", in: dir)
        _ = try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)

        let vm = makeViewModel()
        await vm.loadDirectory(dir)

        XCTAssertEqual(vm.nodes.count, 1, "单根模式只应有一个根节点")
        let root = try XCTUnwrap(vm.nodes.first)
        XCTAssertEqual(root.path.lastPathComponent, "docs")
        XCTAssertTrue(root.isDirectory)
        XCTAssertEqual(root.name, "docs")
        XCTAssertEqual(root.children?.count, 2, "根节点应包含一级子项")
        XCTAssertTrue(vm.isExpanded(root.path), "加载后默认展开根目录")
        XCTAssertEqual(vm.rootDirectory, root.path)
        XCTAssertFalse(vm.isEmptyDirectory)
    }

    func testLoadDirectoryMarksEmptyWhenNoMarkdown() async throws {
        let dir = normalized(try makeDirectory(named: "empty"))

        let vm = makeViewModel()
        await vm.loadDirectory(dir)

        XCTAssertTrue(vm.isEmptyDirectory)
    }

    func testLoadDirectoryLoadsSubdirectoryChildrenRecursively() async throws {
        let dir = normalized(try makeDirectory(named: "docs"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let sub = dir.appendingPathComponent("sub")
        try makeFile(named: "deep.md", in: sub)

        let vm = makeViewModel()
        await vm.loadDirectory(dir)

        let subNode = try XCTUnwrap(child(of: vm, named: "sub"))
        XCTAssertEqual(subNode.children?.map(\.name), ["deep.md"], "扫描是递归的，子目录 children 已加载")
        XCTAssertTrue(subNode.isChildrenLoaded)
    }

    // MARK: - refreshDirectory

    func testRefreshKeepsExpandedAndSelectedState() async throws {
        let dir = normalized(try makeDirectory(named: "docs"))
        try makeFile(named: "A.md", in: dir)

        let vm = makeViewModel()
        await vm.loadDirectory(dir)
        let rootPath = try XCTUnwrap(vm.rootDirectory)
        let a = try XCTUnwrap(child(of: vm, named: "A.md"))
        vm.selectedFileURL = a.path

        // 外部新增文件后刷新
        try makeFile(named: "B.md", in: dir)
        await vm.refreshDirectory()

        XCTAssertTrue(vm.isExpanded(rootPath), "刷新后展开状态应保留")
        XCTAssertEqual(vm.selectedFileURL?.lastPathComponent, "A.md", "刷新后选中状态应保留")
        XCTAssertEqual(vm.nodes.first?.children?.count, 2, "刷新应反映新增文件")
    }

    func testRefreshClearsSelectionWhenSelectedFileDeleted() async throws {
        let dir = normalized(try makeDirectory(named: "docs"))
        try makeFile(named: "A.md", in: dir)
        try makeFile(named: "B.md", in: dir)

        let vm = makeViewModel()
        await vm.loadDirectory(dir)
        let a = try XCTUnwrap(child(of: vm, named: "A.md"))
        vm.selectedFileURL = a.path

        try FileManager.default.removeItem(at: a.path)
        await vm.refreshDirectory()

        XCTAssertNil(vm.selectedFileURL, "选中文件被删除后应清除选中")
        XCTAssertEqual(vm.nodes.first?.children?.count, 1)
    }

    func testRefreshPrunesExpandedDirsThatNoLongerExist() async throws {
        let dir = normalized(try makeDirectory(named: "docs"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)

        let vm = makeViewModel()
        await vm.loadDirectory(dir)
        let rootPath = try XCTUnwrap(vm.rootDirectory)
        let subNode = try XCTUnwrap(child(of: vm, named: "sub"))
        vm.expandedDirs.insert(subNode.path)

        try FileManager.default.removeItem(at: subNode.path)
        await vm.refreshDirectory()

        XCTAssertFalse(vm.expandedDirs.contains(subNode.path), "已删除目录的展开状态应被清理")
        XCTAssertTrue(vm.isExpanded(rootPath), "根目录展开状态不受影响")
    }

    // MARK: - createNewFile

    func testCreateNewFileFallsBackToRootDirectory() async throws {
        let dir = normalized(try makeDirectory(named: "docs"))

        let vm = makeViewModel()
        await vm.loadDirectory(dir)

        let url = vm.createNewFile(in: nil)
        let created = try XCTUnwrap(url)
        XCTAssertEqual(
            created.deletingLastPathComponent().path,
            vm.rootDirectory?.path,
            "未指定目录时应落在根目录"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        XCTAssertEqual(created.pathExtension, "md")
    }

    func testCreateNewFileAvoidsNameCollision() async throws {
        let dir = normalized(try makeDirectory(named: "docs"))
        try makeFile(named: "Untitled.md", in: dir)

        let vm = makeViewModel()
        await vm.loadDirectory(dir)

        let url = try XCTUnwrap(vm.createNewFile(in: nil))
        XCTAssertEqual(url.lastPathComponent, "Untitled 1.md")
    }

    // MARK: - 键盘导航

    func testMoveSelectionWalksVisibleNodes() async throws {
        let dir = normalized(try makeDirectory(named: "docs"))
        try makeFile(named: "A.md", in: dir)
        try makeFile(named: "B.md", in: dir)

        let vm = makeViewModel()
        await vm.loadDirectory(dir)

        // 扁平可见序列：[root, A.md, B.md]（目录在前、按名称排序）
        let flat = vm.flattenedVisibleNodes()
        XCTAssertEqual(flat.map(\.name), ["docs", "A.md", "B.md"])
        let a = flat[1]
        let b = flat[2]

        vm.selectedFileURL = a.path
        let moved = vm.moveSelection(direction: 1)
        XCTAssertEqual(moved?.path, b.path, "下移应选中下一个可见文件")
        XCTAssertEqual(vm.selectedFileURL, b.path)

        let movedBack = vm.moveSelection(direction: -1)
        XCTAssertEqual(movedBack?.path, a.path)
    }

    // MARK: - toggleExpand / clearDirectory

    func testToggleExpandAndClearDirectory() async throws {
        let dir = normalized(try makeDirectory(named: "docs"))
        try makeFile(named: "A.md", in: dir)

        let vm = makeViewModel()
        await vm.loadDirectory(dir)
        let rootPath = try XCTUnwrap(vm.rootDirectory)

        vm.toggleExpand(rootPath)
        XCTAssertFalse(vm.isExpanded(rootPath))
        vm.toggleExpand(rootPath)
        XCTAssertTrue(vm.isExpanded(rootPath))

        vm.clearDirectory()
        XCTAssertTrue(vm.nodes.isEmpty)
        XCTAssertTrue(vm.expandedDirs.isEmpty)
        XCTAssertNil(vm.selectedFileURL)
        XCTAssertNil(vm.rootDirectory)
    }
}

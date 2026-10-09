import XCTest
@testable import MarkdownReader

/// FileTreeViewModel 多根工作区测试（方案 3.3）。
///
/// 覆盖：多根加载与顺序、addFolder 重复/嵌套校验、removeFolder 状态清理、
/// workspaceIsDirty 生命周期、跨根刷新、恢复展开/选中。
@MainActor
final class FileTreeViewModelWorkspaceTests: TemporaryDirectoryTestCase {

    /// 测试环境固定：contentsOfDirectory 返回 /private/var 前缀，归一化输入路径保证同源可比。
    private func normalized(_ url: URL) -> URL {
        url.path.hasPrefix("/var/") ? URL(fileURLWithPath: "/private" + url.path) : url
    }

    private func makeViewModel() -> FileTreeViewModel {
        FileTreeViewModel(settings: SettingsModel.shared)
    }

    // MARK: - 多根加载

    func testLoadWorkspaceBuildsMultipleRootsInOrder() async throws {
        let dirA = normalized(try makeDirectory(named: "alpha"))
        let dirB = normalized(try makeDirectory(named: "beta"))
        try makeFile(named: "A.md", in: dirA)
        try makeFile(named: "B.md", in: dirB)

        let vm = makeViewModel()
        await vm.loadWorkspace(folders: [dirA, dirB])

        XCTAssertEqual(vm.nodes.count, 2)
        XCTAssertEqual(vm.nodes.map(\.path), [dirA, dirB], "根顺序必须与 folders 一致")
        XCTAssertEqual(vm.rootDirectories, [dirA, dirB])
        XCTAssertTrue(vm.isExpanded(dirA), "默认展开所有根")
        XCTAssertTrue(vm.isExpanded(dirB))
        XCTAssertFalse(vm.workspaceIsDirty, "全新加载不应置脏")
    }

    func testLoadWorkspaceRestoresExpandedAndSelection() async throws {
        let dirA = normalized(try makeDirectory(named: "alpha"))
        let sub = dirA.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = normalized(try makeFile(named: "doc.md", in: sub))
        let dirB = normalized(try makeDirectory(named: "beta"))

        let vm = makeViewModel()
        await vm.loadWorkspace(
            folders: [dirA, dirB],
            restoredExpandedDirs: [sub],
            restoredSelection: file
        )

        XCTAssertFalse(vm.isExpanded(dirA), "恢复模式不强制展开根")
        // 选中项应映射到树内节点 URL（路径相同即可，不要求 URL 表示一致）
        XCTAssertEqual(vm.selectedFileURL?.path, file.path, "恢复的选中文件应生效")
        // 展开状态以树内节点 URL 为准（外部构造 URL 与扫描 URL 内部表示可能不同）
        let subNode = try XCTUnwrap(
            vm.nodes.first { $0.path.path == dirA.path }?.children?.first { $0.path.path == sub.path }
        )
        XCTAssertTrue(vm.isExpanded(subNode.path), "树内 sub 节点应处于展开状态")
    }

    func testLoadWorkspaceSkipsMissingFolders() async throws {
        let dirA = normalized(try makeDirectory(named: "alpha"))
        let missing = normalized(temporaryDirectory.appendingPathComponent("ghost"))

        let vm = makeViewModel()
        await vm.loadWorkspace(folders: [missing, dirA])

        XCTAssertEqual(vm.nodes.map(\.path), [dirA], "缺失目录应被跳过")
        XCTAssertNil(vm.errorMessage, "部分缺失不应整体报错")
    }

    // MARK: - addFolder

    func testAddFolderAppendsRootAndMarksDirty() async throws {
        let dirA = normalized(try makeDirectory(named: "alpha"))
        let dirB = normalized(try makeDirectory(named: "beta"))

        let vm = makeViewModel()
        await vm.loadWorkspace(folders: [dirA])
        try await vm.addFolder(dirB)

        XCTAssertEqual(vm.rootDirectories, [dirA, dirB])
        XCTAssertTrue(vm.isExpanded(dirB), "新增根应默认展开")
        XCTAssertTrue(vm.workspaceIsDirty)
    }

    func testAddFolderRejectsDuplicate() async throws {
        let dirA = normalized(try makeDirectory(named: "alpha"))

        let vm = makeViewModel()
        await vm.loadWorkspace(folders: [dirA])

        do {
            try await vm.addFolder(dirA)
            XCTFail("重复目录应被拒绝")
        } catch let error as FileTreeViewModel.AddFolderError {
            XCTAssertEqual(error, .alreadyInWorkspace)
        }
        XCTAssertFalse(vm.workspaceIsDirty, "拒绝添加不得置脏")
        XCTAssertEqual(vm.nodes.count, 1)
    }

    func testAddFolderRejectsNestedConflict() async throws {
        let parent = normalized(try makeDirectory(named: "parent"))
        let child = parent.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let vm = makeViewModel()
        await vm.loadWorkspace(folders: [parent])

        do {
            try await vm.addFolder(child)
            XCTFail("已有根的子目录应被拒绝")
        } catch let error as FileTreeViewModel.AddFolderError {
            XCTAssertEqual(error, .nestedConflict)
        }

        // 反向：已有根是新目录的子目录
        let vm2 = makeViewModel()
        await vm2.loadWorkspace(folders: [child])
        do {
            try await vm2.addFolder(parent)
            XCTFail("包含已有根的父目录应被拒绝")
        } catch let error as FileTreeViewModel.AddFolderError {
            XCTAssertEqual(error, .nestedConflict)
        }
    }

    // MARK: - removeFolder

    func testRemoveFolderClearsStateUnderItAndMarksDirty() async throws {
        let dirA = normalized(try makeDirectory(named: "alpha"))
        let dirB = normalized(try makeDirectory(named: "beta"))
        let fileA = normalized(try makeFile(named: "A.md", in: dirA))
        try makeFile(named: "B.md", in: dirB)

        let vm = makeViewModel()
        await vm.loadWorkspace(folders: [dirA, dirB])
        vm.selectedFileURL = fileA

        vm.removeFolder(dirA)

        XCTAssertEqual(vm.rootDirectories, [dirB])
        XCTAssertNil(vm.selectedFileURL, "被移除根下的选中文件应清除")
        XCTAssertFalse(vm.isExpanded(dirA))
        XCTAssertTrue(vm.workspaceIsDirty)
    }

    func testRemoveLastFolderClearsToWelcomeState() async throws {
        let dirA = normalized(try makeDirectory(named: "alpha"))

        let vm = makeViewModel()
        await vm.loadWorkspace(folders: [dirA])
        vm.removeFolder(dirA)

        XCTAssertTrue(vm.nodes.isEmpty)
        XCTAssertTrue(vm.rootDirectories.isEmpty)
        XCTAssertFalse(vm.workspaceIsDirty, "清空后工作区不复存在，不应置脏")
    }

    // MARK: - 脏标记生命周期

    func testMarkWorkspaceSavedResetsDirty() async throws {
        let dirA = normalized(try makeDirectory(named: "alpha"))
        let dirB = normalized(try makeDirectory(named: "beta"))

        let vm = makeViewModel()
        await vm.loadWorkspace(folders: [dirA])
        try await vm.addFolder(dirB)
        XCTAssertTrue(vm.workspaceIsDirty)

        vm.markWorkspaceSaved()
        XCTAssertFalse(vm.workspaceIsDirty)
    }

    // MARK: - 跨根刷新

    func testRefreshSurvivesOneRootDeleted() async throws {
        let dirA = normalized(try makeDirectory(named: "alpha"))
        let dirB = normalized(try makeDirectory(named: "beta"))
        try makeFile(named: "A.md", in: dirA)
        let fileB = normalized(try makeFile(named: "B.md", in: dirB))

        let vm = makeViewModel()
        await vm.loadWorkspace(folders: [dirA, dirB])
        vm.selectedFileURL = fileB

        try FileManager.default.removeItem(at: dirA)
        await vm.refreshDirectory()

        XCTAssertEqual(vm.rootDirectories, [dirB], "被删除的根应丢弃，其余保留")
        XCTAssertEqual(vm.selectedFileURL, fileB, "存活根下的选中不受影响")
        XCTAssertNil(vm.errorMessage)
    }

    func testRefreshAllRootsDeletedShowsError() async throws {
        let dirA = normalized(try makeDirectory(named: "alpha"))

        let vm = makeViewModel()
        await vm.loadWorkspace(folders: [dirA])

        try FileManager.default.removeItem(at: dirA)
        await vm.refreshDirectory()

        XCTAssertTrue(vm.nodes.isEmpty)
        XCTAssertNotNil(vm.errorMessage, "所有根被删除应提示错误")
    }
}

import XCTest
import MarkdownReaderKit
@testable import MarkdownReader

/// WindowSession 工作区命令测试（方案 3.3）。
///
/// 覆盖：openWorkspace 恢复展开/选中并加载文档、缺失目录容忍、
/// prepareForClose 工作区分支、performWorkspaceSave 落盘与脏标记复位。
@MainActor
final class WindowSessionWorkspaceTests: TemporaryDirectoryTestCase {

    /// 测试环境固定：contentsOfDirectory 返回 /private/var 前缀，归一化输入路径保证同源可比。
    private func normalized(_ url: URL) -> URL {
        url.path.hasPrefix("/var/") ? URL(fileURLWithPath: "/private" + url.path) : url
    }

    private func makeSession(coordinator: WindowCoordinator = WindowCoordinator()) -> WindowSession {
        let session = WindowSession(id: WindowID(), coordinator: coordinator)
        coordinator.register(session: session)
        return session
    }

    /// 构造两个含 Markdown 文件的目录。
    private func makeTwoFolders() throws -> (URL, URL, URL, URL) {
        let dirA = normalized(try makeDirectory(named: "alpha"))
        let dirB = normalized(try makeDirectory(named: "beta"))
        let fileA = normalized(try makeFile(named: "A.md", in: dirA, content: "# A"))
        let fileB = normalized(try makeFile(named: "B.md", in: dirB, content: "# B"))
        return (dirA, dirB, fileA, fileB)
    }

    // MARK: - openWorkspace 恢复浏览状态

    func testOpenWorkspaceRestoresFoldersExpandedAndSelection() async throws {
        let (dirA, dirB, fileA, _) = try makeTwoFolders()
        let wsURL = try makeFile(named: "proj.mdworkspace", content: "")
        let document = WorkspaceDocument(
            folders: [dirA.path, dirB.path],
            expandedDirs: [dirA.path],
            selectedFile: fileA.path
        )
        try WorkspaceFileService.save(document, to: wsURL)

        let session = makeSession()
        await session.openWorkspace(wsURL)

        XCTAssertEqual(session.appViewModel.rootDirectories, [dirA, dirB], "应恢复全部目录")
        XCTAssertEqual(session.appViewModel.workspaceFileURL, wsURL, "应关联工作区文件")
        XCTAssertTrue(session.fileTreeViewModel.isExpanded(dirA), "应恢复展开状态")
        XCTAssertEqual(session.fileTreeViewModel.selectedFileURL, fileA, "应恢复选中文件")
        XCTAssertEqual(session.documentViewModel.currentFileURL, fileA, "应加载选中的文档")
        XCTAssertFalse(session.fileTreeViewModel.workspaceIsDirty, "刚打开的工作区不脏")
        XCTAssertFalse(session.isBlank)
    }

    func testOpenWorkspaceToleratesMissingFolders() async throws {
        let (dirA, _, _, _) = try makeTwoFolders()
        let ghost = normalized(temporaryDirectory.appendingPathComponent("ghost"))
        let wsURL = try makeFile(named: "proj.mdworkspace", content: "")
        let document = WorkspaceDocument(folders: [ghost.path, dirA.path])
        try WorkspaceFileService.save(document, to: wsURL)

        let session = makeSession()
        await session.openWorkspace(wsURL)

        XCTAssertEqual(session.appViewModel.rootDirectories, [dirA], "缺失目录跳过，其余正常加载")
        XCTAssertNil(session.fileTreeViewModel.errorMessage)
    }

    func testOpenWorkspaceAllFoldersMissingShowsError() async throws {
        let ghost = normalized(temporaryDirectory.appendingPathComponent("ghost"))
        let wsURL = try makeFile(named: "proj.mdworkspace", content: "")
        try WorkspaceFileService.save(WorkspaceDocument(folders: [ghost.path]), to: wsURL)

        let session = makeSession()
        await session.openWorkspace(wsURL)

        XCTAssertTrue(session.appViewModel.rootDirectories.isEmpty)
        XCTAssertNotNil(session.fileTreeViewModel.errorMessage)
    }

    func testOpenWorkspaceClaimsFolderOwnership() async throws {
        let (dirA, dirB, _, _) = try makeTwoFolders()
        let wsURL = try makeFile(named: "proj.mdworkspace", content: "")
        try WorkspaceFileService.save(
            WorkspaceDocument(folders: [dirA.path, dirB.path]),
            to: wsURL
        )

        let coordinator = WindowCoordinator()
        let session = makeSession(coordinator: coordinator)
        await session.openWorkspace(wsURL)

        let identityService = ResourceIdentityService()
        XCTAssertEqual(
            coordinator.owner(of: try identityService.identity(for: dirA, kind: .directory)),
            session.id, "工作区内文件夹应归本窗口持有"
        )
        XCTAssertEqual(
            coordinator.owner(of: try identityService.identity(for: dirB, kind: .directory)),
            session.id, "工作区内文件夹应归本窗口持有"
        )
        // 注：工作区文件自身的所有权由路由调用点（handleOpenRequest/WindowSceneHost）claim，
        // 不在 session.openWorkspace 内重复声明。
    }

    // MARK: - prepareForClose 工作区分支

    func testPrepareForCloseCleanSingleRootReturnsClose() async throws {
        let (dirA, _, _, _) = try makeTwoFolders()
        let session = makeSession()

        await session.openDirectory(dirA)

        XCTAssertEqual(session.prepareForClose(), .close)
    }

    func testPrepareForCloseDirtyWorkspaceNeedsDecision() async throws {
        let (dirA, dirB, _, _) = try makeTwoFolders()
        let session = makeSession()

        await session.openDirectory(dirA)
        try await session.fileTreeViewModel.addFolder(dirB)
        session.appViewModel.rootDirectories = session.fileTreeViewModel.rootDirectories

        XCTAssertEqual(session.prepareForClose(), .needsWorkspaceDecision,
                       "未保存的多根工作区关闭时需要保存决策")
        XCTAssertTrue(session.workspaceNeedsSaveDecision)
    }

    // MARK: - performWorkspaceSave

    func testPerformWorkspaceSaveWritesStateAndResetsDirty() async throws {
        let (dirA, dirB, fileA, _) = try makeTwoFolders()
        let session = makeSession()

        await session.openDirectory(dirA)
        try await session.fileTreeViewModel.addFolder(dirB)
        session.appViewModel.rootDirectories = session.fileTreeViewModel.rootDirectories
        session.fileTreeViewModel.selectedFileURL = fileA
        XCTAssertTrue(session.fileTreeViewModel.workspaceIsDirty)

        let target = temporaryDirectory.appendingPathComponent("saved.mdworkspace")
        let success = session.performWorkspaceSave(to: target)

        XCTAssertTrue(success)
        XCTAssertEqual(session.appViewModel.workspaceFileURL, target)
        XCTAssertFalse(session.fileTreeViewModel.workspaceIsDirty, "保存后脏标记复位")

        // 内容 round-trip 校验
        let loaded = try WorkspaceFileService.load(from: target)
        XCTAssertEqual(loaded.folders, [dirA.path, dirB.path])
        XCTAssertEqual(loaded.selectedFile, fileA.path)
    }

    func testPerformWorkspaceSaveFailureKeepsDirty() async throws {
        let (dirA, dirB, _, _) = try makeTwoFolders()
        let session = makeSession()

        await session.openDirectory(dirA)
        try await session.fileTreeViewModel.addFolder(dirB)
        session.appViewModel.rootDirectories = session.fileTreeViewModel.rootDirectories

        let badTarget = URL(fileURLWithPath: "/nonexistent-root-\(UUID().uuidString)/ws.mdworkspace")
        let success = session.performWorkspaceSave(to: badTarget)

        XCTAssertFalse(success)
        XCTAssertTrue(session.fileTreeViewModel.workspaceIsDirty, "保存失败脏标记保留")
        XCTAssertNil(session.appViewModel.workspaceFileURL)
    }

    // MARK: - 拖拽目录添加文件夹

    /// 轮询等待异步条件（拖拽添加经 Task 异步执行）。
    private func waitFor(
        timeout: TimeInterval = 2.0,
        condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testDroppedFolderAddsToExistingWorkspace() async throws {
        let (dirA, dirB, _, _) = try makeTwoFolders()
        let session = makeSession()

        await session.openDirectory(dirA)
        session.addDroppedFolder(dirB)

        await waitFor {
            session.fileTreeViewModel.rootDirectories.map(\.path) == [dirA.path, dirB.path]
        }
        XCTAssertEqual(session.fileTreeViewModel.rootDirectories.map(\.path), [dirA.path, dirB.path],
                       "拖拽目录应添加到工作区")
        XCTAssertEqual(session.appViewModel.rootDirectories.map(\.path), [dirA.path, dirB.path])
        XCTAssertTrue(session.fileTreeViewModel.workspaceIsDirty)
    }

    func testDroppedFileIsIgnored() async throws {
        let (dirA, _, fileA, _) = try makeTwoFolders()
        let session = makeSession()

        await session.openDirectory(dirA)
        session.addDroppedFolder(fileA)  // 非目录

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(session.fileTreeViewModel.rootDirectories, [dirA], "非目录拖拽应被忽略")
        XCTAssertFalse(session.fileTreeViewModel.workspaceIsDirty)
    }

    func testDroppedNestedFolderDoesNotModifyWorkspace() async throws {
        let dirA = normalized(try makeDirectory(named: "alpha"))
        let child = dirA.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let session = makeSession()
        var presentedKey: L10n.Key?
        session.addFolderErrorPresenterForTesting = { presentedKey = $0 }

        await session.openDirectory(dirA)
        session.addDroppedFolder(child)  // 嵌套冲突：performAddFolder 拒绝并提示

        await waitFor { presentedKey != nil }
        XCTAssertEqual(presentedKey, .workspaceNestedConflict, "嵌套冲突应提示对应错误")
        XCTAssertEqual(session.fileTreeViewModel.rootDirectories.count, 1,
                       "嵌套目录不得被添加到工作区")
        XCTAssertFalse(session.fileTreeViewModel.workspaceIsDirty)
    }

    func testDroppedDuplicateFolderReportsAlreadyInWorkspace() async throws {
        let (dirA, _, _, _) = try makeTwoFolders()
        let session = makeSession()
        var presentedKey: L10n.Key?
        session.addFolderErrorPresenterForTesting = { presentedKey = $0 }

        await session.openDirectory(dirA)
        session.addDroppedFolder(dirA)  // 重复

        await waitFor { presentedKey != nil }
        XCTAssertEqual(presentedKey, .workspaceAlreadyAdded)
        XCTAssertEqual(session.fileTreeViewModel.rootDirectories.count, 1)
    }

    func testDroppedFolderOnBlankWindowOpensAsDirectory() async throws {
        let (dirA, _, _, _) = try makeTwoFolders()
        let coordinator = WindowCoordinator()
        coordinator.windowCreationClosureForTesting = { _ in }
        let session = WindowSession(id: WindowID(), coordinator: coordinator)
        coordinator.register(session: session)
        XCTAssertTrue(session.isBlank)

        session.addDroppedFolder(dirA)

        await waitFor {
            session.appViewModel.rootDirectories.map(\.path) == [dirA.path]
        }
        XCTAssertEqual(session.appViewModel.rootDirectories.map(\.path), [dirA.path],
                       "空白窗口拖拽目录应等价于打开目录")
    }

    // MARK: - removeFolderFromWorkspace

    func testRemoveFolderFromWorkspaceReleasesOwnershipAndSyncsState() async throws {
        let (dirA, dirB, _, _) = try makeTwoFolders()
        let coordinator = WindowCoordinator()
        let session = makeSession(coordinator: coordinator)

        await session.openDirectory(dirA)
        try await session.fileTreeViewModel.addFolder(dirB)
        session.appViewModel.rootDirectories = session.fileTreeViewModel.rootDirectories
        let identityService = ResourceIdentityService()
        try coordinator.claim(identityService.identity(for: dirB, kind: .directory), for: session.id)

        session.removeFolderFromWorkspace(dirB)

        XCTAssertEqual(session.appViewModel.rootDirectories, [dirA])
        XCTAssertNil(coordinator.owner(of: try identityService.identity(for: dirB, kind: .directory)),
                     "移除后根目录所有权应释放")
    }
}

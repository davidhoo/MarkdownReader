import XCTest
@testable import MarkdownReader

/// 脏工作区关闭确认流程测试（方案 3.3）。
///
/// 注入 fake 交互边界，覆盖：保存成功放行 / 取消保持窗口 / 不保存丢弃 /
/// 保存面板取消保持窗口，以及与脏 Untitled 决策的串行处理。
@MainActor
final class UnsavedWorkspaceCloseTests: TemporaryDirectoryTestCase {

    // MARK: - fake 交互边界

    /// 可编程的工作区关闭交互边界。
    final class FakeWorkspaceCloseInteraction: UnsavedCloseInteraction {
        var promptChoice: UnsavedPromptChoice = .cancel
        /// 脏 Untitled 文档提示的选择（与工作区提示分开控制，验证串行顺序用）。
        var documentPromptChoice: UnsavedPromptChoice = .dontSave
        /// 工作区保存面板返回的目标 URL；nil 表示用户取消面板。
        var workspaceSaveTarget: URL?
        /// 记录是否展示过工作区提示（验证串行顺序用）
        private(set) var workspacePromptShown = false

        func presentUnsavedChangesPrompt(for session: WindowSession) -> UnsavedPromptChoice {
            documentPromptChoice
        }

        func chooseSaveAsTarget(
            for session: WindowSession,
            suggestedName: String,
            defaultDirectory: URL?
        ) async -> URL? {
            nil
        }

        func presentUnsavedWorkspacePrompt(for session: WindowSession) -> UnsavedPromptChoice {
            workspacePromptShown = true
            return promptChoice
        }

        func chooseWorkspaceSaveTarget(
            for session: WindowSession,
            suggestedName: String,
            defaultDirectory: URL?
        ) async -> URL? {
            workspaceSaveTarget
        }
    }

    /// 测试环境固定：contentsOfDirectory 返回 /private/var 前缀，归一化输入路径。
    private func normalized(_ url: URL) -> URL {
        url.path.hasPrefix("/var/") ? URL(fileURLWithPath: "/private" + url.path) : url
    }

    private func makeCoordinatorAndInteraction() -> (WindowCoordinator, ApplicationTerminationCoordinator, FakeWorkspaceCloseInteraction) {
        let coordinator = WindowCoordinator()
        let interaction = FakeWorkspaceCloseInteraction()
        let termCoord = ApplicationTerminationCoordinator(coordinator: coordinator, closeInteraction: interaction)
        return (coordinator, termCoord, interaction)
    }

    /// 构造一个含脏工作区的 session：打开目录后追加第二个根（addFolder 置脏）。
    private func makeSessionWithDirtyWorkspace(coordinator: WindowCoordinator) async throws -> WindowSession {
        let dirA = normalized(try makeDirectory(named: "alpha"))
        let dirB = normalized(try makeDirectory(named: "beta"))
        try makeFile(named: "A.md", in: dirA)
        try makeFile(named: "B.md", in: dirB)

        let session = WindowSession(id: WindowID(), coordinator: coordinator)
        coordinator.register(session: session)
        await session.openDirectory(dirA)
        try await session.fileTreeViewModel.addFolder(dirB)
        session.appViewModel.rootDirectories = session.fileTreeViewModel.rootDirectories
        XCTAssertTrue(session.workspaceNeedsSaveDecision, "前置条件：工作区必须为脏")
        return session
    }

    // MARK: - 保存成功放行

    func testWorkspaceSaveSuccessAllowsClose() async throws {
        let (coordinator, termCoord, interaction) = makeCoordinatorAndInteraction()
        let session = try await makeSessionWithDirtyWorkspace(coordinator: coordinator)

        let saveURL = temporaryDirectory.appendingPathComponent("ws.mdworkspace")
        interaction.promptChoice = .save
        interaction.workspaceSaveTarget = saveURL

        let decision = await termCoord.resolveWorkspaceChanges(for: session)

        XCTAssertEqual(decision, .proceed, "保存成功应放行")
        XCTAssertFalse(session.fileTreeViewModel.workspaceIsDirty, "保存后脏标记复位")
        XCTAssertEqual(session.appViewModel.workspaceFileURL, saveURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saveURL.path))
    }

    // MARK: - 已关联工作区文件：保存直接覆写原文件

    func testAssociatedWorkspaceSaveOverwritesOriginalFileWithoutPanel() async throws {
        let (coordinator, termCoord, interaction) = makeCoordinatorAndInteraction()

        // 打开一个已保存的工作区文件（关联 workspaceFileURL）
        let dirA = normalized(try makeDirectory(named: "alpha"))
        let dirB = normalized(try makeDirectory(named: "beta"))
        try makeFile(named: "A.md", in: dirA)
        try makeFile(named: "B.md", in: dirB)
        let wsURL = try makeFile(named: "proj.mdworkspace", content: "")
        try WorkspaceFileService.save(WorkspaceDocument(folders: [dirA.path]), to: wsURL)

        let session = WindowSession(id: WindowID(), coordinator: coordinator)
        coordinator.register(session: session)
        await session.openWorkspace(wsURL)
        XCTAssertEqual(session.appViewModel.workspaceFileURL, wsURL)

        // 修改工作区：追加第二个根（置脏）
        try await session.fileTreeViewModel.addFolder(dirB)
        session.appViewModel.rootDirectories = session.fileTreeViewModel.rootDirectories
        XCTAssertTrue(session.workspaceNeedsSaveDecision)

        // 关闭确认选择保存；面板目标故意置 nil —— 若误走另存为面板会被判为取消
        interaction.promptChoice = .save
        interaction.workspaceSaveTarget = nil

        let decision = await termCoord.resolveWorkspaceChanges(for: session)

        XCTAssertEqual(decision, .proceed, "已关联工作区保存应直接覆写原文件，不依赖另存为面板")
        XCTAssertFalse(session.fileTreeViewModel.workspaceIsDirty)
        XCTAssertEqual(session.appViewModel.workspaceFileURL, wsURL, "关联文件不得变更")

        // 原文件内容已更新（包含新增的根）
        let loaded = try WorkspaceFileService.load(from: wsURL)
        XCTAssertEqual(loaded.folders, [dirA.path, dirB.path], "原工作区文件应被覆写为最新状态")
    }

    // MARK: - 取消保持窗口

    func testWorkspaceCancelKeepsWindowOpen() async throws {
        let (coordinator, termCoord, interaction) = makeCoordinatorAndInteraction()
        let session = try await makeSessionWithDirtyWorkspace(coordinator: coordinator)

        interaction.promptChoice = .cancel

        let decision = await termCoord.resolveWorkspaceChanges(for: session)

        XCTAssertEqual(decision, .cancel, "取消应保留窗口")
        XCTAssertTrue(session.fileTreeViewModel.workspaceIsDirty, "取消后工作区状态不变")
    }

    // MARK: - 不保存丢弃

    func testWorkspaceDontSaveDiscardsChanges() async throws {
        let (coordinator, termCoord, interaction) = makeCoordinatorAndInteraction()
        let session = try await makeSessionWithDirtyWorkspace(coordinator: coordinator)

        interaction.promptChoice = .dontSave

        let decision = await termCoord.resolveWorkspaceChanges(for: session)

        XCTAssertEqual(decision, .proceed, "不保存应放行")
        XCTAssertFalse(session.fileTreeViewModel.workspaceIsDirty, "不保存后脏标记复位")
        XCTAssertNil(session.appViewModel.workspaceFileURL, "不保存不得产生工作区文件")
    }

    // MARK: - 保存面板取消

    func testWorkspaceSavePanelCancelKeepsWindowOpen() async throws {
        let (coordinator, termCoord, interaction) = makeCoordinatorAndInteraction()
        let session = try await makeSessionWithDirtyWorkspace(coordinator: coordinator)

        interaction.promptChoice = .save
        interaction.workspaceSaveTarget = nil  // 用户取消保存面板

        let decision = await termCoord.resolveWorkspaceChanges(for: session)

        XCTAssertEqual(decision, .cancel, "取消保存面板应保留窗口")
        XCTAssertTrue(session.fileTreeViewModel.workspaceIsDirty)
    }

    // MARK: - 与脏 Untitled 串行处理

    func testResolveCloseBlockersHandlesUntitledThenWorkspace() async throws {
        let (coordinator, termCoord, interaction) = makeCoordinatorAndInteraction()
        let session = try await makeSessionWithDirtyWorkspace(coordinator: coordinator)

        // 叠加一个脏 Untitled 文档
        session.documentViewModel.createUntitledFile()
        session.documentViewModel.content = "# modified"
        session.appViewModel.hasUnsavedUntitled = true
        session.appViewModel.untitledFileName = session.documentViewModel.fileName

        interaction.promptChoice = .dontSave  // 工作区选择不保存

        let decision = await termCoord.resolveCloseBlockers(for: session)

        XCTAssertEqual(decision, .proceed, "两个阻塞项都处理后应放行")
        XCTAssertTrue(interaction.workspacePromptShown, "Untitled 处理后必须继续询问工作区")
        XCTAssertFalse(session.fileTreeViewModel.workspaceIsDirty)
        XCTAssertFalse(session.documentViewModel.isUntitled, "Untitled 应已被 dontSave 清理")
    }

    func testResolveCloseBlockersCancelOnUntitledSkipsWorkspace() async throws {
        let (coordinator, termCoord, interaction) = makeCoordinatorAndInteraction()
        let session = try await makeSessionWithDirtyWorkspace(coordinator: coordinator)

        session.documentViewModel.createUntitledFile()
        session.documentViewModel.content = "# modified"
        session.appViewModel.hasUnsavedUntitled = true
        session.appViewModel.untitledFileName = session.documentViewModel.fileName

        interaction.promptChoice = .cancel  // 工作区提示选择（本用例不应到达）
        interaction.documentPromptChoice = .cancel  // Untitled 提示取消

        let decision = await termCoord.resolveCloseBlockers(for: session)

        XCTAssertEqual(decision, .cancel, "Untitled 取消应立即终止，保留窗口")
        XCTAssertFalse(interaction.workspacePromptShown, "Untitled 取消后不得再弹工作区提示")
        XCTAssertTrue(session.fileTreeViewModel.workspaceIsDirty)
    }

    // MARK: - prepareForClose 联动

    func testCleanWorkspaceClosesImmediately() async throws {
        let coordinator = WindowCoordinator()
        let termCoord = ApplicationTerminationCoordinator(coordinator: coordinator)
        let dirA = normalized(try makeDirectory(named: "alpha"))
        try makeFile(named: "A.md", in: dirA)

        let session = WindowSession(id: WindowID(), coordinator: coordinator)
        coordinator.register(session: session)
        await session.openDirectory(dirA)

        XCTAssertTrue(termCoord.shouldCloseImmediately(session: session),
                      "未修改的单根目录窗口应直接关闭")
    }
}

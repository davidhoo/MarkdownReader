import XCTest
import MarkdownReaderKit
@testable import MarkdownReader

/// 特征测试：AppViewModel 窗口标题与目录/单文件模式切换现状行为。
///
/// 工作区改造（rootDirectory → rootDirectories）前锁定标题派生规则。
@MainActor
final class AppViewModelTitleTests: TemporaryDirectoryTestCase {

    func testInitialTitleIsPlain() {
        let vm = AppViewModel()
        XCTAssertEqual(vm.windowTitle, "Markdown Reader")
        XCTAssertNil(vm.rootDirectory)
        XCTAssertFalse(vm.isSingleFileMode)
    }

    func testOpenDirectorySetsDirectoryTitle() throws {
        let dir = try makeDirectory(named: "docs")
        let vm = AppViewModel()

        vm.openDirectory(dir)

        XCTAssertEqual(vm.windowTitle, "Markdown Reader — docs")
        XCTAssertEqual(vm.rootDirectory, dir)
        XCTAssertFalse(vm.isSingleFileMode)
        XCTAssertTrue(vm.isSidebarVisible, "目录模式必须保证 Sidebar 可见")
    }

    func testOpenSingleFileSetsFileTitleAndClearsDirectory() throws {
        let dir = try makeDirectory(named: "docs")
        let file = try makeFile(named: "note.md", in: dir)
        let vm = AppViewModel()

        vm.openDirectory(dir)
        vm.openSingleFile(file)

        XCTAssertEqual(vm.windowTitle, "Markdown Reader — note.md")
        XCTAssertNil(vm.rootDirectory)
        XCTAssertTrue(vm.isSingleFileMode)
        XCTAssertEqual(vm.singleFileURL, file)
    }

    func testUntitledTitleTakesPrecedence() throws {
        let dir = try makeDirectory(named: "docs")
        let vm = AppViewModel()
        vm.openDirectory(dir)

        vm.hasUnsavedUntitled = true
        vm.untitledFileName = "Untitled.md"
        // 标题在状态写入后经显式刷新路径更新；此处直接触发 didSet 语义验证优先级
        vm.openDirectory(dir)

        XCTAssertEqual(vm.windowTitle, "Markdown Reader — Untitled.md")
    }

    func testSidebarPresentationIdentityTracksDirectoryContext() throws {
        let dirA = try makeDirectory(named: "a")
        let dirB = try makeDirectory(named: "b")
        let vm = AppViewModel()

        XCTAssertEqual(vm.sidebarPresentationIdentity, "welcome")
        vm.openDirectory(dirA)
        let identityA = vm.sidebarPresentationIdentity
        XCTAssertNotEqual(identityA, "welcome")
        vm.openDirectory(dirB)
        XCTAssertNotEqual(vm.sidebarPresentationIdentity, identityA, "目录上下文变化应触发 Sidebar 重建")
    }

    func testOpenDirectoryRestoresInvalidSidebarWidth() throws {
        let dir = try makeDirectory(named: "docs")
        let vm = AppViewModel()
        vm.isSidebarVisible = false
        vm.sidebarWidth = 100  // 低于最小宽度

        vm.openDirectory(dir)

        XCTAssertTrue(vm.isSidebarVisible)
        XCTAssertEqual(vm.sidebarWidth, AppViewModel.defaultSidebarWidth)
    }

    // MARK: - 工作区标题扩展

    func testUnsavedMultiRootWorkspaceShowsUntitledWorkspaceTitle() throws {
        let dirA = try makeDirectory(named: "a")
        let dirB = try makeDirectory(named: "b")
        let vm = AppViewModel()

        vm.openWorkspace(folders: [dirA, dirB], fileURL: nil)

        let language = SettingsModel.shared.languagePref.resolvedLanguage
        let expected = "Markdown Reader — \(L10n.tr(.workspaceUntitledName, language: language))"
        XCTAssertEqual(vm.windowTitle, expected, "未保存多根工作区应显示未命名工作区标题")
        XCTAssertTrue(vm.isWorkspaceMode)
    }

    func testSavedWorkspaceShowsFileNameTitle() throws {
        let dirA = try makeDirectory(named: "a")
        let wsURL = try makeFile(named: "my-project.mdworkspace")
        let vm = AppViewModel()

        vm.openWorkspace(folders: [dirA], fileURL: wsURL)

        XCTAssertEqual(vm.windowTitle, "Markdown Reader — my-project.mdworkspace",
                       "已保存工作区应显示工作区文件名")
        XCTAssertTrue(vm.isWorkspaceMode, "关联工作区文件后即使单根也是工作区模式")
    }

    func testSingleRootWithoutWorkspaceKeepsFolderTitle() throws {
        let dir = try makeDirectory(named: "docs")
        let vm = AppViewModel()

        vm.openDirectory(dir)

        XCTAssertEqual(vm.windowTitle, "Markdown Reader — docs")
        XCTAssertFalse(vm.isWorkspaceMode)
    }

    func testSidebarPresentationIdentityDiffersAcrossRootSets() throws {
        let dirA = try makeDirectory(named: "a")
        let dirB = try makeDirectory(named: "b")
        let vm = AppViewModel()

        vm.openWorkspace(folders: [dirA], fileURL: nil)
        let singleIdentity = vm.sidebarPresentationIdentity
        vm.openWorkspace(folders: [dirA, dirB], fileURL: nil)
        XCTAssertNotEqual(vm.sidebarPresentationIdentity, singleIdentity,
                          "根集合变化应触发 Sidebar 重建")
    }
}

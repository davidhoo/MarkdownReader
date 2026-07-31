import XCTest
import SwiftUI
import AppKit
@testable import MarkdownReader

/// 打开目录时自动展开 Sidebar 的回归测试（需求：目录模式必须保证目录树可见）。
///
/// 覆盖：
/// - isSidebarVisible == false 时 openDirectory 后变 true；
/// - 从单文件模式打开目录：清理旧文件并展开 Sidebar；
/// - 已显示 Sidebar 时打开另一目录：不重置用户调整过的宽度；
/// - 从隐藏切到显示且宽度无效：恢复默认宽度；
/// - 不同 WindowSession 间 Sidebar 状态隔离；
/// - openSingleFile 仍保持隐藏 Sidebar 的行为。
@MainActor
final class OpenDirectorySidebarTests: TemporaryDirectoryTestCase {

    private func makeAppViewModel() -> AppViewModel { AppViewModel() }

    // MARK: - 隐藏状态下打开目录 → 展开

    func testOpenDirectoryShowsSidebarWhenHidden() throws {
        let vm = makeAppViewModel()
        vm.isSidebarVisible = false

        let dir = try makeDirectory(named: "docs")

        vm.openDirectory(dir)

        XCTAssertTrue(vm.isSidebarVisible, "打开目录后 Sidebar 必须可见")
        XCTAssertEqual(vm.rootDirectory, dir)
        XCTAssertFalse(vm.isSingleFileMode, "目录模式不能是单文件模式")
        XCTAssertNil(vm.singleFileURL)
        XCTAssertNil(vm.selectedFile, "打开目录应清理旧选中状态")
    }

    // MARK: - 从单文件模式切换到目录模式

    func testOpenDirectoryFromSingleFileModeClearsOldFile() throws {
        let vm = makeAppViewModel()
        let file = try makeFile(named: "single.md", content: "# x")
        vm.openSingleFile(file)
        XCTAssertTrue(vm.isSingleFileMode)
        XCTAssertFalse(vm.isSidebarVisible, "前置：单文件模式默认隐藏 Sidebar")
        XCTAssertEqual(vm.singleFileURL, file)

        let dir = try makeDirectory(named: "notes")
        vm.openDirectory(dir)

        XCTAssertFalse(vm.isSingleFileMode, "切换到目录模式后 isSingleFileMode 必须为 false")
        XCTAssertNil(vm.singleFileURL, "旧 singleFileURL 必须被清理")
        XCTAssertEqual(vm.rootDirectory, dir)
        XCTAssertTrue(vm.isSidebarVisible, "从单文件模式切目录后 Sidebar 必须展开")
    }

    // MARK: - 已显示 Sidebar 时不重置用户调整的宽度

    func testOpenDirectoryKeepsUserAdjustedWidthWhenVisible() throws {
        let vm = makeAppViewModel()
        vm.isSidebarVisible = true
        // 用户手动调整到一个有效但非默认的宽度
        vm.sidebarWidth = 320
        let dirA = try makeDirectory(named: "a")
        let dirB = try makeDirectory(named: "b")

        vm.openDirectory(dirA)
        vm.openDirectory(dirB)

        XCTAssertEqual(vm.sidebarWidth, 320, "Sidebar 已可见时打开另一个目录不得重置用户调整过的宽度")
        XCTAssertEqual(vm.rootDirectory, dirB)
        XCTAssertTrue(vm.isSidebarVisible)
    }

    // MARK: - 从隐藏切到显示且宽度无效 → 恢复默认宽度

    func testOpenDirectoryRestoresWidthWhenHiddenAndInvalid() throws {
        let vm = makeAppViewModel()
        vm.isSidebarVisible = false
        // 模拟收起操作把宽度压到阈值以下（无效宽度）
        vm.sidebarWidth = 50
        let dir = try makeDirectory(named: "docs")

        vm.openDirectory(dir)

        XCTAssertTrue(vm.isSidebarVisible)
        XCTAssertEqual(vm.sidebarWidth, AppViewModel.defaultSidebarWidth,
                       "从隐藏切到显示且宽度无效时应恢复默认宽度")
    }

    // MARK: - 从隐藏切到显示但宽度仍有效 → 保留宽度

    func testOpenDirectoryKeepsValidWidthWhenBecomingVisible() throws {
        let vm = makeAppViewModel()
        vm.isSidebarVisible = false
        // 虽隐藏但宽度仍有效（用户曾手动调过又收起）
        vm.sidebarWidth = 280
        let dir = try makeDirectory(named: "docs")

        vm.openDirectory(dir)

        XCTAssertTrue(vm.isSidebarVisible)
        XCTAssertEqual(vm.sidebarWidth, 280, "宽度有效时即使从隐藏切到显示也不应重置")
    }

    // MARK: - openSingleFile 仍隐藏 Sidebar

    func testOpenSingleFileHidesSidebar() throws {
        let vm = makeAppViewModel()
        vm.isSidebarVisible = true
        let file = try makeFile(named: "single.md", content: "# x")

        vm.openSingleFile(file)

        XCTAssertTrue(vm.isSingleFileMode)
        XCTAssertFalse(vm.isSidebarVisible, "打开单个文件必须默认隐藏 Sidebar")
        XCTAssertEqual(vm.singleFileURL, file)
        XCTAssertNil(vm.rootDirectory)
    }

    // MARK: - 不同 WindowSession 间 Sidebar 状态隔离

    func testSidebarStateIsolatedAcrossSessions() throws {
        let coordinator = WindowCoordinator()
        let a = WindowSession(id: WindowID(), coordinator: coordinator)
        let b = WindowSession(id: WindowID(), coordinator: coordinator)
        coordinator.register(session: a)
        coordinator.register(session: b)

        let dirA = try makeDirectory(named: "a")
        let dirB = try makeDirectory(named: "b")

        // a 打开目录 → 展开 Sidebar
        a.appViewModel.isSidebarVisible = false
        a.appViewModel.openDirectory(dirA)
        XCTAssertTrue(a.appViewModel.isSidebarVisible)

        // b 保持隐藏并打开单文件，不影响 a
        b.appViewModel.isSidebarVisible = false
        let fileB = try makeFile(named: "b.md", content: "# b")
        b.appViewModel.openSingleFile(fileB)

        XCTAssertTrue(a.appViewModel.isSidebarVisible, "a 的 Sidebar 不应被 b 的操作影响")
        XCTAssertFalse(b.appViewModel.isSidebarVisible, "b 单文件模式应隐藏 Sidebar")
        XCTAssertEqual(a.appViewModel.rootDirectory, dirA)
        XCTAssertEqual(b.appViewModel.singleFileURL, fileB)
    }

    // MARK: - WindowSession.openDirectory 同步展开 Sidebar（异步加载前即可见）

    func testSessionOpenDirectoryShowsSidebarBeforeTreeLoads() async throws {
        let coordinator = WindowCoordinator()
        let session = WindowSession(id: WindowID(), coordinator: coordinator)
        coordinator.register(session: session)
        session.appViewModel.isSidebarVisible = false

        let dir = try makeDirectory(named: "docs")
        try makeFile(named: "A.md", in: dir, content: "# A")

        await session.openDirectory(dir)

        XCTAssertTrue(session.appViewModel.isSidebarVisible, "session 打开目录后 Sidebar 必须可见")
        XCTAssertEqual(session.appViewModel.rootDirectory, dir)
        XCTAssertFalse(session.fileTreeViewModel.nodes.isEmpty, "目录树应已加载")
    }

    // MARK: - 欢迎页切换到目录时重建 Sidebar 布局

    func testSidebarPresentationIdentityChangesWhenDirectoryContextChanges() throws {
        let vm = makeAppViewModel()
        let welcomeIdentity = vm.sidebarPresentationIdentity
        let dirA = try makeDirectory(named: "a")
        let dirB = try makeDirectory(named: "b")

        vm.openDirectory(dirA)
        let directoryAIdentity = vm.sidebarPresentationIdentity

        XCTAssertNotEqual(
            directoryAIdentity,
            welcomeIdentity,
            "从欢迎页进入目录模式时必须更新 Sidebar 身份，强制 SwiftUI 重新建立非零宽度布局"
        )

        vm.openDirectory(dirA)
        XCTAssertEqual(
            vm.sidebarPresentationIdentity,
            directoryAIdentity,
            "重复打开同一目录不应无谓重建 Sidebar"
        )

        vm.openDirectory(dirB)
        XCTAssertNotEqual(
            vm.sidebarPresentationIdentity,
            directoryAIdentity,
            "切换根目录时应为 Sidebar 建立新的目录上下文"
        )
    }

    func testWelcomeToDirectoryRebuildsSidebarButVisibilityToggleReusesIt() throws {
        let coordinator = WindowCoordinator()
        let session = WindowSession(id: WindowID(), coordinator: coordinator)
        coordinator.register(session: session)

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

        let welcomeProbe = try XCTUnwrap(findSidebarProbe(in: hostingView))
        XCTAssertEqual(welcomeProbe.frame.width, 0, accuracy: 1)

        let dir = try makeDirectory(named: "docs")
        session.appViewModel.openDirectory(dir)
        settleLayout(hostingView)

        let directoryProbe = try XCTUnwrap(findSidebarProbe(in: hostingView))
        XCTAssertFalse(
            welcomeProbe === directoryProbe,
            "欢迎页进入目录模式必须重建 Sidebar 子树，清除遗留的 0 宽度布局"
        )
        XCTAssertGreaterThanOrEqual(
            directoryProbe.frame.width,
            AppViewModel.minSidebarWidth,
            "目录打开后 Sidebar 的实际 AppKit 布局宽度必须非零"
        )

        session.appViewModel.toggleSidebar()
        settleLayout(hostingView)
        let hiddenProbe = try XCTUnwrap(findSidebarProbe(in: hostingView))
        XCTAssertTrue(directoryProbe === hiddenProbe, "普通隐藏不得销毁 Sidebar 子树")

        session.appViewModel.toggleSidebar()
        settleLayout(hostingView)
        let shownProbe = try XCTUnwrap(findSidebarProbe(in: hostingView))
        XCTAssertTrue(directoryProbe === shownProbe, "普通重新显示应复用 Sidebar 子树")
        XCTAssertGreaterThanOrEqual(shownProbe.frame.width, AppViewModel.minSidebarWidth)

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

    private func findSidebarProbe(in view: NSView) -> NSView? {
        findSidebarProbes(in: view).max { $0.frame.width < $1.frame.width }
    }

    private func findSidebarProbes(in view: NSView) -> [NSView] {
        var probes: [NSView] = []
        if view.identifier == SidebarLayoutProbe.viewIdentifier {
            probes.append(view)
        }
        for subview in view.subviews {
            probes.append(contentsOf: findSidebarProbes(in: subview))
        }
        return probes
    }
}

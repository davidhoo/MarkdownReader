import XCTest
@testable import MarkdownReaderKit
@testable import MarkdownReader

/// 窗口命令目标测试（Task 7 Step 1）。
///
/// 验证 WindowCommandTarget 只作用于它绑定的 session，命令不会泄漏到其它窗口的
/// session，session 释放后 target 变为 no-op。这是 FocusedValues 命令路由隔离的
/// 核心不变式：菜单命令只命中焦点窗口。
@MainActor
final class WindowCommandTargetTests: TemporaryDirectoryTestCase {

    private func makeSession(coordinator: WindowCoordinator) -> WindowSession {
        WindowSession(id: WindowID(), coordinator: coordinator)
    }

    // MARK: - 只作用于绑定的 session

    func testCommandTargetsOnlyBoundSession() {
        let coordinator = WindowCoordinator()
        let session = makeSession(coordinator: coordinator)
        let target = WindowCommandTarget(session: session)

        XCTAssertTrue(target.session === session, "target 必须弱引用所绑定的 session")
    }

    // MARK: - 保存命令不触达其它 session

    func testSaveCommandDoesNotReachOtherSession() {
        let coordinator = WindowCoordinator()
        let owner = makeSession(coordinator: coordinator)
        let other = makeSession(coordinator: coordinator)

        // owner 脏，other 干净；对 owner 的 target 发 save，other 的 isDirty 不应被触及
        owner.documentViewModel.isDirty = true
        XCTAssertFalse(other.documentViewModel.isDirty)

        let ownerTarget = WindowCommandTarget(session: owner)
        // perform(.save) 不会影响 other 的 DocumentViewModel
        ownerTarget.perform(.save)

        XCTAssertTrue(owner.documentViewModel.isDirty, "owner 脏状态应保持（save 异步，未落地）")
        XCTAssertFalse(other.documentViewModel.isDirty, "other 不应被 owner 的命令触及")
    }

    // MARK: - 模式切换命令路由到视图级 handler

    func testDisplayModeCommandUsesRegisteredViewHandler() {
        let coordinator = WindowCoordinator()
        let session = makeSession(coordinator: coordinator)
        let target = WindowCommandTarget(session: session)
        var received: DisplayMode?
        target.displayModeSwitchHandler = { received = $0 }

        target.perform(.switchDisplayMode(.raw))

        XCTAssertEqual(received, .raw)
        XCTAssertNotEqual(session.documentViewModel.displayMode, .raw,
                          "handler 接管时不得直接修改 ViewModel 的 displayMode")
    }

    /// 无 handler 回退：可直接改变模式，但绝不能发布旧行号请求（Task 1 合同）。
    func testDisplayModeCommandFallbackSwitchesWithoutLegacyRequest() {
        let coordinator = WindowCoordinator()
        let session = makeSession(coordinator: coordinator)
        let target = WindowCommandTarget(session: session)
        // 预置一个未消费的显式跳转请求，模拟大纲/查找残留。
        session.documentViewModel.requestScroll(to: SourceLine(oneBased: 5))

        target.perform(.switchDisplayMode(.raw))

        XCTAssertEqual(session.documentViewModel.displayMode, .raw)
        XCTAssertNil(session.documentViewModel.scrollToSourceLineRequest,
                     "回退切换不得遗留或产生旧行号请求")
    }

    // MARK: - session 释放后 target 变 no-op

    func testTargetBecomesNoOpAfterSessionDisposal() {
        let coordinator = WindowCoordinator()
        var session: WindowSession? = makeSession(coordinator: coordinator)
        let target = WindowCommandTarget(session: session!)

        // 模拟窗口关闭：释放 session 弱引用
        coordinator.register(session: session!)
        session?.dispose()
        session = nil

        XCTAssertNil(target.session, "session 释放后 target.session 必须为 nil")
        // no-op：不崩溃即通过
        target.perform(.save)
        target.perform(.toggleSidebar)
        target.openBlankWindow()
    }
}

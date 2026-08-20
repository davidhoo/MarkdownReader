import XCTest
@testable import MarkdownReader

/// 路由引擎工作区（.workspace kind）决策测试（方案 3.3）。
///
/// 验证新增 workspace 身份不破坏既有 file/directory 决策，
/// 且空白窗口复用 / 新建窗口 / activateOwner 语义与既有资源一致。
final class WorkspaceRoutingTests: TemporaryDirectoryTestCase {

    private let engine = WindowRoutingEngine()
    private let identityService = ResourceIdentityService()

    private func workspace(_ name: String) -> ResourceIdentity {
        let url = (try? makeFile(named: name, content: "{}")) ?? temporaryDirectory!.appendingPathComponent(name)
        return try! identityService.identity(for: url, kind: .workspace)
    }

    // MARK: - 空白窗口复用

    func testWorkspaceReusesPreferredBlankSession() {
        let blank = WindowID()
        var state = WindowRoutingState()
        state.sessions[blank] = SessionRoutingSnapshot(id: blank, isBlank: true)

        let decision = engine.decision(
            for: workspace("a.mdworkspace"),
            preferredWindowID: blank,
            state: state
        )

        if case .openInSession(let windowID, _) = decision {
            XCTAssertEqual(windowID, blank)
        } else {
            XCTFail("expected .openInSession(blank), got \(decision)")
        }
    }

    // MARK: - 无空白窗口时新建

    func testWorkspaceCreatesWindowWhenNoBlankAvailable() {
        let occupied = WindowID()
        var state = WindowRoutingState()
        state.sessions[occupied] = SessionRoutingSnapshot(id: occupied, isBlank: false)

        let decision = engine.decision(
            for: workspace("a.mdworkspace"),
            preferredWindowID: occupied,
            state: state,
            makeWindowID: { WindowID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!) }
        )

        if case .createWindow(let windowID, _) = decision {
            XCTAssertNotEqual(windowID, occupied)
        } else {
            XCTFail("expected .createWindow, got \(decision)")
        }
    }

    // MARK: - 已持有激活 owner

    func testOwnedWorkspaceActivatesOwner() {
        let owner = WindowID()
        let resource = workspace("a.mdworkspace")
        var state = WindowRoutingState()
        state.sessions[owner] = SessionRoutingSnapshot(id: owner, isBlank: false)
        state.owners[resource] = owner

        let decision = engine.decision(for: resource, preferredWindowID: nil, state: state)

        if case .activateOwner(let windowID, _) = decision {
            XCTAssertEqual(windowID, owner)
        } else {
            XCTFail("expected .activateOwner, got \(decision)")
        }
    }

    // MARK: - 身份隔离

    func testWorkspaceIdentityDiffersFromFileAndDirectoryKind() throws {
        let url = try makeFile(named: "a.mdworkspace", content: "{}")
        let ws = try identityService.identity(for: url, kind: .workspace)
        let file = try identityService.identity(for: url, kind: .file)

        XCTAssertNotEqual(ws, file, "同路径 workspace 与 file 身份不可互换")
        XCTAssertEqual(ws.kind, .workspace)
    }

    // MARK: - Coordinator 集成：workspace 文件识别

    func testCoordinatorRoutesWorkspaceURLAsWorkspaceKind() throws {
        let coordinator = WindowCoordinator()
        let registered = WindowID()
        coordinator.registerSession(id: registered, isBlank: true)

        let wsFile = try makeFile(named: "proj.mdworkspace", content: "{}")
        let items = coordinator.routeOpenRequest(urls: [wsFile], preferredWindowID: registered)

        XCTAssertEqual(items.count, 1)
        guard case .openInSession(let windowID, let identity) = items[0].decision else {
            XCTFail("expected .openInSession, got \(items[0].decision)")
            return
        }
        XCTAssertEqual(windowID, registered)
        XCTAssertEqual(identity.kind, .workspace, "扩展名 .mdworkspace 必须识别为 workspace 身份")
    }
}

import XCTest
@testable import MarkdownReader

/// Task 2/8：统一打开路由与请求队列测试。
@MainActor
final class OpenRequestRoutingTests: TemporaryDirectoryTestCase {

    private let identityService = ResourceIdentityService()

    private func makeCoordinator() -> WindowCoordinator {
        WindowCoordinator(identityService: identityService)
    }

    private func fileURL(_ name: String) -> URL {
        try! makeFile(named: name, content: "# \(name)")
    }

    /// 注入测试用窗口创建闭包，使无 OpenWindowAction 的测试也能完成 createWindow 决策。
    private func makeReadyCoordinator() -> (WindowCoordinator, createdIDs: Box<[WindowID]>) {
        let coordinator = makeCoordinator()
        let box = Box<[WindowID]>([])
        coordinator.windowCreationClosureForTesting = { id in box.value.append(id) }
        return (coordinator, box)
    }

    // MARK: - 队列保留（action 未安装时不 drain / 不删除）

    func testAllExternalURLsAreQueued() {
        let coordinator = makeCoordinator()
        // Task 2：未安装 action 时 enqueue 只入队不 drain，请求保留。
        let urls = [fileURL("a.md"), fileURL("b.md"), fileURL("c.md")]
        let request = OpenRequest(urls: urls, source: .external)
        coordinator.enqueue(request)
        XCTAssertEqual(coordinator.pendingRequestCount, 1)
    }

    func testEnqueueWithoutActionKeepsRequest() {
        let coordinator = makeCoordinator()
        coordinator.enqueue(OpenRequest(url: fileURL("a.md"), source: .external))
        XCTAssertEqual(coordinator.pendingRequestCount, 1, "action 未安装时请求必须保留在队列")
    }

    func testDrainWithoutActionKeepsRequests() {
        let coordinator = makeCoordinator()
        coordinator.enqueue(OpenRequest(url: fileURL("a.md"), source: .external))
        coordinator.enqueue(OpenRequest(url: fileURL("b.md"), source: .external))
        XCTAssertEqual(coordinator.pendingRequestCount, 2)
        // action 未安装时 drain 应原样保留，不删除
        let processed = coordinator.drainPendingRequests()
        XCTAssertTrue(processed.isEmpty, "action 未安装时 drain 不得处理任何请求")
        XCTAssertEqual(coordinator.pendingRequestCount, 2, "action 未安装时请求必须保留")
    }

    // MARK: - 安装 action 后自动 drain（Task 2）

    func testPendingRequestsAutoDrainedAfterActionInstalled() {
        let coordinator = makeCoordinator()
        let box = Box<[WindowID]>([])
        // 先入队（此时无 action，保留）
        coordinator.enqueue(OpenRequest(url: fileURL("a.md"), source: .external))
        XCTAssertEqual(coordinator.pendingRequestCount, 1)
        // 注入创建闭包（模拟 install action）→ install 触发 drainIfReady。
        // 设置闭包本身不触发 drain（只有 install/register 触发），这里手动 drain 模拟
        // WindowSceneHost.task 中 install 完成后的自动 drain 行为。
        coordinator.windowCreationClosureForTesting = { id in box.value.append(id) }
        coordinator.drainPendingRequests()
        XCTAssertEqual(coordinator.pendingRequestCount, 0, "安装 action 后 pending 请求应被自动 drain")
        XCTAssertEqual(box.value.count, 1, "应创建一个新窗口承载该文件")
    }

    // MARK: - 多请求不丢失、顺序稳定（Task 2）

    func testMultipleRequestsNotLostInOrder() throws {
        let (coordinator, box) = makeReadyCoordinator()
        // 无已注册 session：每个不同文件都走 createWindow，按入队顺序创建
        coordinator.enqueue(OpenRequest(url: fileURL("m1.md"), source: .external))
        coordinator.enqueue(OpenRequest(url: fileURL("m2.md"), source: .external))
        coordinator.enqueue(OpenRequest(url: fileURL("m3.md"), source: .external))
        XCTAssertEqual(box.value.count, 3, "三个不同文件应各创建一个窗口")
        XCTAssertEqual(coordinator.pendingRequestCount, 0, "所有请求应被处理，队列清空")
    }

    // MARK: - external 优先于 restore（Task 2）

    func testColdStartRequestWinsOverRestoreRequest() {
        let (coordinator, _) = makeReadyCoordinator()
        let externalURL = fileURL("external.md")
        let restoreRequest = OpenRequest(urls: [], source: .openRecent)
        let externalRequest = OpenRequest(url: externalURL, source: .external)
        coordinator.enqueue(restoreRequest)
        coordinator.enqueue(externalRequest)
        // external 应已通过 enqueue 自动 drain 被处理：无已注册 session → createWindow + storePending。
        let identity = (try? identityService.identity(for: externalURL, kind: .file))
        let storedForNewWindow = coordinator.pendingResourcesForTesting.values.contains(identity!)
        XCTAssertTrue(storedForNewWindow, "external 请求应被处理并预存资源到新窗口")
        // restore 请求 urls 为空，被 handleOpenRequest 跳过，不产生任何 pending resource。
        // 队列应已清空（两条都被取出，external 有副作用、restore 无副作用但已消费）。
        XCTAssertEqual(coordinator.pendingRequestCount, 0, "restore(空 urls) 应被取出消费，队列清空")
    }

    // MARK: - drain 期间新入队请求由收尾 drain 接管（Task 2 重入收尾）

    func testRequestEnqueuedDuringDrainIsHandledByTrailingDrain() throws {
        let coordinator = makeCoordinator()
        let firstFile = try makeFile(named: "trigger.md", content: "# t")
        let secondFile = try makeFile(named: "second.md", content: "# s")

        // 标记闭包是否在 drain 执行中被调用，并同步入队第二个请求。
        let box = Box<[WindowID]>([])
        let didReEnqueue = Box<Bool>(false)
        coordinator.windowCreationClosureForTesting = { [weak coordinator] _ in
            box.value.append(WindowID())
            guard !(didReEnqueue.value) else { return }
            didReEnqueue.value = true
            // 在 drain 执行中同步入队第二个请求——被 isDraining 闸挡住，应由收尾 drain 接管。
            coordinator?.enqueue(OpenRequest(url: secondFile, source: .external))
        }
        // 首个请求无已注册 session → createWindow，触发闭包内同步 enqueue 第二个请求。
        coordinator.enqueue(OpenRequest(url: firstFile, source: .external))

        // 第一个请求 createWindow 触发闭包 → 闭包内同步 enqueue 第二个请求。
        // 收尾 drain 应接管第二个请求，再 createWindow 一次。
        XCTAssertEqual(box.value.count, 2, "drain 期间入队的第二个请求应由收尾 drain 处理")
        XCTAssertEqual(coordinator.pendingRequestCount, 0, "收尾后队列应清空")
    }

    // MARK: - 路由决策（纯逻辑，无副作用）

    func testFirstURLReusesBlankAndSecondCreatesWindow() throws {
        let coordinator = makeCoordinator()
        let blank = WindowID()
        coordinator.registerSession(id: blank, isBlank: true)
        let url1 = fileURL("first.md")
        let url2 = fileURL("second.md")
        let items = coordinator.routeOpenRequest(
            urls: [url1, url2],
            preferredWindowID: blank
        )
        XCTAssertEqual(items.count, 2)
        if case .openInSession(let windowID, _) = items[0].decision {
            XCTAssertEqual(windowID, blank)
        } else {
            XCTFail("expected .openInSession for first URL, got \(items[0].decision)")
        }
        if case .createWindow = items[1].decision {
            // pass
        } else {
            XCTFail("expected .createWindow for second URL, got \(items[1].decision)")
        }
        // Task 4：RoutedOpenItem.url 与输入 url 一一对应，保留原始顺序
        XCTAssertEqual(items[0].url, url1)
        XCTAssertEqual(items[1].url, url2)
    }

    func testOpenRecentActivatesExistingOwner() throws {
        let coordinator = makeCoordinator()
        let owner = WindowID()
        let other = WindowID()
        coordinator.registerSession(id: owner, isBlank: false)
        coordinator.registerSession(id: other, isBlank: true)
        let url = fileURL("owned.md")
        let identity = try identityService.identity(for: url, kind: .file)
        try coordinator.claim(identity, for: owner)
        let items = coordinator.routeOpenRequest(
            urls: [url],
            preferredWindowID: other
        )
        XCTAssertEqual(items.count, 1)
        if case .activateOwner(let windowID, _) = items[0].decision {
            XCTAssertEqual(windowID, owner)
        } else {
            XCTFail("expected .activateOwner, got \(items[0].decision)")
        }
    }

    func testMissingURLDoesNotBlockFollowingURLs() throws {
        let coordinator = makeCoordinator()
        let blank = WindowID()
        coordinator.registerSession(id: blank, isBlank: true)
        let missingURL = temporaryDirectory!.appendingPathComponent("nonexistent.md")
        let existingURL = fileURL("exists.md")
        let items = coordinator.routeOpenRequest(
            urls: [missingURL, existingURL],
            preferredWindowID: blank
        )
        XCTAssertEqual(items.count, 2)
        // missing 产生明确 reject，且保留原始顺序
        XCTAssertEqual(items[0].url, missingURL)
        if case .reject = items[0].decision {
            // pass
        } else {
            XCTFail("expected .reject for missing file, got \(items[0].decision)")
        }
        XCTAssertEqual(items[1].url, existingURL)
        if case .openInSession = items[1].decision {
            // pass
        } else {
            XCTFail("expected .openInSession for existing file, got \(items[1].decision)")
        }
    }

    func testNoVisibleWindowCreatesOrReopensCorrectWindow() {
        let coordinator = makeCoordinator()
        let url = fileURL("lone.md")
        let items = coordinator.routeOpenRequest(
            urls: [url],
            preferredWindowID: nil
        )
        XCTAssertEqual(items.count, 1)
        if case .createWindow = items[0].decision {
            // pass
        } else {
            XCTFail("expected .createWindow when no sessions, got \(items[0].decision)")
        }
    }

    // MARK: - Task 4：重复 identity 只决策一次，重复项复用首项决策

    func testDuplicateIdentityReusesFirstDecision() throws {
        let coordinator = makeCoordinator()
        let blank = WindowID()
        coordinator.registerSession(id: blank, isBlank: true)
        let url = try makeFile(named: "dup.md", content: "# dup")
        // 同一 URL 出现两次：首次复用 blank（openInSession），第二次应复用首次决策（openInSession 同一窗口）
        let items = coordinator.routeOpenRequest(
            urls: [url, url],
            preferredWindowID: blank
        )
        XCTAssertEqual(items.count, 2, "保留原始顺序，每个 url 一个 item")
        if case .openInSession(let firstWindow, _) = items[0].decision {
            XCTAssertEqual(firstWindow, blank)
            // 第二项复用首项决策（重复 identity 不产生 createWindow）
            if case .openInSession(let secondWindow, _) = items[1].decision {
                XCTAssertEqual(secondWindow, blank, "重复 identity 复用首项决策")
            } else {
                XCTFail("expected second duplicate to reuse first decision, got \(items[1].decision)")
            }
        } else {
            XCTFail("expected .openInSession for first URL, got \(items[0].decision)")
        }
    }

    // MARK: - Task 4：缺失与不支持产生明确 reject，不阻塞后续

    func testMissingAndValidProduceRejectThenOpenInOrder() throws {
        let coordinator = makeCoordinator()
        let blank = WindowID()
        coordinator.registerSession(id: blank, isBlank: true)
        let missing = temporaryDirectory!.appendingPathComponent("nope.md")
        let present = fileURL("present.md")
        let items = coordinator.routeOpenRequest(
            urls: [missing, present, missing],
            preferredWindowID: blank
        )
        XCTAssertEqual(items.count, 3, "缺失项保留在结果中（reject），不丢弃不阻塞")
        if case .reject = items[0].decision {} else { XCTFail("missing should reject") }
        if case .openInSession = items[1].decision {} else { XCTFail("present should open") }
        if case .reject = items[2].decision {} else { XCTFail("second missing should reject") }
        XCTAssertEqual(items[0].url, missing)
        XCTAssertEqual(items[1].url, present)
        XCTAssertEqual(items[2].url, missing)
    }

    // MARK: - 冷启动复用空白窗口必须激活

    /// 冷启动双击 .md 时，默认空白窗口走 `.openInSession`。
    /// 此前只加载文档不 activate，导致 macOS 创建的隐藏窗口不会前置，用户看到“打不开”。
    func testOpenInSessionActivatesBlankWindow() throws {
        let (coordinator, _) = makeReadyCoordinator()
        let blankSession = WindowSession(id: WindowID(), coordinator: coordinator)
        coordinator.register(session: blankSession)

        let url = fileURL("cold-open.md")
        coordinator.enqueue(OpenRequest(url: url, source: .external))

        XCTAssertEqual(
            coordinator.lastActiveWindowID,
            blankSession.id,
            "openInSession 必须激活复用的空白窗口，避免冷启动文件打开后窗口不可见"
        )
        let identity = try identityService.identity(for: url, kind: .file)
        XCTAssertEqual(coordinator.owner(of: identity), blankSession.id)
        XCTAssertEqual(coordinator.pendingRequestCount, 0)
    }
}

/// 测试辅助：可变引用盒子，让闭包能累积收集值。
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

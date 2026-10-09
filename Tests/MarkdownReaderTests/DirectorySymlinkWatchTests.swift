import XCTest
@testable import MarkdownReader

/// 使用真实 FSEvents 验证外部目录链接的自动刷新，而非手动调用 refreshDirectory。
@MainActor
final class DirectorySymlinkWatchTests: TemporaryDirectoryTestCase {
    private let defaultsSuite = "com.markdownreader.tests.symlinkWatch-\(UUID().uuidString)"

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }

    private func makeViewModel() -> FileTreeViewModel {
        let settings = SettingsModel(
            defaults: UserDefaults(suiteName: defaultsSuite)!,
            noteRecentDocument: { _ in },
            clearSystemRecentDocuments: {}
        )
        return FileTreeViewModel(settings: settings)
    }

    func testWatchRootsDeduplicateTargetsAndCoveredSubdirectories() async throws {
        let root = try makeDirectory(named: "root")
        let target = try makeDirectory(named: "target")
        let nested = target.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        // 相同前缀的不同目录不应被误判成子目录。
        let sibling = try makeDirectory(named: "target-other")
        for (name, destination) in [("a", target), ("b", target), ("nested", nested), ("sibling", sibling), ("loop", root)] {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(name), withDestinationURL: destination)
        }
        let service = FileService()
        let nodes = try await service.scanDirectory(root)
        let urls = service.directoryWatchURLs(root: root, nodes: nodes)
        XCTAssertEqual(urls.count, 3)
        XCTAssertEqual(Set(urls.map(\.lastPathComponent)), ["root", "target", "target-other"])
        for url in urls {
            XCTAssertTrue(try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        }
    }

    func testExternalTargetCreateRenameDeleteAutomaticallyRefreshTree() async throws {
        let root = try makeDirectory(named: "root")
        let target = try makeDirectory(named: "target")
        let link = root.appendingPathComponent("docs")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let viewModel = makeViewModel()
        defer { viewModel.clearDirectory() }
        await viewModel.loadDirectory(root)

        let file = try makeFile(named: "new.md", in: target, content: "# new")
        try await waitUntil { self.hasNode(link.appendingPathComponent("new.md"), in: viewModel.nodes) }
        XCTAssertFalse(viewModel.isEmptyDirectory)

        let renamed = target.appendingPathComponent("renamed.md")
        try FileManager.default.moveItem(at: file, to: renamed)
        try await waitUntil {
            self.hasNode(link.appendingPathComponent("renamed.md"), in: viewModel.nodes)
                && !self.hasNode(link.appendingPathComponent("new.md"), in: viewModel.nodes)
        }
        try FileManager.default.removeItem(at: renamed)
        try await waitUntil { !self.hasNode(link.appendingPathComponent("renamed.md"), in: viewModel.nodes) }
        XCTAssertTrue(viewModel.isEmptyDirectory)
    }

    func testNewAndRetargetedNestedLinksUpdateWatchRoots() async throws {
        let root = try makeDirectory(named: "root")
        let first = try makeDirectory(named: "first")
        let second = try makeDirectory(named: "second")
        let nested = try makeDirectory(named: "nested-target")
        let viewModel = makeViewModel()
        defer { viewModel.clearDirectory() }
        await viewModel.loadDirectory(root)

        let link = root.appendingPathComponent("docs")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        try await waitUntil { self.hasNode(link, in: viewModel.nodes) }
        try makeFile(named: "first.md", in: first, content: "# first")
        try await waitUntil { self.hasNode(link.appendingPathComponent("first.md"), in: viewModel.nodes) }

        try makeFile(named: "second.md", in: second, content: "# second")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        try await waitUntil { self.hasNode(link.appendingPathComponent("second.md"), in: viewModel.nodes) }
        XCTAssertFalse(hasNode(link.appendingPathComponent("first.md"), in: viewModel.nodes))
        try makeFile(named: "later.md", in: second, content: "# later")
        try await waitUntil { self.hasNode(link.appendingPathComponent("later.md"), in: viewModel.nodes) }

        try FileManager.default.createSymbolicLink(at: second.appendingPathComponent("nested"), withDestinationURL: nested)
        let nestedLink = link.appendingPathComponent("nested")
        try await waitUntil { self.hasNode(nestedLink, in: viewModel.nodes) }
        try makeFile(named: "deep.md", in: nested, content: "# deep")
        try await waitUntil { self.hasNode(nestedLink.appendingPathComponent("deep.md"), in: viewModel.nodes) }

        try FileManager.default.removeItem(at: link)
        try await waitUntil { !self.hasNode(link, in: viewModel.nodes) }
        let watchURLs = FileService().directoryWatchURLs(root: root, nodes: viewModel.nodes)
        XCTAssertEqual(watchURLs.count, 1)
        XCTAssertEqual(watchURLs.first?.lastPathComponent, "root")
    }

    func testReplacingAndStoppingWatchSetRemovesOldCallbacks() async throws {
        let first = try makeDirectory(named: "first")
        let second = try makeDirectory(named: "second")
        let watcher = FileSystemWatcher(debounceInterval: 0.05)
        defer { watcher.stopWatching() }
        var callbacks = 0
        watcher.startWatching(urls: [first, second]) {
            MainActor.assumeIsolated { callbacks += 1 }
        }
        try makeFile(named: "initial.md", in: first)
        try await waitUntil { callbacks > 0 }

        watcher.startWatching(urls: [second]) {
            MainActor.assumeIsolated { callbacks += 1 }
        }
        XCTAssertEqual(watcher.watchedURLs, [second.standardizedFileURL])
        try makeFile(named: "control.md", in: second)
        let beforeControl = callbacks
        try await waitUntil { callbacks > beforeControl }
        // 等待 FSEvents 批次与防抖完成，再检验已移除路径不会产生回调。
        try await Task.sleep(for: .seconds(1))
        let beforeRemoved = callbacks
        try makeFile(named: "removed.md", in: first)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(callbacks, beforeRemoved)

        watcher.stopWatching()
        XCTAssertTrue(watcher.watchedURLs.isEmpty)
        try makeFile(named: "stopped.md", in: second)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(callbacks, beforeRemoved)
    }

    func testClearDirectoryStopsAutomaticRefresh() async throws {
        let root = try makeDirectory(named: "root")
        let viewModel = makeViewModel()
        await viewModel.loadDirectory(root)
        viewModel.clearDirectory()
        XCTAssertTrue(viewModel.nodes.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
        try makeFile(named: "after-close.md", in: root)
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(viewModel.nodes.isEmpty)
    }

    private func hasNode(_ url: URL, in nodes: [FileNode]) -> Bool {
        nodes.contains { $0.path.standardizedFileURL == url.standardizedFileURL || hasNode(url, in: $0.children ?? []) }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(condition(), "未收到预期的自动刷新", file: file, line: line)
        if !condition() { throw WatchTestError.timedOut }
    }

    private enum WatchTestError: Error { case timedOut }
}

import XCTest
@testable import MarkdownReader

/// 特征测试：FileSystemWatcher 现状行为（单路径）。
///
/// 多路径改造前锁定：监控触发回调、防抖合并、stopWatching 后无残余回调。
/// FSEvents 有系统级延迟，等待窗口放宽到 5 秒。
@MainActor
final class FileSystemWatcherTests: TemporaryDirectoryTestCase {

    func testWatchingDirectoryFiresOnChangeAfterFileCreated() async throws {
        let dir = try makeDirectory(named: "watched")
        let watcher = FileSystemWatcher(debounceInterval: 0.2)

        let expectation = expectation(description: "onChange fired")
        expectation.assertForOverFulfill = false
        watcher.startWatching(url: dir) {
            expectation.fulfill()
        }

        // 稍等 stream 就绪（SinceNow 语义：只接收启动后的事件）
        try await Task.sleep(nanoseconds: 200_000_000)
        try "x".write(to: dir.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)

        await fulfillment(of: [expectation], timeout: 5.0)
        watcher.stopWatching()
    }

    func testDebouncingMergesRapidChangesIntoFewCallbacks() async throws {
        let dir = try makeDirectory(named: "watched")
        let watcher = FileSystemWatcher(debounceInterval: 0.3)

        let counter = CallbackCounter()
        watcher.startWatching(url: dir) {
            counter.increment()
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        for i in 0..<5 {
            try "\(i)".write(to: dir.appendingPathComponent("f\(i).md"), atomically: true, encoding: .utf8)
        }

        // 等待防抖窗口过去
        try await Task.sleep(nanoseconds: 1_500_000_000)
        watcher.stopWatching()

        let count = counter.value
        XCTAssertGreaterThanOrEqual(count, 1, "快速连续变更至少触发一次回调")
        XCTAssertLessThanOrEqual(count, 3, "防抖应合并快速连续变更，而不是逐事件回调")
    }

    func testStopWatchingPreventsFurtherCallbacks() async throws {
        let dir = try makeDirectory(named: "watched")
        let watcher = FileSystemWatcher(debounceInterval: 0.2)

        let counter = CallbackCounter()
        watcher.startWatching(url: dir) {
            counter.increment()
        }
        watcher.stopWatching()

        try "x".write(to: dir.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertEqual(counter.value, 0, "stopWatching 后不应再有回调")
    }

    func testRestartWithDifferentDirectorySwitchesWatchTarget() async throws {
        let dirA = try makeDirectory(named: "a")
        let dirB = try makeDirectory(named: "b")
        let watcher = FileSystemWatcher(debounceInterval: 0.2)

        let expectation = expectation(description: "onChange fired for dirB")
        expectation.assertForOverFulfill = false
        watcher.startWatching(url: dirA) { }
        watcher.startWatching(url: dirB) {
            expectation.fulfill()
        }
        XCTAssertEqual(watcher.watchedURL, dirB)

        try await Task.sleep(nanoseconds: 200_000_000)
        try "x".write(to: dirB.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)

        await fulfillment(of: [expectation], timeout: 5.0)
        watcher.stopWatching()
        XCTAssertNil(watcher.watchedURL)
    }

    // MARK: - 多路径监控（工作区多根）

    func testMultiPathWatchingFiresForAnyRoot() async throws {
        let dirA = try makeDirectory(named: "a")
        let dirB = try makeDirectory(named: "b")
        let watcher = FileSystemWatcher(debounceInterval: 0.2)

        let counter = CallbackCounter()
        watcher.startWatching(urls: [dirA, dirB]) {
            counter.increment()
        }
        XCTAssertEqual(watcher.watchedURLs, [dirA, dirB])

        try await Task.sleep(nanoseconds: 200_000_000)
        // 任一根下变更均应触发
        try "x".write(to: dirB.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertGreaterThanOrEqual(counter.value, 1, "第二根下的变更应触发回调")

        let before = counter.value
        try "y".write(to: dirA.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertGreaterThan(counter.value, before, "第一根下的变更也应触发回调")

        watcher.stopWatching()
        XCTAssertTrue(watcher.watchedURLs.isEmpty)
    }

    func testSameSetRepeatCallOnlyUpdatesCallback() async throws {
        let dirA = try makeDirectory(named: "a")
        let dirB = try makeDirectory(named: "b")
        let watcher = FileSystemWatcher(debounceInterval: 0.2)

        let firstCounter = CallbackCounter()
        let secondCounter = CallbackCounter()
        watcher.startWatching(urls: [dirA, dirB]) {
            firstCounter.increment()
        }
        // 同集合重复调用：不重启 stream，仅更新回调
        watcher.startWatching(urls: [dirB, dirA]) {
            secondCounter.increment()
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        try "x".write(to: dirA.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertEqual(firstCounter.value, 0, "旧回调不应再触发")
        XCTAssertGreaterThanOrEqual(secondCounter.value, 1, "新回调应接管后续事件")
        watcher.stopWatching()
    }
}

/// 线程安全的回调计数器（watcher 回调在主线程，但保持通用性）。
private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

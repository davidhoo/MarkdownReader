import XCTest
@testable import MarkdownReader

/// 内容区复制反馈状态测试（Task 1）。
///
/// `CopyFeedbackState` 是不含计时器、不含剪贴板 I/O 的纯值类型，仅负责
/// “某次复制是否仍处于成功反馈窗口”与“只有最新一次成功的计时能重置反馈”。
final class CopyFeedbackStateTests: XCTestCase {

    // MARK: - 首次成功

    func testInitialIsNotShowingSuccess() {
        var state = CopyFeedbackState()
        XCTAssertFalse(state.isShowingSuccess)
    }

    func testBeginShowsSuccess() {
        var state = CopyFeedbackState()
        _ = state.begin()
        XCTAssertTrue(state.isShowingSuccess)
    }

    // MARK: - 重置当前 generation

    func testResetCurrentGenerationHidesSuccess() {
        var state = CopyFeedbackState()
        let generation = state.begin()
        XCTAssertTrue(state.isShowingSuccess)

        state.reset(ifCurrent: generation)
        XCTAssertFalse(state.isShowingSuccess)
    }

    // MARK: - 重复成功

    func testRepeatBeginKeepsShowingSuccess() {
        var state = CopyFeedbackState()
        _ = state.begin()
        let second = state.begin()

        XCTAssertTrue(state.isShowingSuccess)
        XCTAssertNotEqual(second, 0)
    }

    // MARK: - 旧 generation 重置不得清掉后续成功的反馈

    func testStaleResetDoesNotClearLaterCopyFeedback() {
        var state = CopyFeedbackState()
        let first = state.begin()
        let second = state.begin()

        state.reset(ifCurrent: first)
        XCTAssertTrue(state.isShowingSuccess)

        state.reset(ifCurrent: second)
        XCTAssertFalse(state.isShowingSuccess)
    }

    // MARK: - 最新 generation 重置

    func testResetWithLatestGenerationHidesSuccess() {
        var state = CopyFeedbackState()
        _ = state.begin()
        let latest = state.begin()

        state.reset(ifCurrent: latest)
        XCTAssertFalse(state.isShowingSuccess)
    }

    // MARK: - invalidate

    func testInvalidateHidesSuccess() {
        var state = CopyFeedbackState()
        _ = state.begin()
        XCTAssertTrue(state.isShowingSuccess)

        state.invalidate()
        XCTAssertFalse(state.isShowingSuccess)
    }

    func testInvalidateAfterResetStaysHidden() {
        var state = CopyFeedbackState()
        let generation = state.begin()
        state.reset(ifCurrent: generation)
        XCTAssertFalse(state.isShowingSuccess)

        state.invalidate()
        XCTAssertFalse(state.isShowingSuccess)
    }

    func testResetAfterInvalidateDoesNotReviveStaleGeneration() {
        var state = CopyFeedbackState()
        let first = state.begin()
        state.invalidate()
        XCTAssertFalse(state.isShowingSuccess)

        // invalidate 后旧 generation 的 reset 不得重新触发成功态
        state.reset(ifCurrent: first)
        XCTAssertFalse(state.isShowingSuccess)
    }
}

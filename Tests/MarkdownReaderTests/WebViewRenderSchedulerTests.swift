import XCTest
@testable import MarkdownReader
import MarkdownReaderKit

/// WebView 渲染触发收敛的纯策略与世代调度测试。
///
/// 验证两点不变式：
/// 1. `WebViewRenderPolicy` 依据文件身份、内容、强制刷新世代选择正确的渲染动作，
///    与 SwiftUI/WebKit 无关；
/// 2. `WebViewRenderScheduler` 的 latest-wins 世代保证：新请求使所有更早的请求失效。
final class WebViewRenderSchedulerTests: XCTestCase {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    private func snapshot(_ name: String, content: String, version: Int) -> WebViewRenderSnapshot {
        WebViewRenderSnapshot(fileURL: url(name), content: content, contentVersion: version)
    }

    private typealias MarkdownRuntimeRequirements = MarkdownHTMLService.MarkdownRuntimeRequirements

    // MARK: - 策略：渲染动作

    func testInitialSnapshotLoadsFullPage() {
        let snapshot = WebViewRenderSnapshot(
            fileURL: url("a.md"), content: "# A", contentVersion: 1
        )

        XCTAssertEqual(
            WebViewRenderPolicy.action(previous: nil, next: snapshot),
            .loadPage
        )
    }

    func testContentOnlyChangeUsesIncrementalReplacement() {
        let previous = WebViewRenderSnapshot(
            fileURL: url("a.md"), content: "# A", contentVersion: 1
        )
        let next = WebViewRenderSnapshot(
            fileURL: url("a.md"), content: "# A changed", contentVersion: 1
        )

        XCTAssertEqual(
            WebViewRenderPolicy.action(previous: previous, next: next),
            .replaceContent
        )
    }

    func testFileURLChangeTriggersFullPageLoad() {
        let previous = WebViewRenderSnapshot(
            fileURL: url("a.md"), content: "# A", contentVersion: 1
        )
        let next = WebViewRenderSnapshot(
            fileURL: url("b.md"), content: "# A", contentVersion: 1
        )

        XCTAssertEqual(
            WebViewRenderPolicy.action(previous: previous, next: next),
            .loadPage
        )
    }

    func testContentVersionChangeTriggersFullPageLoad() {
        let previous = WebViewRenderSnapshot(
            fileURL: url("a.md"), content: "# A", contentVersion: 1
        )
        let next = WebViewRenderSnapshot(
            fileURL: url("a.md"), content: "# A", contentVersion: 2
        )

        XCTAssertEqual(
            WebViewRenderPolicy.action(previous: previous, next: next),
            .loadPage
        )
    }

    func testIdenticalSnapshotIsNoOp() {
        let previous = WebViewRenderSnapshot(
            fileURL: url("a.md"), content: "# A", contentVersion: 1
        )
        let next = WebViewRenderSnapshot(
            fileURL: url("a.md"), content: "# A", contentVersion: 1
        )

        XCTAssertEqual(
            WebViewRenderPolicy.action(previous: previous, next: next),
            .none
        )
    }

    // MARK: - 世代：latest-wins

    func testNewestRequestInvalidatesAllEarlierRequests() {
        var scheduler = WebViewRenderScheduler()
        let fileChange = scheduler.request()
        let contentChange = scheduler.request()
        let versionChange = scheduler.request()

        XCTAssertFalse(scheduler.accepts(fileChange))
        XCTAssertFalse(scheduler.accepts(contentChange))
        XCTAssertTrue(scheduler.accepts(versionChange))
    }

    func testInitialGenerationIsZero() {
        var scheduler = WebViewRenderScheduler()
        XCTAssertEqual(scheduler.generation, 0)
        // 未发起任何请求时，generation 0 不应被任何后续 request 复用为有效世代。
        let first = scheduler.request()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(scheduler.generation, 1)
    }

    // MARK: - 运行时升级策略：可选运行时需求变化必须整页加载

    func testUnchangedRuntimeRequirementsKeepIncrementalReplacement() {
        let plain = MarkdownRuntimeRequirements(requiresMermaid: false, requiresKaTeX: false)
        XCTAssertEqual(WebViewRuntimePolicy.action(current: plain, next: plain), .replaceContent)
    }

    func testAddingKaTeXPromotesReplacementToFullPageLoad() {
        let plain = MarkdownRuntimeRequirements(requiresMermaid: false, requiresKaTeX: false)
        let math = MarkdownRuntimeRequirements(requiresMermaid: false, requiresKaTeX: true)
        XCTAssertEqual(WebViewRuntimePolicy.action(current: plain, next: math), .loadPage)
    }

    func testRemovingMermaidPromotesReplacementToFullPageLoad() {
        let mermaid = MarkdownRuntimeRequirements(requiresMermaid: true, requiresKaTeX: false)
        let plain = MarkdownRuntimeRequirements(requiresMermaid: false, requiresKaTeX: false)
        XCTAssertEqual(WebViewRuntimePolicy.action(current: mermaid, next: plain), .loadPage)
    }

    func testNilCurrentRequirementsForcesFullPageLoad() {
        let next = MarkdownRuntimeRequirements(requiresMermaid: false, requiresKaTeX: false)
        XCTAssertEqual(WebViewRuntimePolicy.action(current: nil, next: next), .loadPage)
    }

    // MARK: - 渲染模式过渡状态机

    func testRenderedTransitionWaitsForRequestedGeneration() {
        var transition = RenderedModeTransitionState()
        transition.begin()
        transition.track(generation: 8)

        XCTAssertTrue(transition.keepsRawVisible)
        XCTAssertFalse(transition.completeIfMatching(generation: 7))
        XCTAssertTrue(transition.keepsRawVisible)
        XCTAssertTrue(transition.completeIfMatching(generation: 8))
        XCTAssertFalse(transition.keepsRawVisible)
    }

    func testNewTransitionInvalidatesOlderCompletion() {
        var transition = RenderedModeTransitionState()
        transition.begin()
        transition.track(generation: 4)
        transition.track(generation: 5)

        XCTAssertFalse(transition.completeIfMatching(generation: 4))
        XCTAssertTrue(transition.completeIfMatching(generation: 5))
    }
}

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
       // 世代完成但 transfer 未回执：过渡不结束
       XCTAssertFalse(transition.completeIfMatching(generation: 8))
       XCTAssertTrue(transition.keepsRawVisible)
       // transfer 回执后过渡结束
       transition.acknowledgeTransfer()
       XCTAssertFalse(transition.keepsRawVisible)
   }

   func testNewTransitionInvalidatesOlderCompletion() {
       var transition = RenderedModeTransitionState()
       transition.begin()
       transition.track(generation: 4)
       transition.track(generation: 5)

       XCTAssertFalse(transition.completeIfMatching(generation: 4))
       // 世代 5 完成但 transfer 未回执：过渡不结束
       XCTAssertFalse(transition.completeIfMatching(generation: 5))
       XCTAssertTrue(transition.keepsRawVisible)
       transition.acknowledgeTransfer()
       XCTAssertFalse(transition.keepsRawVisible)
   }

    // MARK: - 渲染闸门：Raw 编辑期不触发隐藏 WebView 重渲染

    func testRawContentEditDoesNotRequestWebViewRender() {
        XCTAssertFalse(WebViewRenderEligibility.shouldRequest(
            change: .content, isRenderedMode: false
        ))
    }

    func testFileAndForcedRefreshStillPrewarmWhileRaw() {
        XCTAssertTrue(WebViewRenderEligibility.shouldRequest(
            change: .fileURL, isRenderedMode: false
        ))
        XCTAssertTrue(WebViewRenderEligibility.shouldRequest(
            change: .contentVersion, isRenderedMode: false
        ))
    }

    func testEnteringRenderedModeRequestsLatestContent() {
        XCTAssertTrue(WebViewRenderEligibility.shouldRequest(
            change: .displayMode, isRenderedMode: true
        ))
    }

    func testRenderedContentEditRequestsWebViewRender() {
        XCTAssertTrue(WebViewRenderEligibility.shouldRequest(
            change: .content, isRenderedMode: true
        ))
    }

    func testReturningToRawModeDoesNotRequestWebViewRender() {
        XCTAssertFalse(WebViewRenderEligibility.shouldRequest(
            change: .displayMode, isRenderedMode: false
        ))
    }

    // MARK: - 内容替换完成判定：显式 Boolean 回执

    func testReplacementCompletionRequiresTrueJavaScriptAcknowledgement() {
        XCTAssertTrue(WebViewContentReplacementCompletionPolicy.shouldComplete(
            javaScriptResult: true, isCurrentGeneration: true
        ))
    }

    func testReplacementCompletionRejectsFalseNilAndUnexpectedResult() {
        XCTAssertFalse(WebViewContentReplacementCompletionPolicy.shouldComplete(
            javaScriptResult: false, isCurrentGeneration: true
        ))
        XCTAssertFalse(WebViewContentReplacementCompletionPolicy.shouldComplete(
            javaScriptResult: nil, isCurrentGeneration: true
        ))
        XCTAssertFalse(WebViewContentReplacementCompletionPolicy.shouldComplete(
            javaScriptResult: "true", isCurrentGeneration: true
        ))
    }

    func testReplacementCompletionRejectsSuccessfulButStaleGeneration() {
        XCTAssertFalse(WebViewContentReplacementCompletionPolicy.shouldComplete(
            javaScriptResult: true, isCurrentGeneration: false
        ))
    }

    // MARK: - 失败退出出口（T2）

    func testFailureIfMatchingResetsTransition() {
        var transition = RenderedModeTransitionState()
        transition.begin()
        transition.track(generation: 3)
        XCTAssertTrue(transition.keepsRawVisible)

        // 世代不匹配时不上报失败
        XCTAssertFalse(transition.failIfMatching(generation: 2))
        XCTAssertTrue(transition.keepsRawVisible)

        // 世代匹配时重置过渡
        XCTAssertTrue(transition.failIfMatching(generation: 3))
        XCTAssertFalse(transition.keepsRawVisible)
    }

    func testFailTransferResetsTransition() {
        var transition = RenderedModeTransitionState()
        let transferId = UUID()
        transition.begin(generation: 3, transferId: transferId)
        XCTAssertTrue(transition.keepsRawVisible)

        // 不匹配的旧/异构 ID 不能取消过渡
        let wrongId = UUID()
        XCTAssertFalse(transition.failTransferIfMatching(id: wrongId))
        XCTAssertTrue(transition.keepsRawVisible)

        // 匹配当前交接 ID 才能重置过渡
        XCTAssertTrue(transition.failTransferIfMatching(id: transferId))
        XCTAssertFalse(transition.keepsRawVisible)
    }

    func testExpiredScrollTransferFailureDoesNotRevertNewTransition() {
        var transition = RenderedModeTransitionState()
        let oldTransferId = UUID()
        transition.begin(generation: 1, transferId: oldTransferId)

        // 用户快速进行新的一轮切换，开启新世代和新交接 ID
        let newTransferId = UUID()
        transition.begin(generation: 2, transferId: newTransferId)
        XCTAssertTrue(transition.keepsRawVisible)

        // 上一轮超时的旧失败回调迟到到达
        let oldFailed = transition.failTransferIfMatching(id: oldTransferId)
        XCTAssertFalse(oldFailed, "旧交接超时失败不得打断当前进行中的新过渡")
        XCTAssertTrue(transition.keepsRawVisible, "当前过渡状态必须得到保护")

        // 新交接的正常完成应成功闭合过渡
        transition.acknowledgeTransfer(id: newTransferId)
        XCTAssertTrue(transition.completeIfMatching(generation: 2))
        XCTAssertFalse(transition.keepsRawVisible)
    }

    func testFailureBeforeTransferIdIsBoundDoesNotCancelTransition() {
        var transition = RenderedModeTransitionState()
        transition.begin()
        transition.track(generation: 4)
        XCTAssertNil(transition.targetTransferId)

        XCTAssertFalse(transition.failTransferIfMatching(id: UUID()))
        XCTAssertTrue(transition.keepsRawVisible, "交接 ID 尚未绑定时，任何失败都不能结束过渡")
    }

    // MARK: - 渲染就绪评估策略

    func testReadinessPolicyEvaluatesReadyStatus() {
        let readyResult: [String: Any] = ["ready": true]
        XCTAssertEqual(WebViewRenderReadinessPolicy.evaluate(result: readyResult), .ready)
    }

    func testReadinessPolicyEvaluatesMissingMR() {
        let missingMRResult: [String: Any] = ["ready": false, "reason": "missing_mr"]
        XCTAssertEqual(WebViewRenderReadinessPolicy.evaluate(result: missingMRResult), .notReady(reason: "missing_mr"))
    }

    func testReadinessPolicyEvaluatesMissingCSS() {
        let missingCSSResult: [String: Any] = ["ready": false, "reason": "missing_css_font"]
        XCTAssertEqual(WebViewRenderReadinessPolicy.evaluate(result: missingCSSResult), .notReady(reason: "missing_css_font"))

        let missingPaddingResult: [String: Any] = ["ready": false, "reason": "missing_css_padding"]
        XCTAssertEqual(WebViewRenderReadinessPolicy.evaluate(result: missingPaddingResult), .notReady(reason: "missing_css_padding"))
    }

    func testReadinessPolicyRejectsInvalidResponse() {
        XCTAssertEqual(WebViewRenderReadinessPolicy.evaluate(result: nil), .notReady(reason: "invalid_response"))
        XCTAssertEqual(WebViewRenderReadinessPolicy.evaluate(result: "invalid"), .notReady(reason: "invalid_response"))
        XCTAssertEqual(WebViewRenderReadinessPolicy.evaluate(result: [:]), .notReady(reason: "unknown"))
    }
}

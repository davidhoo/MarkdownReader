import XCTest
import AppKit
import SwiftUI
import JavaScriptCore
@testable import MarkdownReaderKit
@testable import MarkdownReader

/// 渲染与编辑源码位置一致性测试。
///
/// 固定契约：所有跨层、跨模式的 Markdown 源码行号统一为 1-based `SourceLine`。
/// 仅在 Raw 编辑器字符偏移计算边界转换为 0-based 行索引；HTML `data-line` 与
/// JavaScript `MR.scrollToLine` 保持既有 1-based 协议。
final class SourcePositionSyncTests: XCTestCase {

    // MARK: - Rendered JavaScript 源码锚点采样

    /// 大纲顶部对齐会使视口顶部落在「前一块结束」与「下一标题开始」之间的 CSS 留白。
    /// 此时锚点必须在相邻源码范围间插值；绝不能落到整篇文档最后一个块的末行，
    /// 否则 Rendered → Raw 会先显示旧位置、随后被异步交接拉到文末。
    func testRenderedAnchorCaptureInterpolatesViewportGapInsteadOfUsingLastBlock() throws {
        let context = try makeMarkdownReaderJavaScriptContext(
            scrollTop: 188,
            blocks: [
                (start: 1, end: 3, top: 0, bottom: 160),
                (start: 5, end: 5, top: 200, bottom: 230),
                (start: 100, end: 103, top: 5_000, bottom: 5_200)
            ]
        )

        let sourcePosition = try XCTUnwrap(
            context.evaluateScript("MR.captureSourceScrollAnchor().sourcePosition")
        ).toDouble()

        // 前一块 source 末行 = 3，间隙源码范围为 4...5；
        // 视口顶端在视觉间隙的 70% 处，故 sourcePosition = 4.7。
        XCTAssertEqual(sourcePosition, 4.7, accuracy: 0.0001)
    }

    // MARK: - SourceLine 值类型

    func testSourceLinePreservesOneBasedAndZeroBasedBoundary() {
        let first = SourceLine(oneBased: 1)
        let fourth = SourceLine(zeroBasedIndex: 3)

        XCTAssertEqual(first.oneBased, 1)
        XCTAssertEqual(first.zeroBasedIndex, 0)
        XCTAssertEqual(fourth.oneBased, 4)
        XCTAssertEqual(fourth.zeroBasedIndex, 3)
    }

    // MARK: - 大纲：ATX 与 Setext 均 1-based

    func testOutlineUsesOneBasedSourceLines() {
        let items = OutlineService.parse("# First\n\n## Second")

        XCTAssertEqual(items.map(\.sourceLine.oneBased), [1, 3])
    }

    func testOutlineSetextHeadingUsesOneBasedSourceLine() {
        // 行：1 Title / 2 ===== / 3 空 / 4 Para / 5 空 / 6 Sub / 7 ---
        let items = OutlineService.parse("Title\n=====\n\nPara\n\nSub\n---")

        XCTAssertEqual(items.map(\.sourceLine.oneBased), [1, 6])
        XCTAssertEqual(items.map(\.level), [1, 2])
    }

    // MARK: - 渲染标题位置：正向断言（HeadingInfo.sourceLine 与 data-line）

    func testRenderedHeadingExposesOneBasedSourceLineAndDataLine() {
        let result = MarkdownHTMLService.render("# Title")

        XCTAssertEqual(result.headings.first?.sourceLine?.oneBased, 1)
        XCTAssertTrue(result.html.contains(#"data-line="1""#))
    }

    // MARK: - 查找匹配：1-based 源码行

    @MainActor
    func testFindMatchExposesOneBasedSourceLine() {
        let viewModel = FindReplaceViewModel()
        viewModel.searchText = "needle"
        viewModel.performSearch(in: "first\nneedle")

        XCTAssertEqual(viewModel.currentMatchSourceLine?.oneBased, 2)
    }

    // MARK: - 模式切换：双向 source anchor

    @MainActor
    func testRawToRenderedModeSwitchDoesNotPublishLegacyLineRequest() {
        let viewModel = DocumentViewModel()
        viewModel.displayMode = .raw
        viewModel.rawVisibleSourceLine = SourceLine(oneBased: 18)

        viewModel.switchDisplayMode(.rendered)

        XCTAssertEqual(viewModel.displayMode, .rendered)
        XCTAssertNil(viewModel.scrollToSourceLineRequest)
    }

    @MainActor
    func testRenderedToRawModeSwitchCancelsPendingLegacyLineRequest() {
        let viewModel = DocumentViewModel()
        viewModel.displayMode = .rendered
        viewModel.requestScroll(to: SourceLine(oneBased: 1))

        viewModel.switchDisplayMode(.raw)

        XCTAssertEqual(viewModel.displayMode, .raw)
        XCTAssertNil(viewModel.scrollToSourceLineRequest)
    }

    /// 显式按行跳转（大纲/查找/标题）不经过模式切换，必须保留传入的 1-based SourceLine，
    /// 直到既有消费者清除。证明本修复未夺走显式跳转能力。
    @MainActor
    func testExplicitRequestScrollRetainsLineUntilCleared() {
        let viewModel = DocumentViewModel()
        viewModel.requestScroll(to: SourceLine(oneBased: 42))

        XCTAssertEqual(viewModel.scrollToSourceLineRequest?.sourceLine.oneBased, 42)
        XCTAssertEqual(viewModel.scrollToSourceLineRequest?.placement, .reveal)

        viewModel.clearScrollRequest()
        XCTAssertNil(viewModel.scrollToSourceLineRequest)
    }

    // MARK: - 渲染视图按行跳转桥接参数

    /// 大纲顶部落点携带常量 12pt CSS 像素边距，不随 zoom 缩放：CSS `zoom` 已缩放布局，
    /// `getBoundingClientRect`/`scrollY` 同处缩放后坐标系，视觉边距直接用 12。
    @MainActor
    func testRenderedOutlineBridgeUsesConstantTopMargin() {
        let request = DocumentViewModel.SourceScrollRequest(
            id: UUID(),
            sourceLine: SourceLine(oneBased: 24),
            placement: .outlineTop
        )

        let arguments = RenderedLineNavigationBridge.arguments(for: request, zoomLevel: 2)

        XCTAssertEqual(arguments.lineNumber, 24)
        XCTAssertEqual(arguments.placement, .outlineTop)
        // 无论 zoom，视觉边距恒为 12 缩放后 CSS 像素。
        XCTAssertEqual(arguments.topMarginCSSPixels, 12, accuracy: 0.001)
    }

    /// 查找落点不携带顶部边距，继续走既有居中策略。
    @MainActor
    func testRenderedRevealBridgeCarriesNoTopMargin() {
        let request = DocumentViewModel.SourceScrollRequest(
            id: UUID(),
            sourceLine: SourceLine(oneBased: 24),
            placement: .reveal
        )

        let arguments = RenderedLineNavigationBridge.arguments(for: request, zoomLevel: 1.5)

        XCTAssertEqual(arguments.placement, .reveal)
        XCTAssertEqual(arguments.topMarginCSSPixels, 0, accuracy: 0.001)
    }

    // MARK: - 大纲跳转落点策略（.outlineTop）与请求身份

    /// 大纲点击发布 `.outlineTop` 请求，携带目标源码行与统一顶部对齐落点。
    @MainActor
    func testOutlineScrollRequestCarriesTopAlignment() {
        let viewModel = DocumentViewModel()

        viewModel.requestOutlineScroll(to: SourceLine(oneBased: 24))

        XCTAssertEqual(viewModel.scrollToSourceLineRequest?.sourceLine.oneBased, 24)
        XCTAssertEqual(viewModel.scrollToSourceLineRequest?.placement, .outlineTop)
    }

    /// 查找等既有显式跳转仍走 `.reveal`，落点策略不被大纲改动牵连。
    @MainActor
    func testFindScrollRequestKeepsRevealPlacement() {
        let viewModel = DocumentViewModel()

        viewModel.requestScroll(to: SourceLine(oneBased: 24))

        XCTAssertEqual(viewModel.scrollToSourceLineRequest?.placement, .reveal)
    }

    /// 连续点击同一个大纲标题也必须带新请求身份，强制目的视图重新触发定位。
    @MainActor
    func testRepeatedOutlineSelectionGetsNewRequestIdentity() {
        let viewModel = DocumentViewModel()
        viewModel.requestOutlineScroll(to: SourceLine(oneBased: 24))
        let firstID = try! XCTUnwrap(viewModel.scrollToSourceLineRequest?.id)

        viewModel.requestOutlineScroll(to: SourceLine(oneBased: 24))

        XCTAssertNotEqual(viewModel.scrollToSourceLineRequest?.id, firstID)
    }

    /// 保护性测试：`.reveal` 与 `.outlineTop` 共享同一 1-based `SourceLine` 协议，
    /// 避免行号被改回裸 `Int`。
    @MainActor
    func testScrollPlacementsShareOneBasedSourceLineProtocol() {
        let reveal = DocumentViewModel.SourceScrollRequest(
            id: UUID(),
            sourceLine: SourceLine(oneBased: 7),
            placement: .reveal
        )
        let outlineTop = DocumentViewModel.SourceScrollRequest(
            id: UUID(),
            sourceLine: SourceLine(oneBased: 9),
            placement: .outlineTop
        )

        XCTAssertEqual(reveal.sourceLine.oneBased, 7)
        XCTAssertEqual(outlineTop.sourceLine.oneBased, 9)
        XCTAssertEqual(reveal.placement, .reveal)
        XCTAssertEqual(outlineTop.placement, .outlineTop)
    }

    @MainActor
    func testSameModeSwitchDoesNotProduceScrollRequest() {
        let viewModel = DocumentViewModel()
        viewModel.displayMode = .raw
        viewModel.clearScrollRequest()

        viewModel.switchDisplayMode(.raw)

        XCTAssertNil(viewModel.scrollToSourceLineRequest)
    }

    /// 组合序列回归：旧显式请求存在 → 切 Rendered→Raw 清掉旧请求 →
    /// `beginScrollTransfer` 仍活着 → 正确 `.raw` 回执后交接清空、请求仍为 nil。
    /// 守住「交接完成后不会被旧请求 replay 覆盖」这一目标不变式。
    @MainActor
    func testRenderedToRawTransferHasNoLegacyRequestToReplayAfterAcknowledgement() {
        let viewModel = DocumentViewModel()
        viewModel.displayMode = .rendered
        viewModel.requestScroll(to: .first)

        viewModel.switchDisplayMode(.raw)
        let transfer = viewModel.beginScrollTransfer(
            destination: .raw,
            anchor: SourceScrollAnchor(sourcePosition: 42.4, documentProgress: 0.58)
        )

        XCTAssertNil(viewModel.scrollToSourceLineRequest)
        XCTAssertEqual(viewModel.scrollTransfer?.id, transfer.id)

        viewModel.acknowledgeScrollTransfer(
            id: transfer.id,
            destination: .raw,
            contentVersion: transfer.contentVersion
        )
        XCTAssertNil(viewModel.scrollTransfer)
        XCTAssertNil(viewModel.scrollToSourceLineRequest)
    }

    // MARK: - 渲染视图显式请求 pending 取消策略（RenderedExplicitScrollRequestPolicy）

    /// pending 请求在请求被取消（currentRequest == nil）后必须丢弃，
    /// 即便仍处于 Rendered 模式、页面已加载完成也不执行。
    @MainActor
    func testRenderedPendingRequestIsDiscardedAfterCancellation() {
        let request = DocumentViewModel.SourceScrollRequest(
            id: UUID(), sourceLine: SourceLine(oneBased: 42), placement: .outlineTop
        )

        XCTAssertFalse(RenderedExplicitScrollRequestPolicy.shouldApplyPending(
            pendingRequest: request,
            currentRequest: nil,
            isRenderedMode: true,
            isLoading: false
        ))
    }

    /// pending 请求执行须同时满足：pending ID 仍是当前请求、当前为 Rendered 模式、
    /// 页面不在加载中。任一条件不满足均丢弃。
    @MainActor
    func testRenderedPendingRequestRequiresCurrentRequestAndRenderedMode() {
        let request = DocumentViewModel.SourceScrollRequest(
            id: UUID(), sourceLine: SourceLine(oneBased: 42), placement: .outlineTop
        )

        XCTAssertTrue(RenderedExplicitScrollRequestPolicy.shouldApplyPending(
            pendingRequest: request,
            currentRequest: request,
            isRenderedMode: true,
            isLoading: false
        ))
        // 非 Rendered 模式：隐藏 WebView 不得执行定位。
        XCTAssertFalse(RenderedExplicitScrollRequestPolicy.shouldApplyPending(
            pendingRequest: request,
            currentRequest: request,
            isRenderedMode: false,
            isLoading: false
        ))
    }

    /// 页面仍在加载时不得立即执行 pending；待加载结束后由调用方再次校验。
    @MainActor
    func testRenderedPendingRequestDeferredWhileLoading() {
        let request = DocumentViewModel.SourceScrollRequest(
            id: UUID(), sourceLine: SourceLine(oneBased: 42), placement: .outlineTop
        )

        XCTAssertFalse(RenderedExplicitScrollRequestPolicy.shouldApplyPending(
            pendingRequest: request,
            currentRequest: request,
            isRenderedMode: true,
            isLoading: true
        ))
    }

    /// 请求被新请求替换：pending 旧 UUID 不得执行，避免隐藏 WebView 的延迟旧定位
    /// 覆盖模式切换后的锚点位置。
    @MainActor
    func testRenderedPendingRequestDiscardedWhenReplacedByNewRequest() {
        let old = DocumentViewModel.SourceScrollRequest(
            id: UUID(), sourceLine: SourceLine(oneBased: 42), placement: .outlineTop
        )
        let replacement = DocumentViewModel.SourceScrollRequest(
            id: UUID(), sourceLine: SourceLine(oneBased: 57), placement: .outlineTop
        )

        XCTAssertFalse(RenderedExplicitScrollRequestPolicy.shouldApplyPending(
            pendingRequest: old,
            currentRequest: replacement,
            isRenderedMode: true,
            isLoading: false
        ))
    }

    // MARK: - SourceScrollAnchor：模式切换的小数源码位置合同

    func testSourceScrollAnchorPreservesFractionalSourcePosition() {
        let anchor = SourceScrollAnchor(sourcePosition: 18.4, documentProgress: 0.63)

        XCTAssertEqual(anchor.sourcePosition, 18.4, accuracy: 0.0001)
        XCTAssertEqual(anchor.documentProgress, 0.63, accuracy: 0.0001)
    }

    func testSourceScrollAnchorClampsDocumentProgressToUnitRange() {
        // 进度采用钳制策略：超出 0...1 的输入不得崩溃，也不得保留越界值。
        let above = SourceScrollAnchor(sourcePosition: 5, documentProgress: 1.5)
        let below = SourceScrollAnchor(sourcePosition: 5, documentProgress: -0.4)

        XCTAssertEqual(above.documentProgress, 1.0, accuracy: 0.0001)
        XCTAssertEqual(below.documentProgress, 0.0, accuracy: 0.0001)
    }

    @MainActor
    func testScrollTransferCanOnlyBeAcknowledgedByItsDestinationAndID() {
        let viewModel = DocumentViewModel()
        let transfer = viewModel.beginScrollTransfer(
            destination: .rendered,
            anchor: SourceScrollAnchor(sourcePosition: 18.4, documentProgress: 0.63)
        )

        // 目的模式不匹配：不得清除当前请求。
        viewModel.acknowledgeScrollTransfer(
            id: transfer.id, destination: .raw, contentVersion: transfer.contentVersion
        )
        XCTAssertEqual(viewModel.scrollTransfer?.id, transfer.id)

        // 目的模式匹配且 id、contentVersion 匹配：清除请求。
        viewModel.acknowledgeScrollTransfer(
            id: transfer.id, destination: .rendered, contentVersion: transfer.contentVersion
        )
        XCTAssertNil(viewModel.scrollTransfer)
    }

    @MainActor
    func testScrollTransferWrongIDDoesNotClearCurrentRequest() {
        let viewModel = DocumentViewModel()
        let transfer = viewModel.beginScrollTransfer(
            destination: .rendered,
            anchor: SourceScrollAnchor(sourcePosition: 18.4, documentProgress: 0.63)
        )

        // 错误 UUID：不得清除当前请求。
        viewModel.acknowledgeScrollTransfer(
            id: UUID(), destination: .rendered, contentVersion: transfer.contentVersion
        )
        XCTAssertEqual(viewModel.scrollTransfer?.id, transfer.id)
    }

    @MainActor
    func testScrollTransferWrongContentVersionDoesNotClearCurrentRequest() {
        let viewModel = DocumentViewModel()
        let transfer = viewModel.beginScrollTransfer(
            destination: .rendered,
            anchor: SourceScrollAnchor(sourcePosition: 18.4, documentProgress: 0.63)
        )

        // 错误 contentVersion（模拟内容版本改变后旧回执）：不得清除当前请求。
        viewModel.acknowledgeScrollTransfer(
            id: transfer.id, destination: .rendered, contentVersion: transfer.contentVersion + 1
        )
        XCTAssertEqual(viewModel.scrollTransfer?.id, transfer.id)

        // 正确 contentVersion：清除请求。
        viewModel.acknowledgeScrollTransfer(
            id: transfer.id, destination: .rendered, contentVersion: transfer.contentVersion
        )
        XCTAssertNil(viewModel.scrollTransfer)
    }

    // MARK: - 渲染块完整源码范围：data-source-start / data-source-end

    /// 多行段落、列表与围栏代码块必须暴露**完整源码闭区间**，而非仅起始行。
    /// 结束行按 cmark `Markup.range` 的实际上界计算；上界位于下一行第 1 列时回退一行。
    func testRenderedBlocksExposeInclusiveSourceRanges() {
        // 行号布局：
        //  1 # Title
        //  2 (空)
        //  3 first paragraph line
        //  4 second paragraph line
        //  5 (空)
        //  6 - first item
        //  7 - second item
        //  8 (空)
        //  9 ```swift
        // 10 let value = 1
        // 11 ```
        let markdown = """
        # Title

        first paragraph line
        second paragraph line

        - first item
        - second item

        ```swift
        let value = 1
        ```
        """

        let html = MarkdownHTMLService.render(markdown).html

        // 多行段落：第 3–4 行（cmark upper 4:22，column>1 不回退）。data-line 保留既有行为。
        XCTAssertTrue(html.contains(#"<p data-line="3" data-source-start="3" data-source-end="4">"#),
                      "多行段落须暴露完整闭区间 3...4，实际：\n\(html)")
        // 围栏代码块：cmark range upper 11:4（含闭合围栏行），column>1 不回退 → end=11。
        XCTAssertTrue(html.contains(#"<pre data-line="9" data-source-start="9" data-source-end="11">"#),
                      "围栏代码块须暴露完整闭区间 9...11，实际：\n\(html)")
        // 列表容器：upper 8:1（下一行第 1 列）回退一行 → end=7。
        XCTAssertTrue(html.contains(#"<ul data-line="6" data-source-start="6" data-source-end="7">"#),
                      "无序列表须暴露闭区间 6...7，实际：\n\(html)")
    }

    /// 单行块同样输出范围（start == end），使半开映射 `[start, end+1)` 有非零跨度。
    func testSingleLineBlockExposesEqualStartAndEnd() {
        let html = MarkdownHTMLService.render("# Solo").html
        XCTAssertTrue(html.contains(#"<h1 id="heading-1" data-line="1" data-source-start="1" data-source-end="1">"#),
                      "单行标题须暴露 start==end，实际：\n\(html)")
    }

    /// 无可信 range 的元素不得输出 data-source-start/end，也不得制造第 0 行伪锚点。
    func testElementWithoutRangeOmitsSourceRangeAttributes() {
        // 纯 inline HTML block 无 cmark range：不应附带 data-source-* 属性。
        let html = MarkdownHTMLService.render("<div>raw</div>").html
        XCTAssertFalse(html.contains("data-source-start=\"0\""),
                       "无 range 元素不得输出第 0 行伪锚点：\n\(html)")
    }

    // MARK: - SourceAnchorResolution：模式切换定位策略

    /// 可解析源码位置时优先用精确小数位置，不退回全文进度兜底。
    func testSourceAnchorUsesExactPositionBeforeDocumentProgressFallback() {
        let anchor = SourceScrollAnchor(sourcePosition: 18.4, documentProgress: 0.63)
        XCTAssertEqual(SourceAnchorResolution.mode(for: anchor, canResolveSourcePosition: true), .sourcePosition)
        XCTAssertEqual(SourceAnchorResolution.mode(for: anchor, canResolveSourcePosition: false), .documentProgress)
    }

    /// sourcePosition 恰为整数（视口恰停在某行首）仍属可解析，走 .sourcePosition 而非兜底。
    func testSourceAnchorIntegerPositionStillResolvesAsSourcePosition() {
        let anchor = SourceScrollAnchor(sourcePosition: 18.0, documentProgress: 0.5)
        XCTAssertEqual(SourceAnchorResolution.mode(for: anchor, canResolveSourcePosition: true), .sourcePosition)
    }

    /// documentProgress 为 0 或 1 的边界仍正常映射为 .documentProgress。
    func testSourceAnchorDocumentProgressBoundariesResolveAsProgress() {
        let top = SourceScrollAnchor(sourcePosition: 1.0, documentProgress: 0.0)
        let bottom = SourceScrollAnchor(sourcePosition: 100.0, documentProgress: 1.0)
        XCTAssertEqual(SourceAnchorResolution.mode(for: top, canResolveSourcePosition: false), .documentProgress)
        XCTAssertEqual(SourceAnchorResolution.mode(for: bottom, canResolveSourcePosition: false), .documentProgress)
    }

    // MARK: - Raw 字符偏移：UTF-16 边界

    func testRawSourceLineOffsetCharacterOffsetForAscii() {
        // "a\nbb\nccc"：第 1 行从 0、第 2 行从 2、第 3 行从 5
        let content = "a\nbb\nccc"

        XCTAssertEqual(RawSourceLineOffset.characterOffset(in: content, sourceLine: SourceLine(oneBased: 1)), 0)
        XCTAssertEqual(RawSourceLineOffset.characterOffset(in: content, sourceLine: SourceLine(oneBased: 2)), 2)
        XCTAssertEqual(RawSourceLineOffset.characterOffset(in: content, sourceLine: SourceLine(oneBased: 3)), 5)
    }

    func testRawSourceLineOffsetCharacterOffsetUsesUTF16UnitsForUnicode() {
        // "é" 为单字符但 UTF-16 编码 1 个 unit；"𝄞"（U+1D11E）为 2 个 UTF-16 unit。
        // NSRange / NSTextView 以 UTF-16 长度计量，故字符偏移必须用 UTF-16 计数。
        let content = "é\n𝄞\nx"
        // 行长度（UTF-16 unit）：第 1 行 "é" = 1，第 2 行 "𝄞" = 2
        // 第 1 行偏移 0；第 2 行 = 1 + 1(换行) = 2；第 3 行 = 2 + 2 + 1(换行) = 5
        XCTAssertEqual(RawSourceLineOffset.characterOffset(in: content, sourceLine: SourceLine(oneBased: 1)), 0)
        XCTAssertEqual(RawSourceLineOffset.characterOffset(in: content, sourceLine: SourceLine(oneBased: 2)), 2)
        XCTAssertEqual(RawSourceLineOffset.characterOffset(in: content, sourceLine: SourceLine(oneBased: 3)), 5)
    }

    func testRawSourceLineOffsetReturnsNilForOutOfRangeLine() {
        let content = "a\nbb"

        XCTAssertNil(RawSourceLineOffset.characterOffset(in: content, sourceLine: SourceLine(oneBased: 99)))
    }

    // MARK: - Raw 可见行：UTF-16 顶部偏移 → 1-based SourceLine

    func testRawVisibleSourceLineUsesTopVisibleUTF16Offset() {
        // "a\n𝄞\nthird"：UTF-16 unit 顺序：a(0) \n(1) 𝄞(2) 𝄞(3) \n(4) third...
        // 偏移 2 落在第 2 行开头（"𝄞" 的首 unit）。
        let content = "a\n𝄞\nthird"

        XCTAssertEqual(
            RawVisibleSourceLine.sourceLine(in: content, utf16CharacterOffset: 2)?.oneBased,
            2
        )
    }

    func testRawVisibleSourceLineAtZeroOffsetReturnsFirstLine() {
        XCTAssertEqual(
            RawVisibleSourceLine.sourceLine(in: "a\nb\nc", utf16CharacterOffset: 0)?.oneBased,
            1
        )
    }

    func testRawVisibleSourceLineForEmptyContentReturnsNil() {
        XCTAssertNil(RawVisibleSourceLine.sourceLine(in: "", utf16CharacterOffset: 0))
    }

    func testRawVisibleSourceLineClampsOverflowToLastLine() {
        // 3 行内容，超出 UTF-16 长度的偏移须钳制到最后可定位行（第 3 行），不得产生无效 SourceLine。
        let content = "a\nb\nc"
        let overflow = (content as NSString).length + 10

        XCTAssertEqual(
            RawVisibleSourceLine.sourceLine(in: content, utf16CharacterOffset: overflow)?.oneBased,
            3
        )
    }

    func testRawVisibleSourceLineConvertsViewportPointByRemovingTextContainerInset() {
        let point = RawVisibleSourceLine.textContainerPoint(
            visibleOrigin: NSPoint(x: 40, y: 300),
            textContainerOrigin: NSPoint(x: 20, y: 20)
        )

        XCTAssertEqual(point, NSPoint(x: 20, y: 280))
    }

    @MainActor
    func testRawEditorCoordinatorRefreshesItsActiveStateBeforeReportingScroll() {
        let theme = ThemeColors.from(PresetThemes.darkThemes[0])
        let inactiveEditor = SyntaxHighlightedEditor(
            content: .constant(""),
            themeColors: theme,
            isActive: false
        )
        let coordinator = inactiveEditor.makeCoordinator()
        XCTAssertFalse(coordinator.parent.isActive)

        let activeEditor = SyntaxHighlightedEditor(
            content: .constant(""),
            themeColors: theme,
            isActive: true
        )
        coordinator.refresh(parent: activeEditor)

        XCTAssertTrue(coordinator.parent.isActive)
    }

    // MARK: - 活跃 Raw 编辑器实际滚动：报告可见行且不动光标

    /// 构造真实 AppKit 布局的编辑器：填入至少 50 行文本，视口滚到中部后读取可见行。
    /// 断言结果是中部行而非第 1 行，并断言 selectedRange 在读取前后完全相同。
    @MainActor
    func testActiveRawEditorReportsMidViewportVisibleLineWithoutMovingCursor() throws {
        _ = NSApplication.shared

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let viewportHeight: CGFloat = 120
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: viewportHeight))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = HighlightableTextView(frame: NSRect(x: 0, y: 0, width: 240, height: viewportHeight))
        textView.font = font
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        guard let textContainer = textView.textContainer else {
            throw NSError(domain: "SourcePositionSyncTests", code: 1)
        }
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.size = NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 20, height: 20)

        // 60 行内容，足以让视口滚到中部
        let lines = (1...60).map { "line \($0) for scrolling test" }
        let content = lines.joined(separator: "\n")
        textView.string = content

        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: viewportHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.layoutIfNeeded()

        guard let layoutManager = textView.layoutManager else {
            throw NSError(domain: "SourcePositionSyncTests", code: 2)
        }
        layoutManager.ensureLayout(for: textContainer)

        // 把光标放在第 1 行，记录选区
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let cursorBefore = textView.selectedRange()

        // 滚到约第 30 行（中部）
        let midLineOffset = RawSourceLineOffset.characterOffset(
            in: content,
            sourceLine: SourceLine(oneBased: 30)
        ) ?? 0
        textView.scrollRangeToVisible(NSRange(location: midLineOffset, length: 0))

        // 通过 Coordinator 读取可见行：构造一个仅用于报告的 coordinator。
        // 直接复用 RawVisibleSourceLine + layoutManager 计算路径，与生产代码一致。
        let visibleRect = scrollView.contentView.bounds
        let textContainerOrigin = textView.textContainerOrigin
        let topPoint = RawVisibleSourceLine.textContainerPoint(
            visibleOrigin: visibleRect.origin,
            textContainerOrigin: textContainerOrigin
        )
        let glyphIndex = layoutManager.glyphIndex(for: topPoint, in: textContainer)
        XCTAssertNotEqual(glyphIndex, NSNotFound)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

        let visibleLine = try XCTUnwrap(
            RawVisibleSourceLine.sourceLine(in: content, utf16CharacterOffset: charIndex)
        )
        // 中部行，不是第 1 行
        XCTAssertGreaterThan(visibleLine.oneBased, 10)
        XCTAssertLessThan(visibleLine.oneBased, 40)

        // 光标/选区必须未被移动
       let cursorAfter = textView.selectedRange()
       XCTAssertEqual(cursorBefore, cursorAfter)
   }

    // MARK: - RawSourceScrollAnchor：采样与无光标定位

    /// 60 行文本，视口放在第 20 行中部：采样锚点应位于 20...21 之间。
    @MainActor
    func testRawSourceScrollAnchorCaptureReturnsFractionalPosition() throws {
        _ = NSApplication.shared
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let viewportHeight: CGFloat = 120
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: viewportHeight))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        let textView = HighlightableTextView(frame: NSRect(x: 0, y: 0, width: 240, height: viewportHeight))
        textView.font = font
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        guard let textContainer = textView.textContainer else { throw NSError(domain: "test", code: 1) }
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.size = NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 20, height: 20)
        let lines = (1...60).map { "line \($0) for anchor test" }
        let content = lines.joined(separator: "\n")
        textView.string = content
        scrollView.documentView = textView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: viewportHeight), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.layoutIfNeeded()
        guard let layoutManager = textView.layoutManager else { throw NSError(domain: "test", code: 2) }
        layoutManager.ensureLayout(for: textContainer)
        let midOffset = RawSourceLineOffset.characterOffset(in: content, sourceLine: SourceLine(oneBased: 20)) ?? 0
        textView.scrollRangeToVisible(NSRange(location: midOffset, length: 0))
        let anchor = try XCTUnwrap(RawSourceScrollAnchor.capture(scrollView: scrollView, textView: textView))
        XCTAssertGreaterThan(anchor.sourcePosition, 10.0)
        XCTAssertLessThan(anchor.sourcePosition, 30.0)
        XCTAssertGreaterThanOrEqual(anchor.documentProgress, 0)
        XCTAssertLessThanOrEqual(anchor.documentProgress, 1)
    }

    /// 用采样锚点应用到同配置编辑器：选区不变。
    @MainActor
    func testRawSourceScrollAnchorApplyDoesNotMoveCursor() throws {
        _ = NSApplication.shared
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let viewportHeight: CGFloat = 120
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: viewportHeight))
        scrollView.hasVerticalScroller = true
        let textView = HighlightableTextView(frame: NSRect(x: 0, y: 0, width: 240, height: viewportHeight))
        textView.font = font
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        guard let textContainer = textView.textContainer else { throw NSError(domain: "test", code: 1) }
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.size = NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 20, height: 20)
        let lines = (1...60).map { "line \($0) for apply test" }
        let content = lines.joined(separator: "\n")
        textView.string = content
        scrollView.documentView = textView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: viewportHeight), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.layoutIfNeeded()
        guard let layoutManager = textView.layoutManager else { throw NSError(domain: "test", code: 2) }
        layoutManager.ensureLayout(for: textContainer)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let cursorBefore = textView.selectedRange()
        let anchor = SourceScrollAnchor(sourcePosition: 30.5, documentProgress: 0.5)
        RawSourceScrollAnchor.apply(anchor: anchor, scrollView: scrollView, textView: textView)
        let cursorAfter = textView.selectedRange()
        XCTAssertEqual(cursorBefore, cursorAfter)
    }

    // MARK: - Task 5: 交接生命周期

    @MainActor
    func testNewModeSwitchInvalidatesOlderUnacknowledgedTransfer() {
        let viewModel = DocumentViewModel()
        let first = viewModel.beginScrollTransfer(
            destination: .rendered,
            anchor: SourceScrollAnchor(sourcePosition: 18.4, documentProgress: 0.63)
        )
        let second = viewModel.beginScrollTransfer(
            destination: .raw,
            anchor: SourceScrollAnchor(sourcePosition: 6.2, documentProgress: 0.18)
        )
        viewModel.acknowledgeScrollTransfer(id: first.id, destination: .rendered, contentVersion: first.contentVersion)
        XCTAssertEqual(viewModel.scrollTransfer?.id, second.id)
    }

    @MainActor
    func testContentVersionChangePreventsOldAcknowledgement() {
        let viewModel = DocumentViewModel()
        let transfer = viewModel.beginScrollTransfer(
            destination: .rendered,
            anchor: SourceScrollAnchor(sourcePosition: 10.0, documentProgress: 0.3)
        )
        viewModel.contentVersion += 1
        viewModel.acknowledgeScrollTransfer(id: transfer.id, destination: .rendered, contentVersion: transfer.contentVersion + 1)
        XCTAssertNotNil(viewModel.scrollTransfer, "旧 contentVersion 回执不得清除当前交接")
        viewModel.acknowledgeScrollTransfer(id: transfer.id, destination: .rendered, contentVersion: transfer.contentVersion)
        XCTAssertNil(viewModel.scrollTransfer, "正确 contentVersion 回执应清除当前交接")
    }

    /// 在最小 DOM stub 中加载随应用打包的真实脚本；`readyState = loading` 阻止
    /// `MR.init()` 访问与本测试无关的 DOM API。
    private func makeMarkdownReaderJavaScriptContext(
        scrollTop: Double,
        blocks: [(start: Int, end: Int, top: Double, bottom: Double)]
    ) throws -> JSContext {
        let blockArguments = blocks.map {
            "block(\($0.start), \($0.end), \($0.top), \($0.bottom))"
        }.joined(separator: ", ")
        let bootstrap = """
        var window = this;
        window.scrollY = \(scrollTop);
        window.innerHeight = 100;
        var __mrBlocks = [\(blockArguments)];
        function block(start, end, top, bottom) {
          return {
            getAttribute: function(name) {
              if (name === 'data-source-start') return String(start);
              if (name === 'data-source-end') return String(end);
              return null;
            },
            getBoundingClientRect: function() {
              return { top: top - window.scrollY, bottom: bottom - window.scrollY };
            }
          };
        }
        var document = {
          readyState: 'loading',
          documentElement: { scrollTop: 0, scrollHeight: 2000 },
          addEventListener: function() {},
          querySelectorAll: function(selector) {
            return selector === '[data-source-start][data-source-end]' ? __mrBlocks : [];
          }
        };
        """
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(bootstrap)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repositoryRoot
            .appendingPathComponent("Sources/MarkdownReader/Resources/js/markdown-reader.js")
        context.evaluateScript(try String(contentsOf: scriptURL, encoding: .utf8))
        return context
    }
}

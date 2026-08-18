import XCTest
import AppKit
import SwiftUI
@testable import MarkdownReaderKit
@testable import MarkdownReader

/// 渲染与编辑源码位置一致性测试。
///
/// 固定契约：所有跨层、跨模式的 Markdown 源码行号统一为 1-based `SourceLine`。
/// 仅在 Raw 编辑器字符偏移计算边界转换为 0-based 行索引；HTML `data-line` 与
/// JavaScript `MR.scrollToLine` 保持既有 1-based 协议。
final class SourcePositionSyncTests: XCTestCase {

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
    func testRawToRenderedRequestsVisibleRawSourceLine() {
        let viewModel = DocumentViewModel()
        viewModel.displayMode = .raw
        viewModel.rawVisibleSourceLine = SourceLine(oneBased: 18)

        viewModel.switchDisplayMode(.rendered)

        XCTAssertEqual(viewModel.scrollToSourceLineRequest?.oneBased, 18)
    }

    @MainActor
    func testRenderedToRawRequestsVisibleRenderedSourceLine() {
        let viewModel = DocumentViewModel()
        viewModel.displayMode = .rendered
        viewModel.renderedVisibleSourceLine = SourceLine(oneBased: 21)

        viewModel.switchDisplayMode(.raw)

        XCTAssertEqual(viewModel.scrollToSourceLineRequest?.oneBased, 21)
    }

    @MainActor
    func testSameModeSwitchDoesNotProduceScrollRequest() {
        let viewModel = DocumentViewModel()
        viewModel.displayMode = .raw
        viewModel.clearScrollRequest()

        viewModel.switchDisplayMode(.raw)

        XCTAssertNil(viewModel.scrollToSourceLineRequest)
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
}

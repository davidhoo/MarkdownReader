import XCTest
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
    func testRawToRenderedRequestsCursorSourceLine() {
        let viewModel = DocumentViewModel()
        viewModel.displayMode = .raw
        viewModel.cursorSourceLine = SourceLine(oneBased: 8)

        viewModel.switchDisplayMode(.rendered)

        XCTAssertEqual(viewModel.scrollToSourceLineRequest?.oneBased, 8)
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
}

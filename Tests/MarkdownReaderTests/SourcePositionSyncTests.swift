import XCTest
@testable import MarkdownReaderKit

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
}

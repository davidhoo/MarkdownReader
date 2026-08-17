import XCTest
import AppKit
@testable import MarkdownReader

/// 编辑器末尾滚动几何与 AppKit 行片段回归测试。
///
/// 覆盖 PR #14 末行可见性保护链：
/// - 纯几何钳制 `EditorScrollGeometry.restoredOrigin(...)` 的边界；
/// - `HighlightableTextView.lineFragmentBounds(for:)` 在文末换行走 extra line fragment；
/// - `scrollRangeToVisible` 在末行下方保留约一行留白。
///
/// AppKit 测试使用真实 `NSTextView` 布局，不手工伪造 frame / clip bounds。
@MainActor
final class SyntaxHighlightedEditorScrollTests: XCTestCase {

    // MARK: - 纯几何：EditorScrollGeometry.restoredOrigin

    func testRestoredOriginMovesEndCaretIntoViewportWithBottomOverscroll() {
        let origin = EditorScrollGeometry.restoredOrigin(
            targetY: 900,
            viewportHeight: 100,
            documentHeight: 1_100,
            bottomInset: 8,
            caretTop: 990,
            caretBottom: 1_010,
            bottomOverscroll: 20
        )

        XCTAssertEqual(origin, 930, accuracy: 0.001)
    }

    func testRestoredOriginDoesNotMoveVisibleInteriorCaret() {
        let origin = EditorScrollGeometry.restoredOrigin(
            targetY: 500,
            viewportHeight: 100,
            documentHeight: 1_100,
            bottomInset: 8,
            caretTop: 530,
            caretBottom: 550,
            bottomOverscroll: 20
        )

        XCTAssertEqual(origin, 500, accuracy: 0.001)
    }

    func testRestoredOriginClampsAtDocumentBottomIncludingSystemInset() {
        let origin = EditorScrollGeometry.restoredOrigin(
            targetY: 1_050,
            viewportHeight: 100,
            documentHeight: 1_100,
            bottomInset: 8,
            caretTop: 1_095,
            caretBottom: 1_115,
            bottomOverscroll: 20
        )

        XCTAssertEqual(origin, 1_008, accuracy: 0.001)
    }

    // MARK: - AppKit 行片段

    func testLineFragmentBoundsUsesExtraFragmentForTrailingNewline() throws {
        let editor = try makeEditor(text: "first\nlast\n", viewportHeight: 80)
        let end = NSRange(location: (editor.textView.string as NSString).length, length: 0)

        let rect = try XCTUnwrap(editor.textView.lineFragmentBounds(for: end))

        XCTAssertGreaterThan(rect.height, 0)
        XCTAssertGreaterThanOrEqual(rect.minY, editor.lastGlyphLineBottom)
    }

    func testScrollRangeToVisibleLeavesOneLineBelowEndCaret() throws {
        let editor = try makeEditor(
            text: String(repeating: "long line for scrolling\n", count: 120),
            viewportHeight: 80
        )
        let end = NSRange(location: (editor.textView.string as NSString).length, length: 0)
        editor.textView.scrollRangeToVisible(end)

        let caret = try XCTUnwrap(editor.textView.lineFragmentBounds(for: end))
        let caretBottom = caret.maxY + editor.textView.textContainerOrigin.y
        let remainingSpace = editor.scrollView.contentView.bounds.maxY - caretBottom
        XCTAssertGreaterThanOrEqual(remainingSpace, editor.textView.bottomOverscroll - 1)
    }

    // MARK: - 测试专用 editor 构造

    /// 构造真实 AppKit 布局的 editor：240pt 宽滚动视图、垂直自适应文本视图、
    /// 无限高度文本容器，放入离屏 window 完成一次布局。
    private struct EditorHandle {
        let scrollView: NSScrollView
        let textView: HighlightableTextView
        let lastGlyphLineBottom: CGFloat
    }

    private func makeEditor(text: String, viewportHeight: CGFloat) throws -> EditorHandle {
        // headless 宿主需要 NSApplication 共享实例才能完成 AppKit 布局
        _ = NSApplication.shared

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: viewportHeight))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder

        let textView = HighlightableTextView(frame: NSRect(x: 0, y: 0, width: 240, height: viewportHeight))
        textView.font = font
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        guard let textContainer = textView.textContainer else {
            throw NSError(domain: "SyntaxHighlightedEditorScrollTests", code: 1)
        }
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.size = NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: 0)

        textView.string = text

        scrollView.documentView = textView
        // 放入离屏 window 触发真实布局
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
            throw NSError(domain: "SyntaxHighlightedEditorScrollTests", code: 2)
        }
        layoutManager.ensureLayout(for: textContainer)

        // 末个 glyph 行下边缘（textContainer 坐标系）
        var lastGlyphLineBottom: CGFloat = 0
        if layoutManager.numberOfGlyphs > 0 {
            let lastRect = layoutManager.lineFragmentUsedRect(
                forGlyphAt: layoutManager.numberOfGlyphs - 1,
                effectiveRange: nil
            )
            lastGlyphLineBottom = lastRect.maxY
        }

        return EditorHandle(
            scrollView: scrollView,
            textView: textView,
            lastGlyphLineBottom: lastGlyphLineBottom
        )
    }
}

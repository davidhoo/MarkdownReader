import XCTest
import AppKit
@testable import MarkdownReader
@testable import MarkdownReaderKit

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

    // MARK: - 纯几何：SourceLineNavigationGeometry.origin

    /// 大纲顶部落点：目标行 500、12pt 边距 → origin = 488。
    func testOutlineTopOriginUsesTwelvePointMargin() {
        let origin = SourceLineNavigationGeometry.origin(
            targetY: 500,
            placement: .outlineTop,
            topMargin: 12,
            viewportHeight: 120,
            documentHeight: 1_000,
            bottomInset: 0
        )
        XCTAssertEqual(origin, 488, accuracy: 0.001)
    }

    /// 文末钳制：目标行接近文末时受最大 origin 钳制，不越界。
    func testOutlineTopOriginClampsAtDocumentEnd() {
        let origin = SourceLineNavigationGeometry.origin(
            targetY: 980,
            placement: .outlineTop,
            topMargin: 12,
            viewportHeight: 120,
            documentHeight: 1_000,
            bottomInset: 8
        )
        // maxY = 1000 - 120 + 8 = 888，desiredY = 968 → 钳制到 888。
        XCTAssertEqual(origin, 888, accuracy: 0.001)
    }

    /// 文首不产生负 origin。
    func testOutlineTopOriginDoesNotGoNegativeAtDocumentStart() {
        let origin = SourceLineNavigationGeometry.origin(
            targetY: 5,
            placement: .outlineTop,
            topMargin: 12,
            viewportHeight: 120,
            documentHeight: 1_000,
            bottomInset: 0
        )
        XCTAssertEqual(origin, 0, accuracy: 0.001)
    }

    /// 查找落点保持既有 `targetY - viewportHeight / 3`，不被大纲改成顶部对齐。
    func testRevealOriginKeepsOneThirdViewportPlacement() {
        let origin = SourceLineNavigationGeometry.origin(
            targetY: 500,
            placement: .reveal,
            topMargin: 12,
            viewportHeight: 120,
            documentHeight: 1_000,
            bottomInset: 0
        )
        XCTAssertEqual(origin, 460, accuracy: 0.001)
    }

    // MARK: - 显式请求取消策略（ExplicitScrollRequestExecutionPolicy）

    /// 同一请求 ID 仅调度一次：首次（无历史记录）允许调度，重复调度被拒绝。
    /// 防止 Rendered 大纲平滑动画的多次 SwiftUI 更新向隐藏 Raw 编辑器排入重复闭包。
    func testExplicitRequestSchedulesOnlyOnceForSameID() {
        let id = UUID()

        XCTAssertTrue(ExplicitScrollRequestExecutionPolicy.shouldSchedule(
            requestID: id,
            lastScheduledRequestID: nil
        ))
        XCTAssertFalse(ExplicitScrollRequestExecutionPolicy.shouldSchedule(
            requestID: id,
            lastScheduledRequestID: id
        ))
    }

    /// 不同请求 ID 仍可调度：连续点击同一标题会生成新 UUID，不得因上一请求
    /// 仍记录而拒绝新的调度（不得以 sourceLine 判定重复）。
    func testExplicitRequestDifferentIDCanSchedule() {
        let firstID = UUID()
        let secondID = UUID()

        XCTAssertTrue(ExplicitScrollRequestExecutionPolicy.shouldSchedule(
            requestID: secondID,
            lastScheduledRequestID: firstID
        ))
    }

    /// 模式切换清空请求后，已捕获旧 UUID 的已排队闭包不得执行。
    /// currentRequest == nil 表示请求已被取消（如模式切换清空）。
    func testCancelledExplicitRequestCannotExecuteAfterModeSwitch() {
        let request = DocumentViewModel.SourceScrollRequest(
            id: UUID(),
            sourceLine: SourceLine(oneBased: 42),
            placement: .outlineTop
        )

        XCTAssertFalse(ExplicitScrollRequestExecutionPolicy.shouldExecute(
            capturedRequestID: request.id,
            currentRequest: nil,
            isDestinationActive: true
        ))
    }

    /// 请求被新请求替换、或目的视图不再活跃时，旧捕获闭包均不得执行。
    func testReplacedOrInactiveExplicitRequestCannotExecute() {
        let old = DocumentViewModel.SourceScrollRequest(
            id: UUID(), sourceLine: SourceLine(oneBased: 42), placement: .outlineTop
        )
        let replacement = DocumentViewModel.SourceScrollRequest(
            id: UUID(), sourceLine: SourceLine(oneBased: 57), placement: .outlineTop
        )

        // 请求已被替换：旧 id 不再匹配当前请求 id。
        XCTAssertFalse(ExplicitScrollRequestExecutionPolicy.shouldExecute(
            capturedRequestID: old.id, currentRequest: replacement, isDestinationActive: true
        ))
        // 目的视图不活跃（隐藏 Raw）：即便 id 匹配也不执行。
        XCTAssertFalse(ExplicitScrollRequestExecutionPolicy.shouldExecute(
            capturedRequestID: old.id, currentRequest: old, isDestinationActive: false
        ))
    }

    /// 正向情形：请求 id 匹配且目的视图活跃时允许执行。
    func testActiveMatchingExplicitRequestCanExecute() {
        let request = DocumentViewModel.SourceScrollRequest(
            id: UUID(), sourceLine: SourceLine(oneBased: 42), placement: .outlineTop
        )

        XCTAssertTrue(ExplicitScrollRequestExecutionPolicy.shouldExecute(
            capturedRequestID: request.id, currentRequest: request, isDestinationActive: true
        ))
    }

    /// 协调器状态序列回归：大纲请求已被 Raw 调度 → 模式切换清空请求
    /// （等价于 `clearScrollRequest()`）→ 已捕获旧 UUID 的已排队闭包不得执行，
    /// 且同一 UUID 不会被重复调度。明确覆盖「已排队、尚未执行的闭包」场景，
    /// 而非只断言 ViewModel 当前请求为 nil。
    @MainActor
    func testQueuedExplicitClosureCannotExecuteAfterRequestCleared() {
        let theme = ThemeColors.from(PresetThemes.darkThemes[0])
        let editor = SyntaxHighlightedEditor(
            content: .constant(""),
            themeColors: theme,
            isActive: true
        )
        let coordinator = editor.makeCoordinator()

        let request = DocumentViewModel.SourceScrollRequest(
            id: UUID(), sourceLine: SourceLine(oneBased: 42), placement: .outlineTop
        )

        // 1. 模拟 Raw 已为该请求调度一次（记录 lastScheduledExplicitScrollRequestID）。
        XCTAssertTrue(ExplicitScrollRequestExecutionPolicy.shouldSchedule(
            requestID: request.id,
            lastScheduledRequestID: coordinator.lastScheduledExplicitScrollRequestID
        ))
        coordinator.lastScheduledExplicitScrollRequestID = request.id

        // 2. 同一请求再次到来的 SwiftUI 更新不得重复调度。
        XCTAssertFalse(ExplicitScrollRequestExecutionPolicy.shouldSchedule(
            requestID: request.id,
            lastScheduledRequestID: coordinator.lastScheduledExplicitScrollRequestID
        ))

        // 3. 模式切换清空请求：更新时把 coordinator 请求记录置 nil，
        //    使下一次新 UUID 请求可正常处理。
        coordinator.lastScheduledExplicitScrollRequestID = nil

        // 4. 已捕获旧 UUID 的已排队闭包执行前再次验证：当前请求为 nil（已取消），
        //    即便目的视图仍活跃，也不得执行。
        XCTAssertFalse(ExplicitScrollRequestExecutionPolicy.shouldExecute(
            capturedRequestID: request.id,
            currentRequest: nil,
            isDestinationActive: true
        ))
    }

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

    // MARK: - 真实 AppKit：大纲顶部落点不移动选区

    /// 中段目标行以 `.outlineTop` 跳转后，标题行位于视口顶约 12pt，且选区不变。
    @MainActor
    func testOutlineTopPlacementRestsNearTopMarginWithoutMovingSelection() throws {
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
            throw NSError(domain: "SyntaxHighlightedEditorScrollTests", code: 1)
        }
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.size = NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 20, height: 20)
        let lines = (1...120).map { "line \($0) for outline top test" }
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
            throw NSError(domain: "SyntaxHighlightedEditorScrollTests", code: 2)
        }
        layoutManager.ensureLayout(for: textContainer)

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let selectionBefore = textView.selectedRange()

        // 跳到第 60 行（中段），落点策略 .outlineTop，12pt 边距。
        let request = DocumentViewModel.SourceScrollRequest(
            id: UUID(),
            sourceLine: SourceLine(oneBased: 60),
            placement: .outlineTop
        )
        let charOffset = try XCTUnwrap(RawSourceLineOffset.characterOffset(in: content, sourceLine: request.sourceLine))
        let range = NSRange(location: charOffset, length: 0)
        textView.scrollRangeToVisible(range)

        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let textContainerOrigin = textView.textContainerOrigin
        let targetY = rect.origin.y + textContainerOrigin.y

        let visibleHeight = scrollView.contentView.bounds.height
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let clampedY = SourceLineNavigationGeometry.origin(
            targetY: targetY,
            placement: .outlineTop,
            topMargin: 12,
            viewportHeight: visibleHeight,
            documentHeight: documentHeight,
            bottomInset: scrollView.contentView.contentInsets.bottom
        )
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: clampedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // 标题行在 clip 视口坐标系中的顶部位置：targetY（文档坐标）- clip 原点。
        // .outlineTop 策略把 clip 原点设为 targetY - 12，故标题在视口顶约 12pt。
        let visibleOriginY = scrollView.contentView.bounds.origin.y
        let headingTopInClip = targetY - visibleOriginY
        XCTAssertEqual(headingTopInClip, 12, accuracy: 1)

        // 选区不被移动。
        XCTAssertEqual(textView.selectedRange(), selectionBefore)
    }

    /// 文首标题以 `.outlineTop` 跳转：不产生负 origin。
    @MainActor
    func testOutlineTopPlacementAtDocumentStartClampsToZero() throws {
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
            throw NSError(domain: "SyntaxHighlightedEditorScrollTests", code: 1)
        }
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.size = NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 20, height: 20)
        let content = String(repeating: "long line for scrolling\n", count: 120)
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
            throw NSError(domain: "SyntaxHighlightedEditorScrollTests", code: 2)
        }
        layoutManager.ensureLayout(for: textContainer)

        let request = DocumentViewModel.SourceScrollRequest(
            id: UUID(),
            sourceLine: SourceLine(oneBased: 1),
            placement: .outlineTop
        )
        let charOffset = try XCTUnwrap(RawSourceLineOffset.characterOffset(in: content, sourceLine: request.sourceLine))
        let range = NSRange(location: charOffset, length: 0)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let targetY = rect.origin.y + textView.textContainerOrigin.y

        let clampedY = SourceLineNavigationGeometry.origin(
            targetY: targetY,
            placement: .outlineTop,
            topMargin: 12,
            viewportHeight: scrollView.contentView.bounds.height,
            documentHeight: scrollView.documentView?.frame.height ?? 0,
            bottomInset: scrollView.contentView.contentInsets.bottom
        )
        XCTAssertGreaterThanOrEqual(clampedY, 0)
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

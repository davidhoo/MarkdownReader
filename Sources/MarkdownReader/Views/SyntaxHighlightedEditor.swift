import SwiftUI
import MarkdownReaderKit
import AppKit
import ObjectiveC

// MARK: - 搜索高亮引用

@MainActor
final class TextViewSearchRef {
    weak var textView: HighlightableTextView?
    private var highlightedRanges: [NSRange] = []
    private var highlightColor: NSColor = NSColor.systemOrange.withAlphaComponent(0.3)
    private var currentMatchColor: NSColor = NSColor.systemOrange.withAlphaComponent(0.6)
    var currentMatchIndex: Int = -1

    func reapplySearchHighlights(matchRanges: [NSRange], currentIndex: Int) {
        guard let textView = textView,
              let textStorage = textView.textStorage else { return }

        highlightedRanges = matchRanges
        currentMatchIndex = currentIndex

        textView.suppressAutoScroll = true
        defer { textView.suppressAutoScroll = false }

        textView.undoManager?.disableUndoRegistration()
        defer { textView.undoManager?.enableUndoRegistration() }

        // 使用 beginEditing/endEditing 批量更新，防止每次 addAttribute 触发 textDidChange
        // 导致 reapplyHighlights 被反复调用，造成搜索高亮被语法高亮覆盖
        textStorage.beginEditing()
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.removeAttribute(.backgroundColor, range: fullRange)
        let storageLength = textStorage.length
        for (index, range) in matchRanges.enumerated() {
            guard range.location >= 0,
                  range.location + range.length <= storageLength else { continue }
            let color: NSColor = index == currentIndex ? currentMatchColor : highlightColor
            textStorage.addAttribute(.backgroundColor, value: color, range: range)
        }
        textStorage.endEditing()
    }

    func clearSearchHighlights() {
        guard let textView = textView,
              let textStorage = textView.textStorage else { return }

        highlightedRanges = []
        currentMatchIndex = -1

        textView.undoManager?.disableUndoRegistration()
        defer { textView.undoManager?.enableUndoRegistration() }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.removeAttribute(.backgroundColor, range: fullRange)
    }

    func selectMatch(at index: Int, in ranges: [NSRange]) {
        guard let textView = textView,
              index >= 0, index < ranges.count else { return }
        let range = ranges[index]
        let storageLength = textView.textStorage?.length ?? 0
        guard range.location >= 0,
              range.location + range.length <= storageLength else { return }
        currentMatchIndex = index
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    func replaceCurrentMatch(at range: NSRange, with replacement: String) -> NSRange? {
        guard let textView = textView,
              let textStorage = textView.textStorage else { return nil }
        let storageLength = textStorage.length
        guard range.location >= 0,
              range.location + range.length <= storageLength else { return nil }
        textStorage.replaceCharacters(in: range, with: replacement)
        let newLength = (replacement as NSString).length
        return NSRange(location: range.location, length: newLength)
    }

    func replaceAllMatches(ranges: [NSRange], with replacement: String) -> Int {
        guard let textView = textView,
              let textStorage = textView.textStorage else { return 0 }
        var count = 0
        for range in ranges.reversed() {
            let storageLength = textStorage.length
            guard range.location >= 0,
                  range.location + range.length <= storageLength else { continue }
            textStorage.replaceCharacters(in: range, with: replacement)
            count += 1
        }
        return count
    }

    func allMatchRanges() -> [NSRange] { highlightedRanges }
}

// MARK: - 全局 Per-File UndoManager 引用

/// Task 10：已移除全局 _activePerFileUndoManager。
/// swizzled getter 通过 NSWindow.undoStore associated object 读取窗口级 store。

// MARK: - NSWindow undoManager Swizzling

extension NSWindow {
    private static var _hasSwizzled = false

    /// 替换 NSWindow.undoManager getter，使其返回 per-file UndoManager
    /// 这是让 Edit 菜单 Undo/Redo 正确工作的关键
    /// NSWindow.undoManager 是只读属性，无 setter，windowWillReturnUndoManager: 不被 SwiftUI 调用
    /// 唯一可靠的方式是 method swizzling
    static func swizzleUndoManager() {
        guard !_hasSwizzled else { return }
        _hasSwizzled = true

        let original = class_getInstanceMethod(NSWindow.self, #selector(getter: undoManager))
        let swizzled = class_getInstanceMethod(NSWindow.self, #selector(_swizzled_undoManager))
        if let original, let swizzled {
            method_exchangeImplementations(original, swizzled)
        }
    }

    /// Swizzled undoManager getter — 返回 per-file UndoManager（如果存在）
    /// 由于 method_exchangeImplementations，调用 self._swizzled_undoManager() 实际调用原始实现
    @objc private func _swizzled_undoManager() -> UndoManager? {
        if Thread.isMainThread, let um = self.undoStore?.activeUndoManager {
            return um
        }
        // 调用原始实现（swizzling 交换了实现，所以这里实际调用原始方法）
        return self._swizzled_undoManager()
    }
}

// MARK: - Per-File UndoManager Provider

// MARK: - 可控滚动文本视图

/// 编辑器滚动位置纯几何钳制。
///
/// 显式按行跳转的纯几何：把目标源码行的 Y 坐标映射为 `contentView` bounds origin，
/// 不依赖 AppKit 视图实例，可在 headless 环境单独测试。参数均处于文本视图坐标系
/// （调用端负责把 `lineFragmentRect` 加上 `textContainerOrigin.y`）。
enum SourceLineNavigationGeometry {
    /// 把目标行顶部 Y 映射为 clip view bounds origin，按落点策略决定顶部边距并钳制。
    ///
    /// - `.outlineTop`：目标标题距视口顶约 `topMargin`（大纲点击统一 12pt）。
    /// - `.reveal`：保留既有 Raw 约 1/3 视口位置的查找体验（`targetY - viewportHeight / 3`）。
    ///
    /// 文首不允许负 origin；文末在文档可滚动范围内钳制，受系统 bottom inset 容忍。
    static func origin(
        targetY: CGFloat,
        placement: DocumentViewModel.SourceScrollPlacement,
        topMargin: CGFloat,
        viewportHeight: CGFloat,
        documentHeight: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        let desiredY: CGFloat
        switch placement {
        case .outlineTop:
            desiredY = targetY - topMargin
        case .reveal:
            desiredY = targetY - viewportHeight / 3.0
        }
        let maxY = max(0, documentHeight - viewportHeight + bottomInset)
        return max(0, min(desiredY, maxY))
    }
}

/// 把高亮恢复后 `contentView` 的目标 origin 钳制提取为无 UI 副作用的纯函数，
/// 使其在无 `NSTextView` 的 headless 环境可单独测试。参数均处于文本视图坐标系
/// （调用端负责把 `lineFragmentBounds` 加上 `textContainerOrigin.y`）。
/// 不创建或修改 `NSView`，不读取全局状态，也不处理动画。
enum EditorScrollGeometry {
    /// 在文档最大可滚动范围内钳制目标 origin，并在插入点所在行被锚点恢复
    /// 推出视口时优先把该行调回可见区。
    ///
    /// - Parameters:
    ///   - targetY: 锚点恢复给出的候选 origin（文本视图坐标）。
    ///   - viewportHeight: 真实视口高度（`contentView.bounds.height`）。
    ///   - documentHeight: 文档视图高度。
    ///   - bottomInset: 系统管理的底部 inset，作为可读取的钳制余量。
    ///   - caretTop: 插入点所在行上边缘（文本视图坐标），nil 表示无插入点信息。
    ///   - caretBottom: 插入点所在行下边缘（文本视图坐标）。
    ///   - bottomOverscroll: 末行下方应保留的留白目标（约一行高度）。
    static func restoredOrigin(
        targetY: CGFloat,
        viewportHeight: CGFloat,
        documentHeight: CGFloat,
        bottomInset: CGFloat,
        caretTop: CGFloat?,
        caretBottom: CGFloat?,
        bottomOverscroll: CGFloat
    ) -> CGFloat {
        let maxY = max(0, documentHeight - viewportHeight + bottomInset)
        var origin = max(0, min(targetY, maxY))

        guard let caretTop, let caretBottom else { return origin }
        if caretBottom > origin + viewportHeight {
            // 插入点所在行沉到视野外：向下滚动让其可见，并在底部留出一个空行
            origin = min(maxY, caretBottom - viewportHeight + bottomOverscroll)
        } else if caretTop < origin {
            origin = max(0, caretTop)
        }
        return origin
    }
}


/// 从 `SourceLine` 计算其在 `NSTextView` 内容中的 UTF-16 字符偏移。
/// NSRange / NSTextView 以 UTF-16 为单位，因此用 `utf16.count` 而非 `String.count`。
enum RawSourceLineOffset {
    static func characterOffset(in content: String, sourceLine: SourceLine) -> Int? {
        let lines = content.components(separatedBy: "\n")
        let index = sourceLine.zeroBasedIndex
        guard lines.indices.contains(index) else { return nil }
        return lines[..<index].reduce(0) { $0 + $1.utf16.count + 1 }
    }
}

/// 将 Raw 编辑器视口顶部的 UTF-16 字符偏移转换为 1-based `SourceLine`。
///
/// 纯逻辑 helper：不触碰 AppKit 对象、滚动视图或选区。NSTextView 的
/// NSRange 以 UTF-16 unit 计量，因此这里同样按 UTF-16 统计前缀中的换行数。
/// 超出 `(content as NSString).length` 的偏移钳制至最后可定位行，避免产生
/// 无效 `SourceLine`；空内容返回 nil。
enum RawVisibleSourceLine {
    /// 将文本视图/clip view 坐标转换为 text container 坐标。
    /// `textContainerOrigin` 是容器在 text view 内的偏移，因此反向换算必须相减。
    static func textContainerPoint(
        visibleOrigin: NSPoint,
        textContainerOrigin: NSPoint
    ) -> NSPoint {
        NSPoint(
            x: visibleOrigin.x - textContainerOrigin.x,
            y: visibleOrigin.y - textContainerOrigin.y
        )
    }

    static func sourceLine(in content: String, utf16CharacterOffset offset: Int) -> SourceLine? {
        let nsContent = content as NSString
        let length = nsContent.length
        guard length > 0 else { return nil }

        let clamped = min(max(offset, 0), length)
        let prefix = nsContent.substring(to: clamped)

        // 前缀中换行数即 0-based 行索引；1-based 行号 = 换行数 + 1。
        // 若偏移落在最后一个换行之后（视口顶部已是文末空行），换行数即等于总行数-1，
        // 构造出的行号仍是有效的最后行。
        var newlineCount = 0
        for char in prefix.unicodeScalars where char == "\n" {
            newlineCount += 1
        }

        // totalLines 至少为 1（length > 0 时内容非空字符串，至少含一个字符即第 1 行）。
        // 当内容以 "\n" 结尾时 components(separatedBy:) 会多出一个空字符串尾行，
        // newlineCount 不会超过最后一个真实行的索引，钳制确保不越界。
        let totalLines = content.components(separatedBy: "\n").count
        let zeroBasedIndex = min(newlineCount, totalLines - 1)
        return SourceLine(oneBased: zeroBasedIndex + 1)
    }
}

/// 模式切换专用的 Raw 源码滚动锚点采样与无光标定位 helper。
/// 把 NSClipView.bounds 顶部转换为小数源码位置（1-based），不移动光标或选区。
enum RawSourceScrollAnchor {
    /// 采样：从 NSScrollView/NSTextView 当前视口顶部计算小数源码位置和全文进度。
    @MainActor
    static func capture(
        scrollView: NSScrollView,
        textView: NSTextView
    ) -> SourceScrollAnchor? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        let content = textView.string
        guard !content.isEmpty else { return nil }

        let visibleRect = scrollView.contentView.bounds
        let textContainerOrigin = textView.textContainerOrigin
        let topPoint = RawVisibleSourceLine.textContainerPoint(
            visibleOrigin: visibleRect.origin,
            textContainerOrigin: textContainerOrigin
        )

        let glyphIndex = layoutManager.glyphIndex(for: topPoint, in: textContainer)
        guard glyphIndex != NSNotFound,
              glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

        guard let line = RawVisibleSourceLine.sourceLine(
            in: content,
            utf16CharacterOffset: charIndex
        ) else { return nil }

       let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
       let fragmentTop = lineRect.minY
       let fragmentHeight = lineRect.height
       let inFragmentProgress: Double
        if fragmentHeight > 0 {
            inFragmentProgress = (topPoint.y - fragmentTop) / fragmentHeight
        } else {
            inFragmentProgress = 0
        }
        let clampedProgress = min(max(inFragmentProgress, 0), 1)
        let sourcePosition = Double(line.oneBased) + clampedProgress

        let docHeight = textView.attributedString().size().height
        let viewportHeight = visibleRect.height
        let maxScroll = max(docHeight - viewportHeight, 0)
        let docProgress = maxScroll > 0 ? min(max(visibleRect.origin.y / maxScroll, 0), 1) : 0

        return SourceScrollAnchor(sourcePosition: sourcePosition, documentProgress: docProgress)
    }

    /// 定位：根据小数源码位置直接设置 clip view bounds origin，不移动光标或选区。
    @MainActor
    static func apply(
        anchor: SourceScrollAnchor,
        scrollView: NSScrollView,
        textView: NSTextView
    ) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let content = textView.string
        guard !content.isEmpty else { return }

        let sourcePosition = anchor.sourcePosition
        let lineInt = Int(floor(sourcePosition))
        let fraction = sourcePosition - Double(lineInt)
        let clampedLine = max(lineInt, 1)

        guard let charOffset = RawSourceLineOffset.characterOffset(
            in: content,
            sourceLine: SourceLine(oneBased: clampedLine)
        ) else { return }

        let nsContent = content as NSString
        let clampedOffset = min(charOffset, nsContent.length)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: clampedOffset)
        guard glyphIndex != NSNotFound else { return }

        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let targetY = lineRect.minY + fraction * lineRect.height

        let textContainerOrigin = textView.textContainerOrigin
        let clipOriginY = targetY + textContainerOrigin.y

        let docHeight = textView.attributedString().size().height
        let viewportHeight = scrollView.contentView.bounds.height
        let maxScroll = max(docHeight - viewportHeight, 0)
        let clampedY = min(max(clipOriginY, 0), maxScroll)

        scrollView.contentView.bounds.origin.y = clampedY
    }
}

/// 把显式按行跳转请求的生命周期判定（能否调度、异步执行前是否仍有效）提取为
/// 无 UI 副作用的纯逻辑，使其在无 `NSTextView` 的 headless 环境可单独测试。
///
/// 解决的竞态：大纲点击发布 `SourceScrollRequest`，`updateNSView` 在每次 SwiftUI
/// 更新中把闭包排入 `DispatchQueue.main.async`。Rendered 大纲平滑动画会产生多次
/// 更新，同一请求可能向隐藏 Raw 编辑器排入多个旧闭包；切换 Rendered → Raw 时
/// `switchDisplayMode` 清空请求，却无法撤回已排队闭包。最后一个旧闭包把编辑器
/// 拉回大纲标题，造成「先对、后错」。
///
/// 该策略把请求 UUID 变成可取消的执行令牌：调度阶段只允许每个 UUID 排入一次；
/// 执行阶段重新读取当前请求与目的视图活跃状态，验证失败则丢弃闭包、不滚动、
/// 不报告可见行。模式切换清空请求后，所有已排队旧闭包自动失效。
///
/// 不触碰 `ScrollTransfer`、`SourceScrollAnchor`，不保存可变全局状态，也不承载
/// AppKit 调用。
enum ExplicitScrollRequestExecutionPolicy {
    /// 决定本次 SwiftUI 更新是否应为该请求排入滚动闭包。
    ///
    /// 同一请求 UUID 在一个视图端最多调度一次：`lastScheduledRequestID` 已等于
    /// 当前请求 ID 时拒绝重复调度，防止无关更新重复创建滚动动画。连续点击同一
    /// 标题会生成新 UUID，仍可调度——不得以 `sourceLine` 判定重复。
    ///
    /// - Parameters:
    ///   - requestID: 当前请求的 UUID。
    ///   - lastScheduledRequestID: 该视图端上次已调度过的请求 UUID（nil 表示尚未调度）。
    static func shouldSchedule(
        requestID: UUID,
        lastScheduledRequestID: UUID?
    ) -> Bool {
        requestID != lastScheduledRequestID
    }

    /// 异步闭包执行前决定是否真正滚动。
    ///
    /// 两个边界都必须通过才执行：目的视图当前活跃（隐藏 Raw 不滚动），且当前
    /// ViewModel 请求仍与闭包捕获的 UUID 相同。请求变 nil（模式切换清空）、
    /// UUID 改变（被新请求替换）或目的视图不再活跃，都判定为已取消，丢弃闭包。
    ///
    /// - Parameters:
    ///   - capturedRequestID: 闭包捕获的请求 UUID。
    ///   - currentRequest: 异步执行时刻 ViewModel 当前的请求（可能已被清空或替换）。
    ///   - isDestinationActive: 目的视图（Raw 编辑器）当前是否为活跃可见模式。
    static func shouldExecute(
        capturedRequestID: UUID,
        currentRequest: DocumentViewModel.SourceScrollRequest?,
        isDestinationActive: Bool
    ) -> Bool {
        isDestinationActive && currentRequest?.id == capturedRequestID
    }
}

/// NSTextView 子类，支持在高亮期间抑制自动滚动
/// 防止 setSelectedRange / 布局变化触发 scrollRangeToVisible 导致跳动
class HighlightableTextView: NSTextView {
    var suppressAutoScroll = false
    /// 底部留白高度（约一个空行）。在文档末尾新增行时，保证最后一行
    /// 不会完全沉到窗口底边，下方始终保留约一行高度的可视空间。
    var bottomOverscroll: CGFloat = 0
    /// 弱引用窗口级 undoStore（Task 10），deinit 时清空 undo 动作防止悬空指针。
    weak var undoStore: WindowUndoStore?

    // 不重写 undoManager — 通过 NSTextViewDelegate.undoManager(for:) 和
    // NSWindowDelegate.windowWillReturnUndoManager: 提供 per-file UndoManager
    // 这确保文本编辑和菜单验证使用同一个 UndoManager 实例

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        if !suppressAutoScroll {
            super.scrollRangeToVisible(range)
            keepLastLineAboveBottomEdge(range)
        }
    }

    /// 指定字符范围所在行的 line fragment 矩形（textContainer 坐标系）。
    /// 插入点位于文本末尾且文本以换行结尾时，光标在 extra line fragment 中。
    /// 注意：extra line fragment 未被使用时返回的是 height=0 的占位矩形而非
    /// NSZeroRect，必须用 height 判断，否则会拿到零高度的错误矩形。
    func lineFragmentBounds(for range: NSRange) -> CGRect? {
        guard let layoutManager = layoutManager, let textContainer = textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let textLength = (string as NSString).length
        guard textLength > 0 else { return nil }
        if range.location >= textLength {
            let extra = layoutManager.extraLineFragmentUsedRect
            if extra.height > 0 {
                return extra
            }
            guard layoutManager.numberOfGlyphs > 0 else { return nil }
            return layoutManager.lineFragmentUsedRect(forGlyphAt: layoutManager.numberOfGlyphs - 1, effectiveRange: nil)
        }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: range.location)
        return layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
    }

    /// 当滚动目标位于文档末尾（最后一行）且其下方留白不足一个空行高度时，
    /// 继续向上滚动，在底部留出一个空行的空间。
    private func keepLastLineAboveBottomEdge(_ range: NSRange) {
        guard bottomOverscroll > 0,
              let scrollView = enclosingScrollView else { return }
        let textLength = (string as NSString).length
        // 仅处理接近文档末尾的范围（最后一行）
        guard textLength > 0, range.location >= textLength - 1,
              let lineRect = lineFragmentBounds(for: range) else { return }

        let lineBottom = lineRect.maxY + textContainerOrigin.y
        let clipBounds = scrollView.contentView.bounds
        let gap = clipBounds.maxY - lineBottom
        guard gap < bottomOverscroll else { return }

        let newOrigin = NSPoint(x: clipBounds.origin.x, y: clipBounds.origin.y + (bottomOverscroll - gap))
        scrollView.contentView.setBoundsOrigin(newOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    deinit {
        // 安全网：当 NSTextView 被释放时，清除所有 per-file UndoManager 的 undo 动作
        // NSUndoManager 不 retain invocation targets，如果 NSTextView 被释放后
        // UndoManager 仍有引用它的 undo 动作，触发 undo 时会访问悬空指针导致 crash
        // 使用异步调度因为 deinit 不能调用 @MainActor 方法
        let store = undoStore
       DispatchQueue.main.async {
           store?.removeAllActions()
         }
     }

 }

// MARK: - 语法高亮编辑器

/// ViewModel 内容（覆盖编辑器）还是编辑器内容（回写 ViewModel）。提取为独立纯逻辑，
/// 使该决策可在无 `NSTextView` 的 headless 环境单独测试。
///
/// 规则：内容相同 → 用 ViewModel（无操作意义，保持一致）；
/// 内容不同且非强制更新且编辑器是 first responder → 用编辑器（用户正在编辑，以编辑器为准）；
/// 否则 → 用 ViewModel（强制覆盖，阻止 first responder 把旧内容反写）。
/// 强制更新条件：文件身份变化（fileDidChange）或 contentVersion 变化（程序化内容替换）。
enum EditorSyncPolicy {
    /// 本次更新应采用的结果。
    enum Outcome: Equatable {
        /// 用 ViewModel 内容覆盖编辑器（程序化更新或非编辑态）。
        case useViewModel
        /// 用编辑器当前内容回写 ViewModel（用户正在编辑）。
        case useEditor
    }

    /// - Parameters:
    ///   - contentDiffers: 编辑器当前内容与 ViewModel 内容是否不同。
    ///   - fileDidChange: 文件身份（fileURL）是否变化。
    ///   - contentVersionChanged: ViewModel 的 contentVersion 是否变化（程序化更新）。
    ///   - editorIsFirstResponder: 编辑器是否为窗口第一响应者。
    static func outcome(
        contentDiffers: Bool,
        fileDidChange: Bool,
        contentVersionChanged: Bool,
        editorIsFirstResponder: Bool
    ) -> Outcome {
        guard contentDiffers else { return .useViewModel }
        let isForcedUpdate = fileDidChange || contentVersionChanged
        if !isForcedUpdate && editorIsFirstResponder {
            return .useEditor
        }
        return .useViewModel
    }
}

/// Raw 编辑器左侧行号栏的固定视觉度量。
///
/// 宽度只取文档最大行号的位数，避免随着滚动到不同位置而改变编辑区宽度。
enum LineNumberGutterMetrics {
    static let horizontalPadding: CGFloat = 8

    static func width(lineCount: Int, font: NSFont) -> CGFloat {
        let largestLineNumber = String(max(lineCount, 1))
        let labelWidth = (largestLineNumber as NSString).size(withAttributes: [.font: font]).width
        return ceil(labelWidth + horizontalPadding * 2)
    }
}

/// 固定在 Raw 编辑器左侧的行号 gutter。它只绘制当前视口中的逻辑源码行，
/// 自动换行的后续 fragment 不重复编号。
@MainActor
private final class LineNumberGutterRenderer {
    let layer = CALayer()
    private weak var scrollView: NSScrollView?
    private weak var textView: NSTextView?
    private var labelColor: NSColor
    private var labelFont: NSFont
    private var gutterBackgroundColor: NSColor

    init(scrollView: NSScrollView, textView: NSTextView, labelColor: NSColor, labelFont: NSFont, backgroundColor: NSColor) {
        self.scrollView = scrollView
        self.textView = textView
        self.labelColor = labelColor
        self.labelFont = labelFont
        self.gutterBackgroundColor = backgroundColor
        layer.contentsGravity = .resize
        // AppKit 会将 documentView 的托管 layer 加入同一父层；显式置顶以保持 gutter 覆盖文本左侧。
        layer.zPosition = 1
        refresh(textView: textView, labelColor: labelColor, labelFont: labelFont, backgroundColor: backgroundColor)
    }

    func refresh(textView: NSTextView, labelColor: NSColor, labelFont: NSFont, backgroundColor: NSColor) {
        self.textView = textView
        self.labelColor = labelColor
        self.labelFont = labelFont
        self.gutterBackgroundColor = backgroundColor
        redraw()
    }

    func redraw() {
        let size = layer.bounds.size
        guard size.width > 0, size.height > 0 else {
            layer.contents = nil
            return
        }

        let image = NSImage(size: size, flipped: true) { [weak self] rect in
            guard let self else { return false }
            self.gutterBackgroundColor.setFill()
            rect.fill()
            self.drawLineNumbers()
            return true
        }
        layer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func drawLineNumbers() {
        guard let scrollView,
              let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)
        let content = textView.string
        let contentNSString = content as NSString
        let textLength = contentNSString.length
        guard textLength > 0 else { return }

        let textContainerOrigin = textView.textContainerOrigin
        let clipBounds = scrollView.contentView.bounds
        let visibleContainerRect = clipBounds.offsetBy(
            dx: -textContainerOrigin.x,
            dy: -textContainerOrigin.y
        )
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleContainerRect, in: textContainer)
        guard visibleGlyphRange.location != NSNotFound else { return }
        let visibleGlyphEnd = NSMaxRange(visibleGlyphRange)
        var glyphIndex = visibleGlyphRange.location

        while glyphIndex < visibleGlyphEnd {
            var fragmentGlyphRange = NSRange()
            let fragmentRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: &fragmentGlyphRange)
            guard fragmentGlyphRange.length > 0 else { break }

            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let sourceLineRange = contentNSString.lineRange(for: NSRange(location: characterIndex, length: 0))
            let sourceLineStartGlyph = layoutManager.glyphIndexForCharacter(at: sourceLineRange.location)
            if glyphIndex == sourceLineStartGlyph {
                drawLineNumber(
                    sourceLineNumber(forCharacterOffset: sourceLineRange.location, in: content),
                    atY: fragmentRect.minY + textContainerOrigin.y - clipBounds.minY
                )
            }
            glyphIndex = NSMaxRange(fragmentGlyphRange)
        }

        let extraFragment = layoutManager.extraLineFragmentUsedRect
        if extraFragment.height > 0,
           visibleGlyphEnd >= layoutManager.numberOfGlyphs {
            drawLineNumber(
                sourceLineCount(in: content),
                atY: extraFragment.minY + textContainerOrigin.y - clipBounds.minY
            )
        }
    }

    private func drawLineNumber(_ lineNumber: Int, atY y: CGFloat) {
        let label = String(lineNumber) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: labelColor
        ]
        let labelWidth = label.size(withAttributes: attributes).width
        let x = layer.bounds.width - LineNumberGutterMetrics.horizontalPadding - labelWidth
        label.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    }

    private func sourceLineCount(in content: String) -> Int {
        content.utf16.reduce(into: 1) { count, codeUnit in
            if codeUnit == 10 { count += 1 }
        }
    }

    private func sourceLineNumber(forCharacterOffset offset: Int, in content: String) -> Int {
        content.utf16.prefix(offset).reduce(into: 1) { count, codeUnit in
            if codeUnit == 10 { count += 1 }
        }
    }
}

/// 保持 `NSScrollView` 作为 SwiftUI 直接托管的根视图，将行号栏覆盖在其左侧。
/// 不得改写 `contentView.frame`：AppKit 在 SwiftUI 托管下会据此决定文字绘制区域，
/// 修改它会导致内容不绘制。编辑文本通过 text container 的内边距避开覆盖层。
@MainActor
final class LineNumberScrollView: NSScrollView {
    private(set) var lineNumberGutterLayer: CALayer?
    private var lineNumberGutterRenderer: LineNumberGutterRenderer?
    private var gutterWidth: CGFloat = 0

    func configureLineNumberGutter(
        showLineNumbers: Bool,
        textView: NSTextView,
        labelColor: NSColor,
        labelFont: NSFont,
        backgroundColor: NSColor,
        contentPadding: CGFloat
    ) {
        let gutterRenderer: LineNumberGutterRenderer
        if let existing = lineNumberGutterRenderer {
            gutterRenderer = existing
        } else {
            let created = LineNumberGutterRenderer(
                scrollView: self,
                textView: textView,
                labelColor: labelColor,
                labelFont: labelFont,
                backgroundColor: backgroundColor
            )
            wantsLayer = true
            layer?.addSublayer(created.layer)
            lineNumberGutterLayer = created.layer
            lineNumberGutterRenderer = created
            gutterRenderer = created
        }

        gutterRenderer.refresh(
            textView: textView,
            labelColor: labelColor,
            labelFont: labelFont,
            backgroundColor: backgroundColor
        )
        gutterWidth = showLineNumbers
            ? LineNumberGutterMetrics.width(lineCount: sourceLineCount(in: textView.string), font: labelFont)
            : 0
        gutterRenderer.layer.isHidden = !showLineNumbers
        let textInset = NSSize(
            width: contentPadding + gutterWidth,
            height: contentPadding
        )
        if textView.textContainerInset != textInset {
            textView.textContainerInset = textInset
        }
        tile()
    }

    override func tile() {
        super.tile()

        lineNumberGutterLayer?.frame = CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: gutterWidth,
            height: bounds.height
        )
        lineNumberGutterRenderer?.redraw()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        lineNumberGutterRenderer?.redraw()
    }

    private func sourceLineCount(in content: String) -> Int {
        content.utf16.reduce(into: 1) { count, codeUnit in
            if codeUnit == 10 { count += 1 }
        }
    }
}

/// 基于 NSTextView 的语法高亮编辑器
/// 支持 Markdown 语法着色、主题色适配、滚动到指定行
struct SyntaxHighlightedEditor: NSViewRepresentable {
    @Binding var content: String
    var fontSize: CGFloat = 13
    var contentPadding: CGFloat = 20
    var showLineNumbers: Bool = false
    var scrollToSourceLineRequest: DocumentViewModel.SourceScrollRequest?
    var themeColors: ThemeColors
    /// 当前文件 URL，用于 per-file undo 管理
    var fileURL: URL?
    /// 是否处于活跃状态（Raw 模式），用于自动获取焦点
    var isActive: Bool = false
    var searchRef: TextViewSearchRef?
    /// 查找面板是否可见，可见时不抢占焦点
    var isFindBarVisible: Bool = false
    /// Raw 编辑器实际可见区域顶部源码行变化回调（1-based SourceLine）。
    /// 仅活跃（isActive）编辑器滚动或程序化跳转后报告；不得调用 requestScroll，
    /// 以免与 Raw → Rendered 锚点回写形成滚动回环。
   var onVisibleSourceLineChanged: ((SourceLine) -> Void)?
  /// 模式切换采样：采集 Raw 编辑器当前视口顶部的源码滚动锚点。
 var onRawScrollAnchorCaptured: ((SourceScrollAnchor) -> Void)?
 /// 切换触发的采样回调，带触发时 token。nil = 滚动同步（仅缓存），非 nil = 切换触发（需验证 token）。
 var onRawScrollAnchorTriggered: ((SourceScrollAnchor, UUID) -> Void)?
   /// 切换主动触发采样的请求 token。变化时立即执行一次 capture。
   var rawCaptureRequest: UUID?
  /// 模式切换定位交接：destination == .raw 时消费，应用锚点后回执。
   var scrollTransfer: ScrollTransfer?
   var onScrollTransferApplied: ((UUID) -> Void)?
  /// 内容版本号，变化时强制用 ViewModel 内容覆盖编辑器（阻止 firstResponder 回写）
   /// 用于 reload 操作：ViewModel 更新了 content 但 NSTextView 仍持有旧内容
   var contentVersion: Int = 0
    /// 窗口级 Undo 存储（Task 10）。nil 时回退到 window.undoStore。
    var undoStore: WindowUndoStore?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> LineNumberScrollView {
        // 手动创建 NSScrollView + NSTextView
        // 不使用 NSTextView.scrollableTextView() 工厂方法，避免其自带约束与 SwiftUI 布局冲突
        let scrollView = LineNumberScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let textView = HighlightableTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isSelectable = true
        textView.isEditable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear  // 显式设置透明背景，防止 appearance 变化时 AppKit 重置为不透明
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.insertionPointColor = themeColors.accent.nsColor

        // 让文本容器宽度跟随 textView 宽度自动调整
        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }

        // 设置默认字体和颜色
        let defaultFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.font = defaultFont
        textView.typingAttributes[.foregroundColor] = themeColors.ink.nsColor

        // 初始内容 — 使用 textStorage API + disableUndoRegistration 避免 undo 记录
        let um = undoStore?.undoManager(for: fileURL)
        um?.disableUndoRegistration()
        if let textStorage = textView.textStorage {
            textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: content)
        } else {
            textView.string = content
        }
        um?.enableUndoRegistration()

        // 组装 scrollView + textView
        scrollView.documentView = textView

        // 底部留白目标高度（约一个空行）：末尾新增行时最后一行下方
        // 应保留约一行高度的空间。注意：不设置 scrollView/clipView 的
        // contentInsets — 系统在布局时会覆写该值（实测被改写），主动设置
        // 既无效还会污染 scrollView.visibleRect 导致滚动计算漂移。
        let lineHeight = textView.layoutManager?.defaultLineHeight(for: defaultFont) ?? (fontSize * 1.5)
        textView.bottomOverscroll = ceil(lineHeight)

        // 应用初始高亮
        let syntaxColors = deriveSyntaxColors(from: themeColors)
        MarkdownSyntaxHighlighter.applyHighlights(
            to: textView,
            text: content,
            colors: syntaxColors,
            fontSize: fontSize
        )

        // Task 10：把 undoStore 弱引用传给 textView，deinit 时清空
        textView.undoStore = undoStore
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.wasActive = isActive
        context.coordinator.previousThemeColors = themeColors
        configureLineNumberGutter(in: scrollView, textView: textView)

        // 监听活跃编辑器实际滚动：仅报告视口顶部源码行，不触碰选区、不调用 requestScroll。
        // 防抖 100ms，避免连续拖动滚动条产生高频回写。
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        // 用 Unmanaged<Coordinator> 把弱引用包装进 @Sendable 闭包：Coordinator 是
        // NSViewRepresentable 持有的 NSObject，observer 在 deinit 中移除，闭包
        // 仅在主线程（queue: .main）执行，规避 Swift 6 对非 Sendable 捕获的限制。
        final class CoordinatorBox: @unchecked Sendable {
            weak var coordinator: Coordinator?
            init(_ coordinator: Coordinator) { self.coordinator = coordinator }
        }
        let box = CoordinatorBox(context.coordinator)
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { _ in
            // queue: .main 保证主线程；assumeIsolated 桥接到 @MainActor。
            MainActor.assumeIsolated {
                box.coordinator?.scheduleVisibleLineReport()
            }
        }
        context.coordinator.boundsObserver = observer
        searchRef?.textView = textView

        // 记录当前 appearance，后续 updateNSView 中检测变化
        context.coordinator.lastAppearanceToken = NSApp.effectiveAppearance.description

        // Task 10：切换窗口级 undoStore 的活跃文件
        undoStore?.switchFile(to: fileURL)

        // 如果处于活跃状态，自动获取焦点
        if isActive {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: LineNumberScrollView, context: Context) {
        context.coordinator.refresh(parent: self)
        guard let textView = scrollView.documentView as? HighlightableTextView else { return }

        // 检测文件切换：在更新 coordinator.currentFileURL 之前先捕获，供内容同步判定使用。
        // 文件身份变化必须视为强制覆盖（即使编辑器是 first responder，也不能把上一个文件的
        // 内容反写回 ViewModel），回归根因 3。
        let fileDidChange = context.coordinator.currentFileURL != fileURL
        if fileDidChange {
            undoStore?.switchFile(to: fileURL)
            context.coordinator.currentFileURL = fileURL
        }

        // 更新内容（仅在内容确实不同时）
        let currentContent = textView.string
        if currentContent != content {
            // 当 NSTextView 是第一响应者（用户正在编辑）时，以编辑器内容为准
            // 同步回 content Binding，防止 SwiftUI 重渲染用旧值覆盖编辑器
            // 这是修复"保存后内容回退"bug 的关键：保存触发 isDirty 变化，
            // 导致 updateNSView 被调用，如果此时 content 与 textView.string 不同，
            // 不应用 content 覆盖 textView，而应反过来同步
            //
            // 例外（强制覆盖，ViewModel 内容必须胜出，不允许 firstResponder 反写）：
            // 1. contentVersion 变化：reload/load/createUntitled 等程序化内容替换；
            // 2. 文件身份变化（fileDidChange）：切换文档时即使编辑器是 first responder，
            //    也必须用新文档的 ViewModel 内容覆盖编辑器残留的旧内容（回归根因 3）。
            let contentVersionChanged = contentVersion != context.coordinator.lastContentVersion
            let editorIsFirstResponder = textView.window?.firstResponder === textView
            let outcome = EditorSyncPolicy.outcome(
                contentDiffers: true,
                fileDidChange: fileDidChange,
                contentVersionChanged: contentVersionChanged,
                editorIsFirstResponder: editorIsFirstResponder
            )
            if outcome == .useEditor {
                content = currentContent
            } else {
                textView.undoManager?.disableUndoRegistration()
                defer { textView.undoManager?.enableUndoRegistration() }

                if let textStorage = textView.textStorage {
                    let fullRange = NSRange(location: 0, length: textStorage.length)
                    textStorage.beginEditing()
                    textStorage.replaceCharacters(in: fullRange, with: content)
                    textStorage.endEditing()
                } else {
                    textView.string = content
                }
            }
        }
        // 同步 contentVersion 到 coordinator，避免同一版本重复触发强制更新
        context.coordinator.lastContentVersion = contentVersion

        // 更新插入点颜色
        textView.insertionPointColor = themeColors.accent.nsColor
        // typingAttributes 只影响新输入文字的颜色，不覆盖 textStorage 中已有的 per-range 语法高亮
        // textView.textColor 在 isRichText=false 模式下会覆盖全部 foregroundColor 属性
        textView.typingAttributes[.foregroundColor] = themeColors.ink.nsColor
        // 防御性重置：AppKit 可能在 appearance 变化时将 drawsBackground 重置为 true
        // 或将 backgroundColor 重置为不透明色，导致文字被覆盖不可见
        textView.drawsBackground = false
        textView.backgroundColor = .clear

        // 检测 appearance 变化（NSApp.appearance 被设置时 AppKit 会重置 NSTextView 属性）
        context.coordinator.checkAppearanceChange()

        // 始终重新应用语法高亮：isRichText=false 模式下，AppKit 可能在布局变化时
        // （切换大纲面板、窗口缩放、渲染/编辑切换等）清除 textStorage 的 per-range 属性
        // 不使用脏标记优化：首字符颜色检测无法覆盖中段语法元素被清除的情况
        let syntaxColors = deriveSyntaxColors(from: themeColors)
        MarkdownSyntaxHighlighter.applyHighlights(
            to: textView,
            text: textView.string,
            colors: syntaxColors,
            fontSize: fontSize
        )
        context.coordinator.previousThemeColors = themeColors
        context.coordinator.wasActive = isActive

        // 重新叠加搜索高亮（applyHighlights 的 setAttributes 会清除 backgroundColor）
        if let searchRef = searchRef, !searchRef.allMatchRanges().isEmpty {
            searchRef.reapplySearchHighlights(
                matchRanges: searchRef.allMatchRanges(),
                currentIndex: searchRef.currentMatchIndex
            )
        }

        // 同步底部留白目标高度（fontSize 可能通过设置变化）
        let currentFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let lineHeight = textView.layoutManager?.defaultLineHeight(for: currentFont) ?? (fontSize * 1.5)
        let newOverscroll = ceil(lineHeight)
        if abs(textView.bottomOverscroll - newOverscroll) > 0.01 {
            textView.bottomOverscroll = newOverscroll
        }

        configureLineNumberGutter(in: scrollView, textView: textView)

        // First responder 管理：切换到 Raw 模式时自动获取焦点
        // 查找面板可见时不抢占焦点，避免搜索输入框失去焦点
        if isActive, !isFindBarVisible, let window = textView.window, window.firstResponder !== textView {
            DispatchQueue.main.async {
                window.makeFirstResponder(textView)
            }
        }

       // 显式按行跳转请求（大纲/查找/标题）。仅当 Raw 为当前活跃可见模式时消费；
       // 隐藏 Raw 不得调度或执行，避免在不可见视图执行旧定位。同一请求 UUID 仅调度
       // 一次（防止 Rendered 大纲平滑动画的多次更新重复排队）；异步闭包执行前再次
       // 验证请求 ID 仍为 ViewModel 当前请求——模式切换清空请求后，所有已排队旧闭包
       // 自动失效，不会把编辑器拉回大纲标题（修复「先对、后错」竞态）。
       if let request = scrollToSourceLineRequest, isActive {
           if ExplicitScrollRequestExecutionPolicy.shouldSchedule(
               requestID: request.id,
               lastScheduledRequestID: context.coordinator.lastScheduledExplicitScrollRequestID
           ) {
               context.coordinator.lastScheduledExplicitScrollRequestID = request.id
               let capturedRequestID = request.id
               DispatchQueue.main.async { [context, request] in
                   // 执行前再次读取 coordinator 最新 parent，验证请求 ID 仍匹配且 Raw 仍活跃。
                   // 验证失败：丢弃闭包，不滚动、不报告可见行。
                   // SourceScrollRequest 是 let 字段 struct，ID 唯一即整个值相同，
                   // 故通过 ID 验证后直接用捕获的 request 即可，无需二次解包当前请求。
                   guard ExplicitScrollRequestExecutionPolicy.shouldExecute(
                       capturedRequestID: capturedRequestID,
                       currentRequest: context.coordinator.parent.scrollToSourceLineRequest,
                       isDestinationActive: context.coordinator.parent.isActive
                   ) else { return }
                   self.scrollToLineInTextView(textView, request: request, content: textView.string)
                   // 动画结束后报告一次可见行，覆盖 Raw 内大纲/查找跳转后切模式的回归点。
                   context.coordinator.reportVisibleSourceLineOnce()
               }
           }
       } else if scrollToSourceLineRequest == nil {
           // 当前请求为 nil（模式切换清空）：重置调度记录，使下一次新 UUID 请求可正常处理。
           // 不得以 sourceLine 判定重复，连续点击同一标题必须仍可执行。
           context.coordinator.lastScheduledExplicitScrollRequestID = nil
       }

       // 模式切换定位交接：destination == .raw 时消费
       if let transfer = scrollTransfer,
          transfer.destination == .raw,
          transfer.contentVersion == contentVersion {
           DispatchQueue.main.async { [transfer] in
               RawSourceScrollAnchor.apply(
                   anchor: transfer.anchor,
                   scrollView: scrollView,
                   textView: textView
               )
              onScrollTransferApplied?(transfer.id)
          }
      }

     // 切换主动触发采样：rawCaptureRequest 变化时立即执行 capture。
     if let requestToken = rawCaptureRequest,
        requestToken != context.coordinator.lastRawCaptureRequest {
         context.coordinator.lastRawCaptureRequest = requestToken
         if let anchor = RawSourceScrollAnchor.capture(scrollView: scrollView, textView: textView) {
             // 传触发时 token，handleAnchorCaptured 比值防 A→B→A 覆盖
             onRawScrollAnchorTriggered?(anchor, requestToken)
         }
     }
  }

    private func configureLineNumberGutter(in scrollView: LineNumberScrollView, textView: NSTextView) {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        scrollView.configureLineNumberGutter(
            showLineNumbers: showLineNumbers,
            textView: textView,
            labelColor: themeColors.fgMuted.nsColor,
            labelFont: font,
            backgroundColor: themeColors.surface.nsColor,
            contentPadding: contentPadding
        )
    }

    // MARK: - 颜色转换

    /// 从 ThemeColors 派生 SyntaxColors
    private func deriveSyntaxColors(from tc: ThemeColors) -> SyntaxColors {
        let surface = tc.surface.nsColor
        let ink = tc.ink.nsColor
        let accent = tc.accent.nsColor
        let success = tc.success.nsColor
        let danger = tc.danger.nsColor

        let isDark = tc.surface.nsColor.perceivedBrightness < tc.ink.nsColor.perceivedBrightness

        return SyntaxColors.from(
            surface: surface,
            ink: ink,
            accent: accent,
            success: success,
            danger: danger,
            isDark: isDark
        )
    }

    // MARK: - 滚动到行

    /// 显式按行跳转：根据落点策略定位目标行，统一动画 0.3 秒、`easeOut`。
    /// 大纲点击（`.outlineTop`）把目标行停到视口顶下方约 12pt；查找等（`.reveal`）
    /// 保留既有约 1/3 视口位置。不移动光标/选区，先 `scrollRangeToVisible` 做布局准备，
    /// 再立即以 `SourceLineNavigationGeometry` 计算的 origin 覆盖。
    private func scrollToLineInTextView(
        _ textView: NSTextView,
        request: DocumentViewModel.SourceScrollRequest,
        content: String
    ) {
        guard let charOffset = RawSourceLineOffset.characterOffset(
            in: content,
            sourceLine: request.sourceLine
        ) else {
            return
        }

        let range = NSRange(location: charOffset, length: 0)
        textView.scrollRangeToVisible(range)

        guard let scrollView = textView.enclosingScrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let textContainerOrigin = textView.textContainerOrigin
        let targetY = rect.origin.y + textContainerOrigin.y

        let visibleHeight = scrollView.contentView.bounds.height
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        // 系统管理的 contentInsets 提供少量额外可滚动空间，钳制上限读取容忍
        let bottomInset = scrollView.contentView.contentInsets.bottom

        let clampedY = SourceLineNavigationGeometry.origin(
            targetY: targetY,
            placement: request.placement,
            topMargin: 12,
            viewportHeight: visibleHeight,
            documentHeight: documentHeight,
            bottomInset: bottomInset
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scrollView.contentView.animator().setBoundsOrigin(
                NSPoint(x: scrollView.contentView.bounds.origin.x, y: clampedY)
            )
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyntaxHighlightedEditor
        weak var textView: HighlightableTextView?
        weak var scrollView: NSScrollView?
        private var highlightWorkItem: DispatchWorkItem?
        var currentFileURL: URL?
        var previousThemeColors: ThemeColors?
       var wasActive: Bool = false
       var lastRawCaptureRequest: UUID?
        /// 已为显式按行跳转请求（大纲/查找）调度过滚动闭包的 UUID。
        /// 同一 UUID 仅调度一次，防止 Rendered 大纲平滑动画的多次 SwiftUI 更新
        /// 向隐藏 Raw 编辑器排入重复闭包；请求清空时置 nil，使下一个新 UUID 可正常处理。
        /// 不得以 `sourceLine` 判定重复——连续点击同一标题会带新 UUID，必须仍能调度。
        var lastScheduledExplicitScrollRequestID: UUID?
        /// 上次记录的 appearance token，用于检测 appearance 变化
        var lastAppearanceToken: String?
        /// 上次处理的 contentVersion，用于检测程序化内容更新（reload/load）
        var lastContentVersion: Int = 0
        /// boundsDidChange 观察者 token，deinit 时移除
        var boundsObserver: NSObjectProtocol?
        /// 滚动防抖 work item
        var visibleLineDebounce: DispatchWorkItem?

        deinit {
            if let observer = boundsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            visibleLineDebounce?.cancel()
        }

        init(_ parent: SyntaxHighlightedEditor) {
            self.parent = parent
        }

        /// `NSViewRepresentable` 的 coordinator 在首次创建后持续复用；每次 SwiftUI
        /// 更新都必须刷新值类型 parent，才能读取当前 isActive 与回调闭包。
        func refresh(parent: SyntaxHighlightedEditor) {
            self.parent = parent
        }

        @MainActor
        func checkAppearanceChange() {
            let currentToken = NSApp.effectiveAppearance.description
            guard currentToken != lastAppearanceToken else { return }
            lastAppearanceToken = currentToken

            // appearance 变化时 AppKit 会重置 NSTextView 属性
            guard let textView else { return }
            textView.drawsBackground = false
            textView.backgroundColor = .clear
            textView.typingAttributes[.foregroundColor] = parent.themeColors.ink.nsColor
            textView.insertionPointColor = parent.themeColors.accent.nsColor
            // 语法高亮由 updateNSView 末尾统一重应用
        }

        /// NSTextViewDelegate — 为文本视图提供 per-file UndoManager
        /// 此方法返回的 UndoManager 同时也是 windowWillReturnUndoManager: 返回的实例
        /// 确保文本编辑和菜单验证使用同一个 UndoManager
        func undoManager(for view: NSTextView) -> UndoManager? {
            return parent.undoStore?.activeUndoManager
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView else { return }
            let newContent = textView.string

            // 更新绑定
            parent.content = newContent

            // 防抖高亮：延迟 50ms 重新高亮，避免每次按键都触发
            highlightWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.reapplyHighlights()
            }
            highlightWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // 模式切换锚点已改用可见行（onVisibleSourceLineChanged），不再追踪光标行。
        }

        // MARK: - 可见行报告（仅活跃编辑器）

        /// boundsDidChange 防抖入口：100ms 内合并多次滚动通知。
        @MainActor
        func scheduleVisibleLineReport() {
            visibleLineDebounce?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.reportVisibleSourceLine()
            }
            visibleLineDebounce = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
        }

        /// 程序化跳转（大纲/查找）动画结束后由 scrollToLineInTextView 调用，
        /// 报告一次最终可见行。即便用户没有再次手动滚动，下一次切到 Rendered
        /// 仍使用新位置。
        @MainActor
        func reportVisibleSourceLineOnce() {
            visibleLineDebounce?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.reportVisibleSourceLine()
            }
        }

        /// 读取视口顶部 UTF-16 偏移并转为 1-based SourceLine。
        /// 缺少 layout / textContainer 时不猜测行号，等待下一次通知。
        /// 严禁调用 requestScroll，严禁触碰 setSelectedRange。
        @MainActor
        private func reportVisibleSourceLine() {
            // 仅活跃 Raw 编辑器可写回 rawVisibleSourceLine；隐藏的常驻 Raw
            // 不得覆盖 Rendered 状态。
            guard parent.isActive else { return }
            guard let textView, let scrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            let content = textView.string
            guard !content.isEmpty else { return }

            let visibleRect = scrollView.contentView.bounds
            let textContainerOrigin = textView.textContainerOrigin
            // 视口顶部在文本容器坐标系中的点
            let topPoint = RawVisibleSourceLine.textContainerPoint(
                visibleOrigin: visibleRect.origin,
                textContainerOrigin: textContainerOrigin
            )

            let glyphIndex = layoutManager.glyphIndex(for: topPoint, in: textContainer)
            guard glyphIndex != NSNotFound,
                  glyphIndex < layoutManager.numberOfGlyphs else { return }
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

            let sourceLine = RawVisibleSourceLine.sourceLine(
                in: content,
                utf16CharacterOffset: charIndex
            )
           guard let sourceLine else { return }
           parent.onVisibleSourceLineChanged?(sourceLine)
           // 同时采集模式切换锚点（小数源码位置），供 Raw→Rendered 切换使用。
           if let anchor = RawSourceScrollAnchor.capture(scrollView: scrollView, textView: textView) {
               parent.onRawScrollAnchorCaptured?(anchor)
           }
       }

        @MainActor
        private func reapplyHighlights() {
            guard let textView = textView,
                  let scrollView = scrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            let syntaxColors = parent.deriveSyntaxColors(from: parent.themeColors)

            // 抑制自动滚动，防止高亮期间 setSelectedRange / 布局变化导致跳动
            textView.suppressAutoScroll = true
            defer { textView.suppressAutoScroll = false }

            // 保存选中范围
            let selectedRange = textView.selectedRange()

            // 保存滚动位置：记录第一个可见字符的位置和垂直偏移
            let visibleRect = textView.visibleRect
            let textContainerOrigin = textView.textContainerOrigin

            // 将可见区域从文本视图坐标转换为文本容器坐标
            let containerVisibleRect = NSRect(
                x: visibleRect.origin.x - textContainerOrigin.x,
                y: visibleRect.origin.y - textContainerOrigin.y,
                width: visibleRect.width,
                height: visibleRect.height
            )

            // 获取可见区域对应的字符范围
            let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: containerVisibleRect, in: textContainer)
            let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
            let firstVisibleCharLocation = visibleCharRange.location

            // 计算第一个可见字符在文本视图坐标系中的 Y 坐标
            let firstCharGlyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: firstVisibleCharLocation, length: 0),
                actualCharacterRange: nil
            )
            let firstCharRect = layoutManager.boundingRect(forGlyphRange: firstCharGlyphRange, in: textContainer)
            let firstCharYInView = firstCharRect.origin.y + textContainerOrigin.y

            // 计算第一个可见字符相对于可见区域顶部的偏移量
            let verticalOffset = firstCharYInView - visibleRect.origin.y

            // 应用语法高亮
            MarkdownSyntaxHighlighter.applyHighlights(
                to: textView,
                text: textView.string,
                colors: syntaxColors,
                fontSize: parent.fontSize
            )

            // 确保可见区域的布局已完成（而非仅 1 个字符）
            layoutManager.ensureLayout(forCharacterRange: visibleCharRange)

            // 基于字符位置恢复滚动位置（在恢复选中范围之前，避免 setSelectedRange 触发二次滚动）
            let restoredGlyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: firstVisibleCharLocation, length: 0),
                actualCharacterRange: nil
            )
            let restoredRect = layoutManager.boundingRect(forGlyphRange: restoredGlyphRange, in: textContainer)
            let targetY = restoredRect.origin.y + textContainerOrigin.y - verticalOffset

            // 视口高度取 clipView.bounds：scrollView.visibleRect 会被系统管理的
            // contentInsets 污染（实测高度虚增），导致钳制与可见性判断失真
            let visibleHeight = scrollView.contentView.bounds.height
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            // 系统管理的 contentInsets 提供少量额外可滚动空间，钳制上限读取容忍（不主动设置）
            let bottomInset = scrollView.contentView.contentInsets.bottom

            // 确保插入点仍在视野内：锚点恢复可能把正在输入的最后一行推出视野，
            // 之后按键的自动滚动与位置恢复相互拉扯，造成闪动
            let insertionRange = NSRange(location: selectedRange.location, length: 0)
            var caretTop: CGFloat?
            var caretBottom: CGFloat?
            if let lineRect = textView.lineFragmentBounds(for: insertionRange) {
                caretTop = lineRect.minY + textContainerOrigin.y
                caretBottom = lineRect.maxY + textContainerOrigin.y
            }
            let clampedY = EditorScrollGeometry.restoredOrigin(
                targetY: targetY,
                viewportHeight: visibleHeight,
                documentHeight: documentHeight,
                bottomInset: bottomInset,
                caretTop: caretTop,
                caretBottom: caretBottom,
                bottomOverscroll: textView.bottomOverscroll
            )

            scrollView.contentView.setBoundsOrigin(
                NSPoint(x: scrollView.contentView.bounds.origin.x, y: clampedY)
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)

            // 恢复选中范围（此时滚动位置已固定，suppressAutoScroll 防止二次跳动）
            textView.setSelectedRange(selectedRange)

            // 重新叠加搜索高亮（语法高亮会 setAttributes 全文本重置，覆盖搜索高亮）
            // 延迟一帧执行，确保语法高亮的 endEditing 已完成，避免被覆盖
            if let searchRef = parent.searchRef, !searchRef.allMatchRanges().isEmpty {
                DispatchQueue.main.async {
                    searchRef.reapplySearchHighlights(
                        matchRanges: searchRef.allMatchRanges(),
                        currentIndex: searchRef.currentMatchIndex
                    )
                }
            }

            // 延迟再确认一次滚动位置，防止布局管理器异步调整
            let finalY = clampedY
            DispatchQueue.main.async {
                guard let scrollView = self.scrollView else { return }
                let currentY = scrollView.contentView.bounds.origin.y
                if abs(currentY - finalY) > 1.0 {
                    scrollView.contentView.setBoundsOrigin(
                        NSPoint(x: scrollView.contentView.bounds.origin.x, y: finalY)
                    )
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        }
    }
}

// MARK: - SwiftUI Color → NSColor 转换

extension Color {
    // NSColor(SwiftUI.Color) 创建的是"目录颜色"（catalog color），会根据当前
    // NSAppearance 懒加载解析。codesign --deep 重签名可能破坏 SwiftUI 颜色目录签名，
    // 导致解析失败返回错误色值（如 .clear 或背景色），使文字不可见。
    // 显式转换为 sRGB 色彩空间创建固定颜色，消除动态解析问题。
    var nsColor: NSColor {
        let resolved = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.black
        return NSColor(red: resolved.redComponent, green: resolved.greenComponent,
                       blue: resolved.blueComponent, alpha: resolved.alphaComponent)
    }
}

// MARK: - NSColor 感知亮度

extension NSColor {
    var perceivedBrightness: CGFloat {
        let srgb = usingColorSpace(.sRGB) ?? self
        return 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent
    }
}

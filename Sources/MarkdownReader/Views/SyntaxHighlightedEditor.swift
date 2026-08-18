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

/// 基于 NSTextView 的语法高亮编辑器
/// 支持 Markdown 语法着色、主题色适配、滚动到指定行
struct SyntaxHighlightedEditor: NSViewRepresentable {
    @Binding var content: String
    var fontSize: CGFloat = 13
    var contentPadding: CGFloat = 20
    var scrollToSourceLine: SourceLine?
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
   /// 内容版本号，变化时强制用 ViewModel 内容覆盖编辑器（阻止 firstResponder 回写）
   /// 用于 reload 操作：ViewModel 更新了 content 但 NSTextView 仍持有旧内容
   var contentVersion: Int = 0
    /// 窗口级 Undo 存储（Task 10）。nil 时回退到 window.undoStore。
    var undoStore: WindowUndoStore?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // 手动创建 NSScrollView + NSTextView
        // 不使用 NSTextView.scrollableTextView() 工厂方法，避免其自带约束与 SwiftUI 布局冲突
        let scrollView = NSScrollView()
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

        // 设置边距
        textView.textContainerInset = NSSize(width: contentPadding, height: contentPadding)

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

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
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

        // 更新边距（仅在值变化时更新，避免不必要的布局计算）
        let currentInset = textView.textContainerInset
        let newInset = NSSize(width: contentPadding, height: contentPadding)
        if abs(currentInset.width - newInset.width) > 0.01 || abs(currentInset.height - newInset.height) > 0.01 {
            textView.textContainerInset = newInset
        }

        // 同步底部留白目标高度（fontSize 可能通过设置变化）
        let currentFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let lineHeight = textView.layoutManager?.defaultLineHeight(for: currentFont) ?? (fontSize * 1.5)
        let newOverscroll = ceil(lineHeight)
        if abs(textView.bottomOverscroll - newOverscroll) > 0.01 {
            textView.bottomOverscroll = newOverscroll
        }

        // First responder 管理：切换到 Raw 模式时自动获取焦点
        // 查找面板可见时不抢占焦点，避免搜索输入框失去焦点
        if isActive, !isFindBarVisible, let window = textView.window, window.firstResponder !== textView {
            DispatchQueue.main.async {
                window.makeFirstResponder(textView)
            }
        }

        // 滚动到指定源码行
        if let sourceLine = scrollToSourceLine {
            DispatchQueue.main.async { [context] in
                self.scrollToLineInTextView(textView, sourceLine: sourceLine, content: textView.string)
                // 动画结束后报告一次可见行，覆盖 Raw 内大纲/查找跳转后切模式的回归点。
                context.coordinator.reportVisibleSourceLineOnce()
            }
        }
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

    private func scrollToLineInTextView(_ textView: NSTextView, sourceLine: SourceLine, content: String) {
        guard let charOffset = RawSourceLineOffset.characterOffset(in: content, sourceLine: sourceLine) else {
            return
        }

        let range = NSRange(location: charOffset, length: 0)
        textView.scrollRangeToVisible(range)

        // 1/3 位置效果
        if let scrollView = textView.enclosingScrollView,
           let layoutManager = textView.layoutManager,
           let textContainer = textView.textContainer {

            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let textContainerOrigin = textView.textContainerOrigin
            let targetY = rect.origin.y + textContainerOrigin.y

            let visibleHeight = scrollView.contentView.bounds.height
            let adjustedY = max(0, targetY - visibleHeight / 3.0)

            let documentHeight = scrollView.documentView?.frame.height ?? 0
            // 系统管理的 contentInsets 提供少量额外可滚动空间，钳制上限读取容忍
            let clampedY = min(adjustedY, documentHeight - visibleHeight + scrollView.contentView.contentInsets.bottom)

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scrollView.contentView.animator().setBoundsOrigin(
                    NSPoint(x: scrollView.contentView.bounds.origin.x, y: clampedY)
                )
            }
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

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

/// NSTextView 子类，支持在高亮期间抑制自动滚动
/// 防止 setSelectedRange / 布局变化触发 scrollRangeToVisible 导致跳动
class HighlightableTextView: NSTextView {
    var suppressAutoScroll = false
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
        }
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

/// 编辑器内容同步策略（任务 4）。
///
/// 决定 `updateNSView` 发现 ViewModel 内容与 `NSTextView` 内容不一致时，应采用
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
    var scrollToLine: Int?
    var themeColors: ThemeColors
    /// 当前文件 URL，用于 per-file undo 管理
    var fileURL: URL?
    /// 是否处于活跃状态（Raw 模式），用于自动获取焦点
    var isActive: Bool = false
    var searchRef: TextViewSearchRef?
    /// 查找面板是否可见，可见时不抢占焦点
    var isFindBarVisible: Bool = false
    /// 光标行号变化回调（0-based 行号）
    var onCursorLineNumberChanged: ((Int) -> Void)?
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

        // First responder 管理：切换到 Raw 模式时自动获取焦点
        // 查找面板可见时不抢占焦点，避免搜索输入框失去焦点
        if isActive, !isFindBarVisible, let window = textView.window, window.firstResponder !== textView {
            DispatchQueue.main.async {
                window.makeFirstResponder(textView)
            }
        }

        // 滚动到指定行
        if let line = scrollToLine {
            DispatchQueue.main.async {
                scrollToLineInTextView(textView, line: line, content: textView.string)
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

    private func scrollToLineInTextView(_ textView: NSTextView, line: Int, content: String) {
        let lines = content.components(separatedBy: "\n")
        guard line < lines.count else { return }

        var charOffset = 0
        for i in 0..<line {
            charOffset += lines[i].count + 1
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

            let visibleHeight = scrollView.visibleRect.height
            let adjustedY = max(0, targetY - visibleHeight / 3.0)

            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let clampedY = min(adjustedY, documentHeight - visibleHeight)

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

        init(_ parent: SyntaxHighlightedEditor) {
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

            notifyCursorLineNumber(textView)

            // 防抖高亮：延迟 50ms 重新高亮，避免每次按键都触发
            highlightWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.reapplyHighlights()
            }
            highlightWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = textView else { return }
            notifyCursorLineNumber(textView)
        }

        @MainActor
        private func notifyCursorLineNumber(_ textView: NSTextView) {
            let location = textView.selectedRange().location
            let text = textView.string
            // 1-based line number, consistent with HTML data-line and OutlineItem.lineNumber
            let lineNumber = text[..<text.index(text.startIndex, offsetBy: min(location, text.count))].components(separatedBy: "\n").count
            parent.onCursorLineNumberChanged?(lineNumber)
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

            let visibleHeight = scrollView.visibleRect.height
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let clampedY = max(0, min(targetY, documentHeight - visibleHeight))

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

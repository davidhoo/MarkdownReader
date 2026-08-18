import SwiftUI
import MarkdownReaderKit

/// Markdown 原始文本视图，使用 NSTextView 实现语法高亮着色
/// 像 VS Code / Sublime Text 一样对 Markdown 语法元素进行着色渲染
struct RawMarkdownView: View {
    @Binding var content: String
    var fontSize: CGFloat = 13
    var contentPadding: CGFloat = 20
    var scrollToSourceLine: SourceLine?
    var fileURL: URL?
    /// 是否处于活跃状态（Raw 模式），用于自动获取焦点
    var isActive: Bool = false
    var isFindBarVisible: Bool = false
    var searchRef: TextViewSearchRef?
    var onCursorSourceLineChanged: ((SourceLine) -> Void)?
    /// 内容版本号，变化时强制用 ViewModel 内容覆盖编辑器（阻止回写）
    /// 用于 reload 操作：ViewModel 更新了 content 但 NSTextView 仍持有旧内容
    var contentVersion: Int = 0
    var undoStore: WindowUndoStore?
    @Environment(\.themeColors) private var themeColors

    var body: some View {
        SyntaxHighlightedEditor(
            content: $content,
            fontSize: fontSize,
            contentPadding: contentPadding,
            scrollToSourceLine: scrollToSourceLine,
            themeColors: themeColors,
            fileURL: fileURL,
            isActive: isActive,
            searchRef: searchRef,
            isFindBarVisible: isFindBarVisible,
            onCursorSourceLineChanged: onCursorSourceLineChanged,
            contentVersion: contentVersion,
            undoStore: undoStore
        )
        .background(themeColors.surface)
    }
}

import SwiftUI
import MarkdownReaderKit

/// Markdown 原始文本视图，使用 NSTextView 实现语法高亮着色
/// 像 VS Code / Sublime Text 一样对 Markdown 语法元素进行着色渲染
struct RawMarkdownView: View {
    @Binding var content: String
    var fontSize: CGFloat = 13
    var contentPadding: CGFloat = 20
    var showLineNumbers: Bool = false
    var scrollToSourceLineRequest: DocumentViewModel.SourceScrollRequest?
    var fileURL: URL?
    /// 是否处于活跃状态（Raw 模式），用于自动获取焦点
    var isActive: Bool = false
    var isFindBarVisible: Bool = false
    var searchRef: TextViewSearchRef?
    /// 活跃 Raw 编辑器实际可见行回调，透传给 SyntaxHighlightedEditor。
   var onVisibleSourceLineChanged: ((SourceLine) -> Void)?
   /// 模式切换采样：采集 Raw 编辑器当前视口顶部的源码滚动锚点。
  var onRawScrollAnchorCaptured: ((SourceScrollAnchor) -> Void)?
  /// 切换触发的采样回调，带触发时 token。
  var onRawScrollAnchorTriggered: ((SourceScrollAnchor, UUID) -> Void)?
  /// 切换主动触发采样的请求 token。变化时触发一次 capture。
   var rawCaptureRequest: UUID?
   /// 模式切换定位交接：destination == .raw 时消费，应用锚点后回执。
   var scrollTransfer: ScrollTransfer?
   var onScrollTransferApplied: ((UUID) -> Void)?
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
            showLineNumbers: showLineNumbers,
            scrollToSourceLineRequest: scrollToSourceLineRequest,
            themeColors: themeColors,
            fileURL: fileURL,
            isActive: isActive,
            searchRef: searchRef,
            isFindBarVisible: isFindBarVisible,
           onVisibleSourceLineChanged: onVisibleSourceLineChanged,
          onRawScrollAnchorCaptured: onRawScrollAnchorCaptured,
          onRawScrollAnchorTriggered: onRawScrollAnchorTriggered,
          rawCaptureRequest: rawCaptureRequest,
           scrollTransfer: scrollTransfer,
           onScrollTransferApplied: onScrollTransferApplied,
           contentVersion: contentVersion,
            undoStore: undoStore
        )
        .background(themeColors.surface)
    }
}

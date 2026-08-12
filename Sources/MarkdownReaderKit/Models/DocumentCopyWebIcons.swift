import Foundation

/// 供 WebKit 渲染模式文档复制按钮使用的两个 mask 图标 data URL。
///
/// 纯值类型、`Sendable`、不依赖 AppKit：主 App 的 `SFSymbolWebImageProvider`
/// 在主线程栅格化 SF Symbol 为透明 PNG 并以 `data:image/png;base64,...` 形式
/// 填充本结构，随后跨层传递到 `MarkdownHTMLService` 写入 `:root` CSS 变量。
/// WebKit 以 CSS mask 显示，颜色由 `currentColor` 决定。
///
/// 禁止用空字符串伪装有效资源：可用性必须由 `isAvailable` 显式表达。
public struct DocumentCopyWebIcons: Sendable, Equatable {
    /// 默认态（doc.on.doc）mask data URL。
    public let copyMaskDataURL: String
    /// 成功态（checkmark）mask data URL。
    public let copiedMaskDataURL: String

    /// 两个图标是否均有效。任一为空即视为不可用。
    public var isAvailable: Bool {
        !copyMaskDataURL.isEmpty && !copiedMaskDataURL.isEmpty
    }

    public init(copyMaskDataURL: String, copiedMaskDataURL: String) {
        self.copyMaskDataURL = copyMaskDataURL
        self.copiedMaskDataURL = copiedMaskDataURL
    }

    /// 两个图标均不可用时的占位值。供 PDF/打印、降级与默认参数使用。
    public static let unavailable = DocumentCopyWebIcons(copyMaskDataURL: "", copiedMaskDataURL: "")

    /// 拼入 `:root` 的 CSS custom-property 片段。
    ///
    /// 仅在 `isAvailable` 时输出两个变量；不可用时返回空串，不向页面注入任何
    /// mask 变量。data URL 已是 ASCII base64，无需额外转义。
    public var cssFragment: String {
        guard isAvailable else { return "" }
        return "--mr-document-copy-icon: url(\"\(copyMaskDataURL)\"); "
            + "--mr-document-copied-icon: url(\"\(copiedMaskDataURL)\");"
    }
}

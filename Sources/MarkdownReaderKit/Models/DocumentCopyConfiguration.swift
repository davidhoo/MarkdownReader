import Foundation

/// Quick Look 整篇内容复制的格式。
///
/// 仅决定 Quick Look 预览的「整篇内容复制」语义，不影响主应用阅读（复制渲染富文本）
/// 与 Raw 编辑（复制当前编辑缓冲区原始 Markdown）两处入口。
public enum QuickLookDocumentCopyFormat: String, CaseIterable, Codable, Sendable {
    /// 复制 `#mr-content` 的渲染富文本（标题、强调、表格、代码等结构）。
    case richText
    /// 复制文件 UTF-8 原文，逐字保真、不可执行。
    case rawMarkdown
}

/// 主应用与 Quick Look Extension 共享的偏好 key。
///
/// Quick Look Extension 运行在独立进程，无法访问主应用的 `UserDefaults.standard`，
/// 必须用 `CFPreferencesCopyAppValue(key, applicationID)` 从主应用 preference 域读取。
/// 所有跨进程 key、applicationID 集中在此，避免在 Provider 中复制 key 字符串或默认值。
public enum SharedPreferenceKey {
    /// 主应用 bundle id，也是 CFPreferences 的 applicationID 域。
    public static let applicationID = "com.markdownreader.app"

    /// 界面语言偏好（`LanguagePref.rawValue`，含 `auto`）。
    public static let languagePref = "com.markdownreader.languagePref"
    /// 启用 Quick Look 预览。
    public static let enableQuickLookPreview = "com.markdownreader.enableQuickLookPreview"
    /// 内容一键复制总开关。
    public static let enableDocumentCopy = "com.markdownreader.enableDocumentCopy"
    /// Quick Look 整篇内容复制格式（`QuickLookDocumentCopyFormat.rawValue`）。
    public static let quickLookDocumentCopyFormat = "com.markdownreader.quickLookDocumentCopyFormat"
}

/// Quick Look 预览每次 `preparePreviewOfFile` 时从主应用 preference 域解析的设置快照。
///
/// 纯值类型、`Sendable`、`Equatable`：接收已存储的可选 Bool/String 与显式
/// `detectedLanguage`，把跨进程 CFPreferences 原始值与解析逻辑收敛到 Kit，
/// Provider 只负责类型桥接。缺失/无效值的兼容默认：
/// - 内容一键复制：`true`（不打开扰已有用户）；
/// - Quick Look 格式：`richText`；
/// - 语言偏好：`auto` 用检测语言；非 `auto` 的有效值直接映射。
public struct QuickLookDocumentCopySettings: Equatable, Sendable {
    /// 内容一键复制总开关是否开启。
    public let isDocumentCopyEnabled: Bool
    /// Quick Look 整篇内容复制格式。
    public let format: QuickLookDocumentCopyFormat
    /// 解析后的界面语言（已展开 `auto`）。
    public let language: Language

    /// 从已存储的原始偏好值构造快照。
    ///
    /// - Parameters:
    ///   - storedDocumentCopyEnabled: CFPreferences 中读出的总开关 Bool，`nil` 视为开启。
    ///   - storedFormatRawValue: CFPreferences 中读出的格式 rawValue，无效/缺失回退 `richText`。
    ///   - storedLanguagePrefRawValue: CFPreferences 中读出的语言偏好 rawValue；缺失或 `auto` 用 `detectedLanguage`。
    ///   - detectedLanguage: 当前系统检测语言，用于 `auto`/缺失语言偏好的回退。
    public init(
        storedDocumentCopyEnabled: Bool?,
        storedFormatRawValue: String?,
        storedLanguagePrefRawValue: String?,
        detectedLanguage: Language
    ) {
        self.isDocumentCopyEnabled = storedDocumentCopyEnabled ?? true
        self.format = QuickLookDocumentCopyFormat(rawValue: storedFormatRawValue ?? "") ?? .richText

        if let pref = LanguagePref(rawValue: storedLanguagePrefRawValue ?? "") {
            self.language = pref == .auto ? detectedLanguage : pref.toLanguage ?? detectedLanguage
        } else {
            // 缺失或无效语言偏好视为 auto：使用检测语言。
            self.language = detectedLanguage
        }
    }
}

/// 渲染页面的整篇内容复制配置。
///
/// 把「是否启用、复制格式、原始 Markdown payload、本地化文案、SF Symbol mask 图标」
/// 收敛为单个值类型，供 `MarkdownHTMLService.buildFullHTML` 与
/// `buildContentAwareHTML` 共用同一合同。默认配置为 disabled，保护 PDF 导出
/// 与未迁移入口不出现复制按钮。
public struct DocumentCopyPageConfiguration: Equatable, Sendable {
    /// 是否启用整篇内容复制按钮。
    public let isEnabled: Bool
    /// 复制格式（主阅读固定 richText；Quick Look 由设置决定）。
    public let format: QuickLookDocumentCopyFormat
    /// 仅 `rawMarkdown` 格式需要的 UTF-8 文件原文；其它格式传 `nil`。
    public let rawMarkdown: String?
    /// 普通态按钮文案。
    public let copyTitle: String
    /// 成功态按钮文案。
    public let copiedTitle: String
    /// SF Symbol mask 图标 data URL，不可用时按钮安全 no-op。
    public let webIcons: DocumentCopyWebIcons

    public init(
        isEnabled: Bool,
        format: QuickLookDocumentCopyFormat,
        rawMarkdown: String?,
        copyTitle: String,
        copiedTitle: String,
        webIcons: DocumentCopyWebIcons
    ) {
        self.isEnabled = isEnabled
        self.format = format
        self.rawMarkdown = rawMarkdown
        self.copyTitle = copyTitle
        self.copiedTitle = copiedTitle
        self.webIcons = webIcons
    }

    /// 默认 disabled 配置：不输出任何复制相关属性、payload 或 mask 变量。
    /// 保护 PDF 导出与未迁移调用方。
    public static let disabled = DocumentCopyPageConfiguration(
        isEnabled: false,
        format: .richText,
        rawMarkdown: nil,
        copyTitle: "",
        copiedTitle: "",
        webIcons: .unavailable
    )

    /// 仅 `rawMarkdown` 格式且有非空原文时才编码 base64；其它情况返回 `nil`。
    public var rawMarkdownBase64: String? {
        guard format == .rawMarkdown, let rawMarkdown, !rawMarkdown.isEmpty else { return nil }
        return Data(rawMarkdown.utf8).base64EncodedString()
    }
}

import MarkdownReaderKit
import XCTest

/// 文档复制图标跨层数据合同单测：覆盖 `DocumentCopySymbol` 常量、
/// `DocumentCopyWebIcons` 的可用性与 CSS 片段输出，以及
/// `MarkdownHTMLService.buildFullHTML(renderResult:...)` 的 :root 变量注入。
/// 不依赖 AppKit / WebKit。
final class DocumentCopyWebIconsTests: XCTestCase {

    // MARK: - DocumentCopySymbol 常量

    func testCopySymbolIsDocOnDoc() {
        XCTAssertEqual(DocumentCopySymbol.copy.rawValue, "doc.on.doc")
    }

    func testCopiedSymbolIsCheckmark() {
        XCTAssertEqual(DocumentCopySymbol.copied.rawValue, "checkmark")
    }

    // MARK: - DocumentCopyWebIcons 可用性

    func testUnavailableIsNotAvailable() {
        XCTAssertFalse(DocumentCopyWebIcons.unavailable.isAvailable)
    }

    func testConstructedIconsAreAvailable() {
        let icons = DocumentCopyWebIcons(
            copyMaskDataURL: "data:image/png;base64,Y29weQ==",
            copiedMaskDataURL: "data:image/png;base64,Y2hlY2s="
        )
        XCTAssertTrue(icons.isAvailable)
    }

    // MARK: - CSS 片段输出

    func testUnavailableEmitsNoCSS() {
        XCTAssertEqual(DocumentCopyWebIcons.unavailable.cssFragment, "")
    }

    func testAvailableEmitsBothMaskVariables() {
        let icons = DocumentCopyWebIcons(
            copyMaskDataURL: "data:image/png;base64,Y29weQ==",
            copiedMaskDataURL: "data:image/png;base64,Y2hlY2s="
        )
        let css = icons.cssFragment
        XCTAssertTrue(css.contains("--mr-document-copy-icon:"))
        XCTAssertTrue(css.contains("--mr-document-copied-icon:"))
        XCTAssertTrue(css.contains("data:image/png;base64,Y29weQ=="))
        XCTAssertTrue(css.contains("data:image/png;base64,Y2hlY2s="))
    }

    // MARK: - buildFullHTML :root 注入

    func testBuildFullHTMLInjectsBothMaskVariablesWhenAvailable() {
        let result = MarkdownHTMLService.render("# Title")
        let icons = DocumentCopyWebIcons(
            copyMaskDataURL: "data:image/png;base64,Y29weQ==",
            copiedMaskDataURL: "data:image/png;base64,Y2hlY2s="
        )
        let configuration = DocumentCopyPageConfiguration(
            isEnabled: true,
            format: .richText,
            rawMarkdown: nil,
            copyTitle: "Copy",
            copiedTitle: "Copied",
            webIcons: icons
        )

        let html = MarkdownHTMLService.buildFullHTML(
            renderResult: result,
            themeCSS: "--ink: #ffffff;",
            contentPadding: 20,
            baseURL: nil,
            isDark: true,
            documentCopyConfiguration: configuration
        )

        XCTAssertTrue(html.contains("--mr-document-copy-icon:"))
        XCTAssertTrue(html.contains("--mr-document-copied-icon:"))
        XCTAssertTrue(html.contains("data:image/png;base64,Y29weQ=="))
        XCTAssertTrue(html.contains("data:image/png;base64,Y2hlY2s="))
    }

    func testBuildFullHTMLDefaultsToUnavailableAndEmitsNoMaskVariables() {
        let result = MarkdownHTMLService.render("# Title")

        let html = MarkdownHTMLService.buildFullHTML(
            renderResult: result,
            themeCSS: "--ink: #ffffff;",
            contentPadding: 20,
            baseURL: nil,
            isDark: true
        )

        XCTAssertFalse(html.contains("--mr-document-copy-icon"))
        XCTAssertFalse(html.contains("--mr-document-copied-icon"))
    }

    func testPDFConvenienceEntranceDefaultsToUnavailable() {
        // PDF 便利入口仍可不传配置，且不输出 mask 变量与复制属性。
        let html = MarkdownHTMLService.buildFullHTML(
            content: "# Heading",
            themeCSS: "--ink: #000000;",
            contentPadding: 16,
            baseURL: nil,
            isDark: false
        )

        XCTAssertFalse(html.contains("--mr-document-copy-icon"))
        XCTAssertFalse(html.contains("--mr-document-copied-icon"))
        XCTAssertFalse(html.contains("data-document-copy-enabled"))
    }

    // MARK: - DocumentCopyPageConfiguration 页面属性合同

    func testDisabledConfigurationEmitsNoCopyAttributesOrPayloadOrMaskVariables() {
        let result = MarkdownHTMLService.render("# Title")

        let html = MarkdownHTMLService.buildFullHTML(
            renderResult: result,
            themeCSS: "",
            contentPadding: 20,
            baseURL: nil,
            documentCopyConfiguration: .disabled
        )

        XCTAssertFalse(html.contains("data-document-copy-enabled"))
        XCTAssertFalse(html.contains("data-document-copy-format"))
        XCTAssertFalse(html.contains("data-document-copy-raw-base64"))
        XCTAssertFalse(html.contains("--mr-document-copy-icon"))
    }

    func testEnabledRichTextConfigurationEmitsAttributesAndMaskVariablesAndEscapedLabels() {
        let result = MarkdownHTMLService.render("# Title")
        let icons = DocumentCopyWebIcons(
            copyMaskDataURL: "data:image/png;base64,Y29weQ==",
            copiedMaskDataURL: "data:image/png;base64,Y2hlY2s="
        )
        let configuration = DocumentCopyPageConfiguration(
            isEnabled: true,
            format: .richText,
            rawMarkdown: nil,
            copyTitle: "Copy \"Content\"",
            copiedTitle: "Content <Copied>",
            webIcons: icons
        )

        let html = MarkdownHTMLService.buildFullHTML(
            renderResult: result,
            themeCSS: "",
            contentPadding: 20,
            baseURL: nil,
            documentCopyConfiguration: configuration
        )

        XCTAssertTrue(html.contains("data-document-copy-enabled=\"true\""))
        XCTAssertTrue(html.contains("data-document-copy-format=\"richText\""))
        // 含引号的标题被 XML 属性转义，不得出现裸引号截断属性。
        XCTAssertTrue(html.contains("data-document-copy-title=\"Copy &quot;Content&quot;\""))
        XCTAssertTrue(html.contains("data-document-copied-title=\"Content &lt;Copied&gt;\""))
        XCTAssertFalse(html.contains("data-document-copy-raw-base64"))
        XCTAssertTrue(html.contains("--mr-document-copy-icon:"))
    }

    func testRawMarkdownConfigurationEmitsBase64NotRawContent() {
        let rawMarkdown = "# 中文标题 🎉\n\n</div><script>alert(1)</script>\n"
        let result = MarkdownHTMLService.render(rawMarkdown)
        let configuration = DocumentCopyPageConfiguration(
            isEnabled: true,
            format: .rawMarkdown,
            rawMarkdown: rawMarkdown,
            copyTitle: "Copy",
            copiedTitle: "Copied",
            webIcons: .unavailable
        )

        let html = MarkdownHTMLService.buildFullHTML(
            renderResult: result,
            themeCSS: "",
            contentPadding: 20,
            baseURL: nil,
            documentCopyConfiguration: configuration
        )

        XCTAssertTrue(html.contains("data-document-copy-format=\"rawMarkdown\""))
        XCTAssertTrue(html.contains("data-document-copy-raw-base64="))
        // 原始 Markdown 不得直接出现在属性中；危险标签不得未转义出现。
        XCTAssertFalse(html.contains("data-document-copy-raw-base64=\"</div><script>"))
        // base64 解码后字节保真：用同一编码反解验证。
        let attrPattern = "data-document-copy-raw-base64=\""
        guard let start = html.range(of: attrPattern) else {
            XCTFail("missing raw-base64 attribute")
            return
        }
        let rest = html[start.upperBound...]
        guard let endQuote = rest.firstIndex(of: "\"") else {
            XCTFail("unterminated attribute")
            return
        }
        let base64 = String(html[start.upperBound..<endQuote])
        let decoded = String(decoding: Data(base64Encoded: base64) ?? Data(), as: UTF8.self)
        XCTAssertEqual(decoded, rawMarkdown)
    }

    func testBuildContentAwareHTMLHonorsSameConfigurationContract() {
        let rawMarkdown = "# QL 原文"
        let icons = DocumentCopyWebIcons(
            copyMaskDataURL: "data:image/png;base64,Y29weQ==",
            copiedMaskDataURL: "data:image/png;base64,Y2hlY2s="
        )
        let configuration = DocumentCopyPageConfiguration(
            isEnabled: true,
            format: .rawMarkdown,
            rawMarkdown: rawMarkdown,
            copyTitle: "Copy",
            copiedTitle: "Copied",
            webIcons: icons
        )

        let html = MarkdownHTMLService.buildContentAwareHTML(
            content: rawMarkdown,
            themeCSS: "",
            contentPadding: 20,
            baseURL: nil,
            isDark: false,
            hasMermaid: false,
            hasKaTeX: false,
            inlineImages: false,
            documentCopyConfiguration: configuration
        )

        XCTAssertTrue(html.contains("data-document-copy-enabled=\"true\""))
        XCTAssertTrue(html.contains("data-document-copy-format=\"rawMarkdown\""))
        XCTAssertTrue(html.contains("data-document-copy-raw-base64="))
        XCTAssertTrue(html.contains("--mr-document-copy-icon:"))
    }

    func testBuildContentAwareHTMLDefaultsToDisabled() {
        let html = MarkdownHTMLService.buildContentAwareHTML(
            content: "# Title",
            themeCSS: "",
            contentPadding: 20,
            baseURL: nil,
            isDark: false,
            hasMermaid: false,
            hasKaTeX: false
        )

        XCTAssertFalse(html.contains("data-document-copy-enabled"))
        XCTAssertFalse(html.contains("data-document-copy-raw-base64"))
    }
}

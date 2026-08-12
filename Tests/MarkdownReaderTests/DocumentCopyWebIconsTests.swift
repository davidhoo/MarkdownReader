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

        let html = MarkdownHTMLService.buildFullHTML(
            renderResult: result,
            themeCSS: "--ink: #ffffff;",
            contentPadding: 20,
            baseURL: nil,
            isDark: true,
            documentCopyTitle: "Copy",
            documentCopiedTitle: "Copied",
            documentCopyWebIcons: icons
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
            isDark: true,
            documentCopyTitle: "Copy",
            documentCopiedTitle: "Copied"
        )

        XCTAssertFalse(html.contains("--mr-document-copy-icon"))
        XCTAssertFalse(html.contains("--mr-document-copied-icon"))
    }

    func testPDFConvenienceEntranceDefaultsToUnavailable() {
        // PDF 便利入口仍可不传 Web 图标，且不输出 mask 变量。
        let html = MarkdownHTMLService.buildFullHTML(
            content: "# Heading",
            themeCSS: "--ink: #000000;",
            contentPadding: 16,
            baseURL: nil,
            isDark: false,
            documentCopyTitle: "Copy",
            documentCopiedTitle: "Copied"
        )

        XCTAssertFalse(html.contains("--mr-document-copy-icon"))
        XCTAssertFalse(html.contains("--mr-document-copied-icon"))
    }
}

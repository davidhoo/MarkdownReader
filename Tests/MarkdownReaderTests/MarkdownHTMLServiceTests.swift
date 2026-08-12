import MarkdownReaderKit
import XCTest

/// MarkdownHTMLService 页面壳装配单测：覆盖新增的 `buildFullHTML(renderResult:...)`
/// 重载与原 `buildFullHTML(content:...)` 便利入口的输出合同。不创建 WebView，不联网。
final class MarkdownHTMLServiceTests: XCTestCase {

    // MARK: - 新重载：以 RenderResult 为输入装配页面壳

    func testBuildFullHTMLFromRenderResultEmbedsRenderedBodyAndShell() {
        let result = MarkdownHTMLService.render("# Single parse")

        let html = MarkdownHTMLService.buildFullHTML(
            renderResult: result,
            themeCSS: "--ink: #ffffff;",
            contentPadding: 20,
            baseURL: nil,
            isDark: true,
            documentCopyTitle: "Copy",
            documentCopiedTitle: "Copied"
        )

        XCTAssertTrue(html.contains(result.html))
        XCTAssertTrue(html.contains("id=\"mr-content\""))
        XCTAssertTrue(html.contains("data-document-copy-title=\"Copy\""))
        XCTAssertTrue(html.contains("data-is-dark=\"true\""))
    }

    // MARK: - 旧便利入口：签名与输出合同回归（PDF 等调用方未迁移）

    func testBuildFullHTMLFromContentPreservesShellContract() {
        let html = MarkdownHTMLService.buildFullHTML(
            content: "# Heading",
            themeCSS: "--ink: #000000;",
            contentPadding: 16,
            baseURL: nil,
            isDark: false,
            documentCopyTitle: "Copy",
            documentCopiedTitle: "Copied"
        )

        XCTAssertTrue(html.contains("<h1 id=\"heading-1\""))
        XCTAssertTrue(html.contains("id=\"mr-theme-style\""))
        XCTAssertTrue(html.contains("mr:///js/markdown-reader.js"))
        XCTAssertTrue(html.contains("id=\"mr-content\""))
    }
}

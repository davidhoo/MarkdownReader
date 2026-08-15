import MarkdownReaderKit
import XCTest

// `MarkdownRuntimeRequirements` 是 `MarkdownHTMLService` 的嵌套类型，经此别名在测试中直用。
typealias MarkdownRuntimeRequirements = MarkdownHTMLService.MarkdownRuntimeRequirements


/// MarkdownHTMLService 页面壳装配单测：覆盖新增的 `buildFullHTML(renderResult:...)`
/// 重载与原 `buildFullHTML(content:...)` 便利入口的输出合同。不创建 WebView，不联网。
final class MarkdownHTMLServiceTests: XCTestCase {

    // MARK: - 新重载：以 RenderResult 为输入装配页面壳

    func testBuildFullHTMLFromRenderResultEmbedsRenderedBodyAndShell() {
        let result = MarkdownHTMLService.render("# Single parse")
        let configuration = DocumentCopyPageConfiguration(
            isEnabled: true,
            format: .richText,
            rawMarkdown: nil,
            copyTitle: "Copy",
            copiedTitle: "Copied",
            webIcons: .unavailable
        )

        let html = MarkdownHTMLService.buildFullHTML(
            renderResult: result,
            themeCSS: "--ink: #ffffff;",
            contentPadding: 20,
            baseURL: nil,
            isDark: true,
            documentCopyConfiguration: configuration
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
            isDark: false
        )

        XCTAssertTrue(html.contains("<h1 id=\"heading-1\""))
        XCTAssertTrue(html.contains("id=\"mr-theme-style\""))
        XCTAssertTrue(html.contains("mr:///js/markdown-reader.js"))
        XCTAssertTrue(html.contains("id=\"mr-content\""))
        // PDF 便利入口默认 disabled，不出现复制按钮。
        XCTAssertFalse(html.contains("data-document-copy-enabled"))
    }

    // MARK: - 运行时需求检测：从已渲染 HTML 推导，不复制原始文本探测实现

    func testRuntimeRequirementsForPlainMarkdownNeedNoOptionalRuntime() {
        let result = MarkdownHTMLService.render("# Plain\n\n```swift\nlet x = 1\n```")

        XCTAssertEqual(
            MarkdownRuntimeRequirements.detect(in: result),
            MarkdownRuntimeRequirements(requiresMermaid: false, requiresKaTeX: false)
        )
    }

    func testRuntimeRequirementsDetectMermaidAndSingleDollarMath() {
        let mermaid = MarkdownHTMLService.render("```mermaid\ngraph TD\nA --> B\n```")
        let math = MarkdownHTMLService.render("Euler: $e^{iπ} + 1 = 0$")

        XCTAssertTrue(MarkdownRuntimeRequirements.detect(in: mermaid).requiresMermaid)
        XCTAssertFalse(MarkdownRuntimeRequirements.detect(in: mermaid).requiresKaTeX)
        XCTAssertTrue(MarkdownRuntimeRequirements.detect(in: math).requiresKaTeX)
        XCTAssertFalse(MarkdownRuntimeRequirements.detect(in: math).requiresMermaid)
    }

    func testRuntimeRequirementsDetectLatexFencedBlock() {
        let latex = MarkdownHTMLService.render("```latex\n\\frac{a}{b}\n```")
        XCTAssertTrue(MarkdownRuntimeRequirements.detect(in: latex).requiresKaTeX)
    }

    func testRuntimeRequirementsDetectMixedMermaidAndKaTeX() {
        let mixed = MarkdownHTMLService.render("""
        ```mermaid
        graph TD
        A --> B
        ```

        Euler: $$e^{i\\pi} + 1 = 0$$
        """)

        let requirements = MarkdownRuntimeRequirements.detect(in: mixed)
        XCTAssertTrue(requirements.requiresMermaid)
        XCTAssertTrue(requirements.requiresKaTeX)
    }

    // MARK: - 页面壳资源集：默认完整，按需求条件装配

    func testBuildFullHTMLOmitsOptionalRuntimesWhenNotRequired() {
        let result = MarkdownHTMLService.render("# Plain\n\n```swift\nlet x = 1\n```")

        let html = MarkdownHTMLService.buildFullHTML(
            renderResult: result,
            themeCSS: "",
            contentPadding: 20,
            baseURL: nil,
            runtimeRequirements: .init(requiresMermaid: false, requiresKaTeX: false)
        )

        XCTAssertFalse(html.contains("mr:///js/mermaid.min.js"))
        XCTAssertFalse(html.contains("mr:///js/katex.min.js"))
        XCTAssertFalse(html.contains("mr:///css/katex.min.css"))
        XCTAssertTrue(html.contains("mr:///js/prism-core.min.js"))
        XCTAssertTrue(html.contains("mr:///js/markdown-reader.js"))
    }

    func testBuildFullHTMLDefaultsToAllOptionalRuntimes() {
        let result = MarkdownHTMLService.render("# Plain")

        let html = MarkdownHTMLService.buildFullHTML(
            renderResult: result,
            themeCSS: "",
            contentPadding: 20,
            baseURL: nil
        )

        XCTAssertTrue(html.contains("mr:///js/mermaid.min.js"))
        XCTAssertTrue(html.contains("mr:///js/katex.min.js"))
        XCTAssertTrue(html.contains("mr:///css/katex.min.css"))
    }

    func testBuildFullHTMLIncludesOnlyMermaidWhenMermaidRequired() {
        let result = MarkdownHTMLService.render("```mermaid\ngraph TD\nA --> B\n```")

        let html = MarkdownHTMLService.buildFullHTML(
            renderResult: result,
            themeCSS: "",
            contentPadding: 20,
            baseURL: nil,
            runtimeRequirements: .init(requiresMermaid: true, requiresKaTeX: false)
        )

        XCTAssertTrue(html.contains("mr:///js/mermaid.min.js"))
        XCTAssertFalse(html.contains("mr:///js/katex.min.js"))
        XCTAssertFalse(html.contains("mr:///css/katex.min.css"))
    }

    func testBuildFullHTMLIncludesOnlyKaTeXWhenKaTeXRequired() {
        let result = MarkdownHTMLService.render("$a^2$")

        let html = MarkdownHTMLService.buildFullHTML(
            renderResult: result,
            themeCSS: "",
            contentPadding: 20,
            baseURL: nil,
            runtimeRequirements: .init(requiresMermaid: false, requiresKaTeX: true)
        )

        XCTAssertFalse(html.contains("mr:///js/mermaid.min.js"))
        XCTAssertTrue(html.contains("mr:///js/katex.min.js"))
        XCTAssertTrue(html.contains("mr:///css/katex.min.css"))
    }
}

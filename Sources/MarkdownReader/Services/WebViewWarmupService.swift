import Foundation
import MarkdownReaderKit
import WebKit

/// WebView 预热服务（Task 13）。
///
/// 应用级幂等服务：首次调用创建隐藏 WebPage 预加载 HTML 模板 + JS 库，
/// 后续窗口注册不再重复预热。状态机 `.idle → .warming → .ready` 保证幂等。
@MainActor
final class WebViewWarmupService {

    /// 预热状态。
    enum State: Sendable {
        case idle
        case warming
        case ready
    }

    /// 单例：应用级唯一预热实例。
    static let shared = WebViewWarmupService()

    private(set) var state: State = .idle
    private(set) var warmedPage: WebPage?

    private init() {}

    /// 基础运行时预热 HTML：保留 `markdown.css`、Prism、autoloader 与 `markdown-reader.js`，
    /// 不再预热 Mermaid / KaTeX。普通文档不承担可选运行时的启动解析与内存成本；
    /// 首次打开含图表/公式的文档会按文档自身需求加载可选库。
    static let warmupHTML = """
    <!DOCTYPE html><html><head>
    <link rel="stylesheet" href="mr:///css/markdown.css">
    <script src="mr:///js/prism-core.min.js"></script>
    <script src="mr:///js/prism-autoloader.min.js"></script>
    <script>Prism.plugins.autoloader.languages_path = 'mr:///js/';</script>
    <script src="mr:///js/markdown-reader.js"></script>
    </head><body><div class="markdown-preview"><div id="mr-content"></div></div></body></html>
    """

    /// 幂等预热：首次调用创建 WebPage，后续调用为 no-op。
    /// 返回预热的 WebPage（已 ready 则立即返回，warming 时等待）。
    @discardableResult
    func warmUpIfNeeded() -> WebPage? {
        switch state {
        case .ready:
            return warmedPage
        case .warming:
            return warmedPage
        case .idle:
            break
        }

        state = .warming
        let scheme = URLScheme("mr")!
        let handler = MarkdownURLSchemeHandler(baseURL: nil)
        var configuration = WebPage.Configuration()
        configuration.urlSchemeHandlers[scheme] = handler
        let page = WebPage(configuration: configuration)
        _ = page.load(html: Self.warmupHTML, baseURL: URL(string: "about:blank")!)
        warmedPage = page
        state = .ready
        return page
    }

    /// 测试用：重置状态。
    func resetForTesting() {
        warmedPage = nil
        state = .idle
    }
}

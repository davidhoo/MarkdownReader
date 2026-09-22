import WebKit
import MarkdownReaderKit
import AppKit
import SwiftUI
import os.log

enum PDFExportService {

    private static let logger = Logger(subsystem: "com.markdownreader.app", category: "PDFExportService")

    // MARK: - 共享 JS 等待脚本

    /// 等待所有图片加载完成的 JS 脚本
    private static let jsWaitForImages = """
    (function() {
        const images = document.querySelectorAll('img');
        const promises = Array.from(images).map(img => {
            if (img.complete) return Promise.resolve();
            return new Promise(resolve => {
                img.onload = resolve;
                img.onerror = resolve;
                setTimeout(resolve, 5000);
            });
        });
        return Promise.all(promises);
    })()
    """

    /// 等待 Mermaid 异步渲染完成的 JS 脚本
    private static let jsWaitForMermaid = """
    (function() {
        const containers = document.querySelectorAll('.mermaid-container');
        if (containers.length === 0) return Promise.resolve();
        return new Promise(resolve => {
            let elapsed = 0;
            const interval = setInterval(() => {
                const allDone = Array.from(containers).every(c => c.querySelector('svg') || c.querySelector('.mermaid-error'));
                elapsed += 100;
                if (allDone || elapsed > 10000) {
                    clearInterval(interval);
                    resolve();
                }
            }, 100);
        });
    })()
    """

    /// 等待 PlantUML 异步渲染完成的 JS 脚本
    private static let jsWaitForPlantUML = """
    (function() {
        const containers = document.querySelectorAll('.plantuml-container');
        if (containers.length === 0) return Promise.resolve();
        return new Promise(resolve => {
            let elapsed = 0;
            const interval = setInterval(() => {
                const allDone = Array.from(containers).every(c => c.querySelector('svg') || c.querySelector('.plantuml-error'));
                elapsed += 100;
                if (allDone || elapsed > 15000) {
                    clearInterval(interval);
                    resolve();
                }
            }, 100);
        });
    })()
    """

    // MARK: - 导出方法

    /// 使用主视图中已有的 WebPage 导出 PDF（推荐方案）
    /// WebPage 在视图层级中，内容已完整渲染
    @MainActor
    static func exportFromPage(_ page: WebPage) async throws -> Data {
        while page.isLoading {
            try await Task.sleep(for: .milliseconds(100))
        }
        // 等待 JS 渲染（KaTeX、Mermaid、PlantUML、图片加载等）完成
        try await waitForJSRender(page: page)

        _ = try? await page.callJavaScript("MR.clearSearchHighlight()")

        // 获取页面内容高度用于验证导出完整性
        let contentHeight = try await page.callJavaScript(
            "Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)"
        ) as? Double ?? 0

        let config = WebPage.ExportedContentConfiguration.pdf(
            region: .contents,
            allowTransparentBackground: false
        )
        let data = try await page.exported(as: config)

       // 验证导出结果：如果 PDF 数据量与页面内容高度严重不匹配，
        // 可能是 .contents region 只导出了可视区域，记录警告
        // 使用宽松阈值：每 1000px 至少 2KB，避免纯文本页面误报
        let expectedMinSize = max(Int(contentHeight / 1000.0) * 2_000, 5_000)
        if contentHeight > 0 && data.count < expectedMinSize {
            logger.warning("exportFromPage: PDF data (\(data.count) bytes) seems too small for content height \(contentHeight), .contents region may have truncated output")
        }

        return data
    }

    /// 离屏 WKWebView 导出 PDF（备选方案，当 WebPage 不可用时使用）
    @MainActor
    static func export(html: String, baseURL: URL?, contentWidth: CGFloat, contentPadding: CGFloat) async throws -> Data {
        let handler = MRURLSchemeHandler(baseURL: baseURL)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: "mr")

        let totalWidth = contentWidth + 2 * contentPadding

        let previousKeyWindow = NSApp.keyWindow

        let offscreenWindow = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: totalWidth, height: 10000),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        offscreenWindow.isOpaque = false
        offscreenWindow.backgroundColor = .clear

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: totalWidth, height: 10000), configuration: configuration)
        offscreenWindow.contentView?.addSubview(webView)
        offscreenWindow.orderBack(nil)
        // 不调用 makeKey() 避免抢夺焦点

        let effectiveBaseURL = baseURL ?? URL(string: "about:blank")!
        webView.loadHTMLString(html, baseURL: effectiveBaseURL)

        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(100))
        }
        // 等待 JS readyState
        let _ = try await webView.evaluateJavaScript("document.readyState")
        try await waitForOffscreenJSRender(webView: webView)

        let scrollHeight = try await webView.evaluateJavaScript("Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)") as? Double ?? 10000
        webView.frame.size.height = CGFloat(scrollHeight)

        // 强制 display 触发 WebKit 合成器渲染所有内容
        webView.display()
        try await Task.sleep(for: .milliseconds(200))

        let pdfConfig = WKPDFConfiguration()
        // 不设置 rect，使用默认 null rect，让 WebKit 自动导出完整网页内容并分页

        let data = try await webView.pdf(configuration: pdfConfig)

        webView.removeFromSuperview()
        offscreenWindow.close()
        // 仅在前台窗口未变时恢复焦点，避免覆盖用户在导出期间的窗口切换
        if NSApp.keyWindow == nil || NSApp.keyWindow === offscreenWindow {
            previousKeyWindow?.makeKey()
        }

        return data
    }

    // MARK: - JS 渲染等待

    /// 等待页面内异步 JS 渲染完成（Mermaid、KaTeX、PlantUML、图片加载）— WebPage 版本
    @MainActor
    private static func waitForJSRender(page: WebPage) async throws {
        // 等待 DOMContentLoaded 和基本渲染
        try await Task.sleep(for: .milliseconds(300))

        // 等待所有图片加载完成
        do {
            _ = try await page.callJavaScript(jsWaitForImages)
        } catch {
            logger.warning("waitForJSRender: image wait failed: \(error)")
        }

        // 等待 Mermaid 异步渲染完成
        do {
            _ = try await page.callJavaScript(jsWaitForMermaid)
        } catch {
            logger.warning("waitForJSRender: mermaid wait failed: \(error)")
        }

        // 等待 PlantUML 异步渲染完成
        do {
            _ = try await page.callJavaScript(jsWaitForPlantUML)
        } catch {
            logger.warning("waitForJSRender: plantuml wait failed: \(error)")
        }

        // 额外等待确保布局稳定
        try await Task.sleep(for: .milliseconds(200))
    }

    /// 等待离屏 WKWebView 中异步 JS 渲染完成 — WKWebView 版本
    @MainActor
    private static func waitForOffscreenJSRender(webView: WKWebView) async throws {
        // 基本等待
        try await Task.sleep(for: .milliseconds(500))

        // 等待所有图片加载完成
        do {
            _ = try await webView.evaluateJavaScript(jsWaitForImages)
        } catch {
            logger.warning("waitForOffscreenJSRender: image wait failed: \(error)")
        }

        // 等待 Mermaid 异步渲染完成
        do {
            _ = try await webView.evaluateJavaScript(jsWaitForMermaid)
        } catch {
            logger.warning("waitForOffscreenJSRender: mermaid wait failed: \(error)")
        }

        // 等待 PlantUML 异步渲染完成
        do {
            _ = try await webView.evaluateJavaScript(jsWaitForPlantUML)
        } catch {
            logger.warning("waitForOffscreenJSRender: plantuml wait failed: \(error)")
        }

        // 额外等待确保布局稳定
        try await Task.sleep(for: .milliseconds(200))
    }
}

/// WKURLSchemeHandler 兼容的 mr:// scheme handler
/// 复用 MarkdownURLSchemeHandler 的资源解析逻辑
private final class MRURLSchemeHandler: NSObject, WKURLSchemeHandler {
    let baseURL: URL?
    let resourceSearchPaths: [URL]?
    let hostBundle: Bundle

    init(baseURL: URL?, resourceSearchPaths: [URL]? = nil, hostBundle: Bundle = .main) {
        self.baseURL = baseURL
        self.resourceSearchPaths = resourceSearchPaths
        self.hostBundle = hostBundle
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.scheme == "mr" else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        var path = url.path
        if path.hasPrefix("/") {
            path = String(path.dropFirst())
        }

        let resourceURL = MarkdownResourceLocator.resolveResourceURL(
            path: path,
            baseURL: baseURL,
            resourceSearchPaths: resourceSearchPaths,
            hostBundle: hostBundle
        )

        guard let resourceURL, FileManager.default.fileExists(atPath: resourceURL.path) else {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(Data())
            urlSchemeTask.didFinish()
            return
        }

        do {
            let (data, mimeType) = try MarkdownResourceLocator.loadResourceData(at: resourceURL)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": mimeType]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

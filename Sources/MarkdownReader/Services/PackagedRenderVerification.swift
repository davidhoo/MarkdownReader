import AppKit
import MarkdownReaderKit
import SwiftUI
import WebKit

/// 发布门禁运行的是 .app 内的主程序及其已链接的渲染代码，不重新编译替代品。
/// 仅内部命令行入口使用；独立的非持久化页面，不访问用户文档或设置。
@MainActor
enum PackagedRenderVerification {
    static let argument = "--verify-packaged-render"

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run(reportURL: URL, nonce: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            finish(reportURL: reportURL, nonce: nonce, error: "Render verification timed out")
        }
        Task { @MainActor in
            do {
                let metrics = try await verify()
                watchdog.cancel()
                finish(reportURL: reportURL, nonce: nonce, metrics: metrics)
            } catch {
                watchdog.cancel()
                finish(reportURL: reportURL, nonce: nonce, error: String(describing: error))
            }
        }
        app.run()
        exit(1)
    }

    private static func finish(
        reportURL: URL, nonce: String, metrics: [String: String] = [:], error: String? = nil
    ) -> Never {
        let report: [String: Any] = [
            "schemaVersion": 1,
            "nonce": nonce,
            "bundlePath": Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            "success": error == nil,
            "error": error ?? "",
            "metrics": metrics
        ]
        do {
            // 此文件是调用方显式指定的诊断回执，不经过用户文档的加载/保存管线。
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: reportURL, options: .atomic)
        } catch {
            exit(1)
        }
        exit(error == nil ? 0 : 1)
    }

    private static func verify() async throws -> [String: String] {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        // 与主阅读页面相同，使用当前进程 Bundle.main，绝不注入源码或外部资源路径。
        configuration.urlSchemeHandlers[URLScheme("mr")!] = MarkdownURLSchemeHandler(baseURL: nil)
        let page = WebPage(configuration: configuration)
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WebView(page))
        window.orderBack(nil)
        defer { window.close() }

        let markdown = "# Packaging verification\n\n" + (1...80).map {
            "## Section \($0)\n\n中文 English paragraph \($0)."
        }.joined(separator: "\n\n")
        let colors = ThemeColors.from(PresetThemes.defaultTheme(for: .light))
        let html = MarkdownHTMLService.buildFullHTML(
            content: markdown,
            themeCSS: colors.cssCustomProperties + colors.codeHighlightCSS,
            contentPadding: 20,
            baseURL: nil,
            isDark: false,
            runtimeRequirements: .init(requiresMermaid: false, requiresKaTeX: false)
        )
        _ = page.load(html: html, baseURL: URL(string: "about:blank")!)
        var lastFailure = "Page did not finish loading"
        var ready = false
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            guard !page.isLoading else { continue }
            let result = try await page.callJavaScript("return " + WebViewRenderReadinessPolicy.checkScript)
            switch WebViewRenderReadinessPolicy.evaluate(result: result) {
            case .ready: ready = true
            case .notReady(let reason): lastFailure = reason
            }
            if ready { break }
        }
        guard ready else { throw Failure(description: lastFailure) }

        let updated = MarkdownHTMLService.render(markdown.replacingOccurrences(
            of: "Packaging verification", with: "Updated packaged document"
        ))
        let replacement = try await page.callJavaScript(
            "return MR.replaceContent(html)", arguments: ["html": updated.html]
        )
        guard WebViewContentReplacementCompletionPolicy.shouldComplete(
            javaScriptResult: replacement, isCurrentGeneration: true
        ) else { throw Failure(description: "Content replacement was not acknowledged") }

        let scroll = try await page.callJavaScript("return await MR.scrollToSourceScrollAnchor(100, 0.4)")
        guard scroll as? Bool == true else { throw Failure(description: "Scroll transfer was not acknowledged") }
        guard let metrics = try await page.callJavaScript("""
            return {
                font: getComputedStyle(document.body).fontFamily,
                padding: getComputedStyle(document.querySelector('.markdown-preview')).paddingLeft,
                title: document.querySelector('h1').textContent,
                scrollY: String(window.scrollY),
                sourcePosition: String(MR.captureSourceScrollAnchor().sourcePosition),
                prism: typeof Prism
            }
            """) as? [String: String],
            metrics["font"]?.contains("-apple-system") == true,
            metrics["padding"] == "20px",
            metrics["title"] == "Updated packaged document",
            metrics["prism"] == "object",
            let scrollY = Double(metrics["scrollY"] ?? ""), scrollY > 0,
            let position = Double(metrics["sourcePosition"] ?? ""), position > 1
        else { throw Failure(description: "Rendered styles, content or actual scroll position did not match") }
        return metrics
    }
}

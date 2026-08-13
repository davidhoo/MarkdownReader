import AppKit
import os.log
import QuickLookUI
import MarkdownReaderKit
import WebKit

private let logger = Logger(subsystem: "com.markdownreader.app.QuickLook", category: "PreviewProvider")

@MainActor
final class MarkdownQLPreviewProvider: NSViewController, QLPreviewingController {
    private var webView: WKWebView!
    private var navigationDelegate: QLNavigationDelegate?

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let resourceSearchPaths = Self.resolveResourceSearchPaths()
        let schemeHandler = QLSchemeHandler(resourceSearchPaths: resourceSearchPaths)
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "mr")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    nonisolated func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping @Sendable (Error?) -> Void) {
        // Quick Look Extension 运行在独立进程，从主应用 preference 域读取共享设置快照。
        // Provider 仅作 Bool/String 类型桥接；key、默认值与解析逻辑收敛在 Kit。
        let appID = SharedPreferenceKey.applicationID as CFString
        let enableQLKey = SharedPreferenceKey.enableQuickLookPreview as CFString
        let enableCopyKey = SharedPreferenceKey.enableDocumentCopy as CFString
        let formatKey = SharedPreferenceKey.quickLookDocumentCopyFormat as CFString
        let languagePrefKey = SharedPreferenceKey.languagePref as CFString

        let quickLookEnabled = Self.cfPreferenceBool(
            key: enableQLKey,
            applicationID: appID,
            keyExistsDefault: true
        )
        guard quickLookEnabled else {
            handler(NSError(domain: "com.markdownreader.app.QuickLook", code: 1, userInfo: [NSLocalizedDescriptionKey: "Quick Look preview is disabled"]))
            return
        }

        let enableDocumentCopy = Self.cfPreferenceBool(
            key: enableCopyKey,
            applicationID: appID,
            keyExistsDefault: true
        )
        let storedFormat = Self.cfPreferenceString(key: formatKey, applicationID: appID)
        let storedLanguagePref = Self.cfPreferenceString(key: languagePrefKey, applicationID: appID)
        let detectedLanguage = LanguageService.detectLanguage()

        // 对文件及其所在目录获取 security-scoped access，
        // 确保内联图片（base64）时可以读取同目录下的图片文件
        let fileAccessing = url.startAccessingSecurityScopedResource()
        let directoryURL = url.deletingLastPathComponent()
        let dirAccessing = directoryURL.startAccessingSecurityScopedResource()
        defer {
            if dirAccessing { directoryURL.stopAccessingSecurityScopedResource() }
            if fileAccessing { url.stopAccessingSecurityScopedResource() }
        }

        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            logger.error("Failed to read file: \(error)")
            handler(error)
            return
        }

        logger.info("File loaded, length: \(content.count)")

        let isDark = detectDarkMode()
        let theme = PresetThemes.defaultTheme(for: isDark ? .dark : .light)
        let themeColors = ThemeColors.from(theme)

        let hasMermaid = content.contains("```mermaid")
        let hasKaTeX = content.contains("$$") || content.contains("\\(") || content.contains("\\[") || content.contains("```math")

        logger.info("Content-aware: hasMermaid=\(hasMermaid), hasKaTeX=\(hasKaTeX)")

        let dirURL = url.deletingLastPathComponent()
        logger.info("Previewing file: \(url.path)")
        logger.info("Directory URL: \(dirURL.path)")
        logger.info("fileAccessing: \(fileAccessing), dirAccessing: \(dirAccessing)")

        // 解析设置快照：仅决定 Quick Look 复制格式与总开关；缺失值回退 Kit 兼容默认。
        let settings = QuickLookDocumentCopySettings(
            storedDocumentCopyEnabled: enableDocumentCopy,
            storedFormatRawValue: storedFormat,
            storedLanguagePrefRawValue: storedLanguagePref,
            detectedLanguage: detectedLanguage
        )
        logger.info("Document copy snapshot: enabled=\(settings.isDocumentCopyEnabled), format=\(settings.format.rawValue), language=\(settings.language.rawValue)")

        // SF Symbol mask 图标：主阅读与 Quick Look 共用同一提供者。
        // 必须在主线程栅格化；preparePreviewOfFile 可能不在主线程，故在主线程 closure 内取。
        let copyTitle = L10n.tr(.contentCopy, language: settings.language)
        let copiedTitle = L10n.tr(.contentCopied, language: settings.language)
        let rawPayload = settings.format == .rawMarkdown ? content : nil

        let weakSelf = self
        DispatchQueue.main.async {
            let webIcons = MainActor.assumeIsolated {
                SFSymbolWebImageProvider.shared.documentCopyWebIcons(displayScale: weakSelf.webView?.window?.backingScaleFactor ?? 2)
            }

            let documentCopyConfiguration = DocumentCopyPageConfiguration(
                isEnabled: settings.isDocumentCopyEnabled,
                format: settings.format,
                rawMarkdown: rawPayload,
                copyTitle: copyTitle,
                copiedTitle: copiedTitle,
                webIcons: webIcons
            )

            let html = MarkdownHTMLService.buildContentAwareHTML(
                content: content,
                themeCSS: themeColors.cssCustomProperties + themeColors.codeHighlightCSS,
                contentPadding: 20,
                baseURL: dirURL,
                isDark: isDark,
                hasMermaid: hasMermaid,
                hasKaTeX: hasKaTeX,
                inlineImages: true,
                documentCopyConfiguration: documentCopyConfiguration
            )

            // 诊断日志：检查 HTML 中是否包含 data: URL（内联图片成功）
            let hasInlineData = html.contains("data:image/")
            let hasMrScheme = html.contains("mr:///")
            let hasRawPath = html.contains("screenshot.png") && !html.contains("data:image/") && !html.contains("mr:///")
            logger.info("HTML generated, length: \(html.count), hasInlineData: \(hasInlineData), hasMrScheme: \(hasMrScheme), hasRawPath: \(hasRawPath)")

            // 输出 HTML 前 2000 字符用于调试
            logger.debug("HTML preview: \(html.prefix(2000))")

            let baseURL = url.deletingLastPathComponent()

            guard let webView = weakSelf.webView else {
                logger.error("webView is nil — viewDidLoad not called yet")
                handler(NSError(domain: "com.markdownreader.app.QuickLook", code: 2, userInfo: [NSLocalizedDescriptionKey: "WebView not initialized"]))
                return
            }

            weakSelf.navigationDelegate?.forceCompleteIfPending()

            let navDelegate = QLNavigationDelegate { error in
                handler(error)
            }
            weakSelf.navigationDelegate = navDelegate
            webView.navigationDelegate = navDelegate

            if isDark {
                webView.underPageBackgroundColor = NSColor(red: 0.094, green: 0.094, blue: 0.102, alpha: 1.0)
            }

            webView.loadHTMLString(html, baseURL: baseURL)

            let timeout: TimeInterval = hasMermaid ? 2.0 : 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                navDelegate.forceCompleteIfPending()
            }
        }
    }

    // MARK: - CFPreferences 类型桥接

    /// 从主应用 preference 域读 Bool。Provider 不写默认值、不用自己的 bundle id。
    /// `keyExistsDefault` 为 key 缺失时的回退（启用类设置默认 true，与主应用一致）。
    nonisolated static func cfPreferenceBool(
        key: CFString,
        applicationID: CFString,
        keyExistsDefault: Bool
    ) -> Bool {
        let keyExists = UnsafeMutablePointer<DarwinBoolean>.allocate(capacity: 1)
        defer { keyExists.deallocate() }
        let value = CFPreferencesGetAppBooleanValue(key, applicationID, keyExists)
        return keyExists.pointee.boolValue ? value : keyExistsDefault
    }

    /// 从主应用 preference 域读 String。缺失或类型不符返回 nil。
    nonisolated static func cfPreferenceString(key: CFString, applicationID: CFString) -> String? {
        guard let raw = CFPreferencesCopyAppValue(key, applicationID) else { return nil }
        if let str = raw as? String { return str }
        // NSNumber/CFNumber 等非字符串值视为缺失，避免误用。
        return nil
    }

    private nonisolated static func resolveResourceSearchPaths() -> [URL] {
        let searchPaths: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("MarkdownReader_MarkdownReader.bundle").appendingPathComponent("Resources"),
            Bundle.main.resourceURL?.appendingPathComponent("MarkdownReader_MarkdownReader.bundle").appendingPathComponent("Contents").appendingPathComponent("Resources"),
            Bundle.main.resourceURL,
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources"),
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources")
                .appendingPathComponent("MarkdownReader_MarkdownReader.bundle")
                .appendingPathComponent("Resources"),
        ].compactMap { $0 }

        for path in searchPaths {
            let cssPath = path.appendingPathComponent("css/markdown.css")
            if FileManager.default.fileExists(atPath: cssPath.path) {
                logger.info("Found resources at: \(path.path)")
                return [path]
            }
        }

        logger.error("No resource path found")
        return searchPaths
    }
}

// MARK: - WKURLSchemeHandler for mr://

private final class QLSchemeHandler: NSObject, WKURLSchemeHandler {
    private let resourceSearchPaths: [URL]

    init(resourceSearchPaths: [URL]) {
        self.resourceSearchPaths = resourceSearchPaths
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.scheme == "mr" else {
            urlSchemeTask.didFailWithError(NSError(domain: "com.markdownreader.app.QuickLook", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid scheme"]))
            return
        }

        var path = url.path
        if path.hasPrefix("/") {
            path = String(path.dropFirst())
        }

        let resourceURL = resolveResource(for: path)

        guard let resourceURL, FileManager.default.fileExists(atPath: resourceURL.path) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didFinish()
            return
        }

        do {
            let data = try Data(contentsOf: resourceURL)
            let mimeType = Self.mimeType(for: resourceURL.pathExtension)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mimeType])!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func resolveResource(for path: String) -> URL? {
        let absoluteURL = URL(fileURLWithPath: "/" + path)
        if FileManager.default.fileExists(atPath: absoluteURL.path) {
            return absoluteURL
        }

        for searchPath in resourceSearchPaths {
            let url = searchPath.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "html", "htm": return "text/html"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Navigation Delegate

private final class QLNavigationDelegate: NSObject, WKNavigationDelegate, @unchecked Sendable {
    private let completionHandler: @Sendable (Error?) -> Void
    private var handled = false

    init(completionHandler: @escaping @Sendable (Error?) -> Void) {
        self.completionHandler = completionHandler
    }

    func forceCompleteIfPending() {
        guard !handled else { return }
        handled = true
        logger.info("Navigation delegate timeout — forcing handler completion")
        completionHandler(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !handled else { return }
        handled = true
        logger.info("WebView didFinish navigation")
        completionHandler(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !handled else { return }
        handled = true
        logger.error("WebView didFail: \(error)")
        completionHandler(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !handled else { return }
        handled = true
        logger.error("WebView didFailProvisionalNavigation: \(error)")
        completionHandler(error)
    }
}

private func detectDarkMode() -> Bool {
    if Thread.isMainThread {
        return NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    } else {
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
}

import SwiftUI
import MarkdownReaderKit
import WebKit

class MarkdownNavigationDecider: WebPage.NavigationDeciding {
    /// 回归修复：Markdown 内链不再全局广播 `.openLinkedMarkdownFile`。WebView 通过
    /// 此 closure 把链接 URL 回传给所属 session，再按目录内导航或外部打开规则处理，
    /// 确保内链只由来源窗口处理（需求 §6.7）。
    var onOpenLinkedMarkdownFile: ((URL) -> Void)?

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .allow }

        if url.scheme == "mr" {
            if action.target?.isMainFrame == true,
               action.navigationType == .linkActivated,
               let fileURL = localFileURL(fromMRURL: url),
               FileService.isTreeDisplayExtension(fileURL),
               FileManager.default.fileExists(atPath: fileURL.path) {
                let handler = onOpenLinkedMarkdownFile
                await MainActor.run {
                    handler?(fileURL)
                }
                return .cancel
            }
            return .allow
        }

        if url.scheme == "about" {
            return .allow
        }

        if url.scheme == "file" {
            if action.target?.isMainFrame == true && action.navigationType == .linkActivated {
                let fileURL = url.standardizedFileURL
                if FileService.isTreeDisplayExtension(fileURL),
                   FileManager.default.fileExists(atPath: fileURL.path) {
                    let handler = onOpenLinkedMarkdownFile
                    await MainActor.run {
                        handler?(fileURL)
                    }
                }
                return .cancel
            }
            return .allow
        }

        NSWorkspace.shared.open(url)
        return .cancel
    }

    func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        .allow
    }

    func decideAuthenticationChallengeDisposition(for challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (.performDefaultHandling, nil)
    }

    private func localFileURL(fromMRURL url: URL) -> URL? {
        var path = url.path
        guard !path.isEmpty else { return nil }

        if path.hasPrefix("/") {
            path = String(path.dropFirst())
        }

        // mr:///css/... is a bundled resource, while mr:////Users/... is a local absolute path.
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}

struct WebViewMarkdownView: View {
    let content: String
    let fileURL: URL?
    var contentPadding: CGFloat = 20
    var maxContentWidthFollowsWindow: Bool = false
    var scrollToLine: Int?
    let themeCSS: String
    var isDark: Bool = true
    var searchQuery: String = ""
    var searchCaseSensitive: Bool = false
    var searchWholeWord: Bool = false
    var searchCurrentIndex: Int = -1
    var isFindBarVisible: Bool = false
    /// 内容版本号，变化时强制完全重新加载（而非增量更新）
    /// 用于 reload 操作等场景，即使 content 值未变也需刷新视图
    var contentVersion: Int = 0
    var onVisibleHeadingChanged: ((MarkdownHTMLService.HeadingInfo?) -> Void)?
    var onVisibleLineChanged: ((Int) -> Void)?
    /// 回归修复：本窗口命令目标（由 WindowSceneHost 注入）。视图直接在其上注册 zoom
    /// handler，不再发布独立 focusedSceneValue 覆盖焦点路由，也不在内部临时 @FocusedValue 反查。
    var commandTarget: WindowCommandTarget?

    /// 回归修复：Markdown 内链回调。WebView 把点击的本地 Markdown 链接回传给所属
    /// session，按目录内导航或外部打开规则处理，不再全局广播。
    var onOpenLinkedMarkdownFile: ((URL) -> Void)?

    @Environment(\.language) private var language

    @State private var page = WebPage()
    @Binding var exportedPage: WebPage?
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var lastLoadedContent: String = ""
    @State private var lastLoadedURL: URL?
    @State private var scrollSyncTimer: Timer?
    @State private var isConfigured = false
    @State private var currentHeadings: [MarkdownHTMLService.HeadingInfo] = []
    @State private var pendingScrollToLine: Int?
    @State private var zoomLevel: CGFloat = 1.0
    /// 上次处理的 contentVersion，用于检测程序化内容更新（reload/load）
    @State private var lastHandledContentVersion: Int = 0
    /// 持有 navigationDecider，使其生命周期与视图一致，便于注入内链 closure。
    @State private var navigationDecider = MarkdownNavigationDecider()

    var body: some View {
        WebView(page)
            .webViewScrollPosition($scrollPosition)
            .webViewLinkPreviews(.disabled)
            .webViewTextSelection(.enabled)
            .webViewBackForwardNavigationGestures(.disabled)
            .webViewMagnificationGestures(.enabled)
            .webViewContentBackground(.hidden)
            .webViewOnScrollGeometryChange(for: Int.self, of: { geometry in
                Int(geometry.contentOffset.y)
            }, action: { _, _ in
                scheduleScrollSync()
            })
            .onAppear {
                exportedPage = page
                configureAndLoad()
                registerZoomHandler()
                syncLinkedFileHandler()
            }
            .onChange(of: content) { _, newContent in
                if newContent == lastLoadedContent { return }
                if lastLoadedContent.isEmpty {
                    loadContent()
                } else {
                    updateContent(newContent)
                    lastLoadedContent = newContent
                }
            }
            .onChange(of: contentVersion) { _, newVersion in
                // contentVersion 变化意味着 ViewModel 程序化更新了内容（如 reload）
                // 即使 content 值与 lastLoadedContent 相同，也需要完全重新加载
                if newVersion != lastHandledContentVersion {
                    lastHandledContentVersion = newVersion
                    loadContent()
                }
            }
            .onChange(of: fileURL) { _, _ in
                loadContent()
            }
            .onChange(of: scrollToLine) { _, newValue in
                if let line = newValue {
                    if page.isLoading {
                        pendingScrollToLine = line
                    } else {
                        scrollToLineNumber(line)
                    }
                }
            }
            .onChange(of: page.isLoading) { _, isLoading in
                if !isLoading, let line = pendingScrollToLine {
                    pendingScrollToLine = nil
                    scrollToLineNumber(line)
                }
                if !isLoading && zoomLevel != 1.0 {
                    restoreZoom()
                }
            }
            .onChange(of: themeCSS) { _, _ in
                updateThemeCSS(themeCSS)
            }
            .onChange(of: contentPadding) { _, newValue in
                updateContentPadding(newValue)
            }
            .onChange(of: maxContentWidthFollowsWindow) { _, newValue in
                updateMaxContentWidth(newValue)
            }
            .onChange(of: searchQuery) { _, _ in
                updateSearchHighlight()
            }
            .onChange(of: searchCaseSensitive) { _, _ in
                updateSearchHighlight()
            }
            .onChange(of: searchWholeWord) { _, _ in
                updateSearchHighlight()
            }
            .onChange(of: searchCurrentIndex) { _, newValue in
                setSearchCurrent(newValue)
            }
            .onChange(of: isFindBarVisible) { _, isVisible in
                if !isVisible {
                    clearSearchHighlight()
                }
                syncDocumentCopyButtonVisibility()
            }
            .onChange(of: language) { _, _ in
                updateDocumentCopyButtonLabels()
            }
            .onDisappear {
                scrollSyncTimer?.invalidate()
                // 视图退出：清理 zoom handler，避免残留回调指向已销毁视图。
                commandTarget?.zoomHandler = nil
                navigationDecider.onOpenLinkedMarkdownFile = nil
            }
            // 回归修复：zoom handler 直接注册到注入的本窗口命令目标，
            // 不再发布独立 focusedSceneValue（覆盖会抢夺焦点路由）。
            .onChange(of: commandTarget?.objectIdentifier) { _, _ in registerZoomHandler() }
            .environment(\.openURL, OpenURLAction { url in
                NSWorkspace.shared.open(url)
                return .handled
            })
    }

    /// 把 zoom handler 注册到注入的本窗口命令目标（由 WindowSceneHost 发布并绑定本 session）。
    private func registerZoomHandler() {
        commandTarget?.zoomHandler = { cmd in
            switch cmd {
            case .in: applyZoom(zoomLevel + 0.1)
            case .out: applyZoom(zoomLevel - 0.1)
            case .reset: applyZoom(1.0)
            }
        }
    }

    /// 把父视图注入的内链 closure 同步到 navigationDecider。
    /// 仅在 WebPage 尚未创建时安全（navigationDecider 为 @State，始终存活）。
    private func syncLinkedFileHandler() {
        navigationDecider.onOpenLinkedMarkdownFile = onOpenLinkedMarkdownFile
    }

    private func configureAndLoad() {
        guard !isConfigured else {
            loadContent()
            return
        }
        isConfigured = true

        let scheme = URLScheme("mr")!
        let handler = MarkdownURLSchemeHandler(baseURL: fileURL?.deletingLastPathComponent())
        var configuration = WebPage.Configuration()
        configuration.urlSchemeHandlers[scheme] = handler

        navigationDecider.onOpenLinkedMarkdownFile = onOpenLinkedMarkdownFile
        page = WebPage(
            configuration: configuration,
            navigationDecider: navigationDecider
        )
        exportedPage = page

        loadContent()
    }

    private func loadContent() {
        let baseURL = fileURL?.deletingLastPathComponent()
        let html = MarkdownHTMLService.buildFullHTML(
            content: content,
            themeCSS: themeCSS,
            contentPadding: contentPadding,
            maxContentWidthFollowsWindow: maxContentWidthFollowsWindow,
            baseURL: baseURL,
            isDark: isDark,
            documentCopyTitle: L10n.tr(.contentCopy, language: language),
            documentCopiedTitle: L10n.tr(.contentCopied, language: language)
        )

        let renderResult = MarkdownHTMLService.render(content, baseURL: baseURL)
        currentHeadings = renderResult.headings

        scrollPosition = ScrollPosition(edge: .top)

        let effectiveBaseURL = baseURL ?? URL(string: "about:blank")!
        _ = page.load(html: html, baseURL: effectiveBaseURL)
        lastLoadedContent = content
        lastLoadedURL = fileURL

        // 页面加载后同步查找栏显隐（查找栏打开期间渲染按钮隐藏）。
        syncDocumentCopyButtonVisibility()

        if let line = scrollToLine {
            pendingScrollToLine = line
            let capturedLine = line
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [capturedLine] in
                if pendingScrollToLine == capturedLine {
                    pendingScrollToLine = nil
                    scrollToLineNumber(capturedLine)
                }
            }
        }
    }

    private func updateContent(_ content: String) {
        let baseURL = fileURL?.deletingLastPathComponent()
        let renderResult = MarkdownHTMLService.render(content, baseURL: baseURL)
        currentHeadings = renderResult.headings

        let escapedHTML = renderResult.html
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "'", with: "\\'")

        Task { @MainActor [escapedHTML] in
            _ = try? await page.callJavaScript("MR.replaceContent('\(escapedHTML)')")
        }
    }

    private func scrollToLineNumber(_ lineNumber: Int) {
        Task { @MainActor [lineNumber] in
            _ = try? await page.callJavaScript("MR.scrollToLine(\(lineNumber))")
        }
    }

    private func updateThemeCSS(_ themeCSS: String) {
        let escaped = themeCSS
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "'", with: "\\'")

        Task { @MainActor [escaped] in
            do {
                _ = try await page.callJavaScript("document.getElementById('mr-theme-style').textContent = '\(escaped)'")
                _ = try await page.callJavaScript("MR.rerenderMermaid()")
                _ = try await page.callJavaScript("MR.rerenderPlantUML()")
            } catch {
                print("[MarkdownReader] updateThemeCSS failed: \(error)")
            }
        }
    }

    private func updateContentPadding(_ padding: CGFloat) {
        Task { @MainActor [padding] in
            _ = try? await page.callJavaScript("document.documentElement.style.setProperty('--content-padding', '\(padding)px')")
        }
    }

    private func updateMaxContentWidth(_ followsWindow: Bool) {
        let value = followsWindow ? "none" : "980px"
        Task { @MainActor [value] in
            _ = try? await page.callJavaScript("document.documentElement.style.setProperty('--content-max-width', '\(value)')")
        }
    }

    private func updateSearchHighlight() {
        guard isFindBarVisible else {
            clearSearchHighlight()
            return
        }
        let escapedQuery = searchQuery
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        Task { @MainActor [escapedQuery] in
            _ = try? await page.callJavaScript("MR.highlightSearch('\(escapedQuery)', \(searchCaseSensitive), \(searchWholeWord), \(searchCurrentIndex))")
        }
    }

    private func setSearchCurrent(_ index: Int) {
        guard isFindBarVisible && !searchQuery.isEmpty else { return }
        Task { @MainActor [index] in
            _ = try? await page.callJavaScript("MR.setSearchCurrent(\(index))")
        }
    }

    private func clearSearchHighlight() {
        Task { @MainActor in
            _ = try? await page.callJavaScript("MR.clearSearchHighlight()")
        }
    }

    /// 查找栏显隐同步到 DOM 按钮：查找栏打开期间渲染复制按钮隐藏且不接收点击。
    private func syncDocumentCopyButtonVisibility() {
        let hidden = isFindBarVisible
        Task { @MainActor [hidden] in
            _ = try? await page.callJavaScript("MR.setDocumentCopyButtonHidden(\(hidden))")
        }
    }

    /// 运行时语言变化时更新 DOM 按钮的普通/成功标签，不整页重新加载。
    private func updateDocumentCopyButtonLabels() {
        let normal = L10n.tr(.contentCopy, language: language).jsEscaped
        let copied = L10n.tr(.contentCopied, language: language).jsEscaped
        Task { @MainActor [normal, copied] in
            _ = try? await page.callJavaScript("MR.setDocumentCopyButtonLabels('\(normal)', '\(copied)')")
        }
    }

    private func scheduleScrollSync() {
        scrollSyncTimer?.invalidate()
        scrollSyncTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            Task { @MainActor in
                if let lineResult = try? await page.callJavaScript("MR.getTopVisibleLine()"),
                   let lineNumber = lineResult as? Int {
                    onVisibleLineChanged?(lineNumber)
                }

                guard let result = try? await page.callJavaScript("MR.getVisibleHeading()") else {
                    onVisibleHeadingChanged?(nil)
                    return
                }
                let dict = result as? [String: Any]
                guard let id = dict?["id"] as? String,
                      let level = dict?["level"] as? Int,
                      let title = dict?["title"] as? String,
                      let lineNumber = dict?["lineNumber"] as? Int else {
                    onVisibleHeadingChanged?(nil)
                    return
                }
                onVisibleHeadingChanged?(MarkdownHTMLService.HeadingInfo(id: id, level: level, title: title, lineNumber: lineNumber))
            }
        }
    }

    // MARK: - 缩放

    /// 恢复缩放级别（页面加载完成后调用）
    private func restoreZoom() {
        let rounded = String(format: "%.2f", zoomLevel)
        Task { @MainActor [rounded] in
            _ = try? await page.callJavaScript("document.body.style.zoom = '\(rounded)'")
        }
    }

    private func applyZoom(_ level: CGFloat) {
        let clamped = min(max(level, 0.3), 3.0)
        zoomLevel = clamped
        let rounded = String(format: "%.2f", clamped)
        Task { @MainActor [rounded] in
            _ = try? await page.callJavaScript("document.body.style.zoom = '\(rounded)'")
        }
    }
}

private extension String {
    /// 转义用于 JS 单引号字符串字面量的字符，与现有 updateContent/updateThemeCSS 转义一致。
    var jsEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}

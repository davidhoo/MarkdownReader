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
    /// 当前屏幕像素倍率。变化时经既有 `requestRender()` 走 latest-wins 调度整页重载，
    /// 以便注入对应倍率的缓存复制图标 CSS 变量。不绕过 scheduler 直接 `page.load`。
    @Environment(\.displayScale) private var displayScale

    @State private var page = WebPage()
    @Binding var exportedPage: WebPage?
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var scrollSyncTimer: Timer?
    @State private var isConfigured = false
    @State private var pendingScrollToLine: Int?
    @State private var zoomLevel: CGFloat = 1.0
    /// 渲染触发收敛：latest-wins 请求世代。`fileURL`/`content`/`contentVersion`
    /// 任一变化只递增世代；`.task(id:)` 在一次 `Task.yield()` 后对最终快照执行唯一渲染。
    @State private var renderScheduler = WebViewRenderScheduler()
    /// 上一次已应用的渲染快照，用于决策下一次动作（loadPage/replaceContent/none）。
    @State private var lastAppliedRender: WebViewRenderSnapshot?
    /// 当前进行中的增量 `MR.replaceContent` 写入任务，新请求或视图消失时取消。
    @State private var contentReplacementTask: Task<Void, Never>?
    /// 持有 navigationDecider，使其生命周期与视图一致，便于注入内链 closure。
    @State private var navigationDecider = MarkdownNavigationDecider()

    var body: some View {
        webViewBase
            .onAppear { handleAppear() }
            .onChange(of: content) { _, _ in requestRender() }
            .onChange(of: contentVersion) { _, _ in requestRender() }
            .onChange(of: fileURL) { _, _ in requestRender() }
            .onChange(of: scrollToLine) { _, newValue in handleScrollToLineChange(newValue) }
            .onChange(of: page.isLoading) { _, isLoading in handleLoadingChange(isLoading) }
            .onChange(of: themeCSS) { _, _ in updateThemeCSS(themeCSS) }
            .onChange(of: contentPadding) { _, newValue in updateContentPadding(newValue) }
            .onChange(of: maxContentWidthFollowsWindow) { _, newValue in updateMaxContentWidth(newValue) }
            .onChange(of: searchQuery) { _, _ in updateSearchHighlight() }
            .onChange(of: searchCaseSensitive) { _, _ in updateSearchHighlight() }
            .onChange(of: searchWholeWord) { _, _ in updateSearchHighlight() }
            .onChange(of: searchCurrentIndex) { _, newValue in setSearchCurrent(newValue) }
            .onChange(of: isFindBarVisible) { _, isVisible in handleFindBarVisibleChange(isVisible) }
            .onChange(of: language) { _, _ in updateDocumentCopyButtonLabels() }
            .onChange(of: displayScale) { _, _ in requestRender() }
            .modifier(WebViewRenderLifecycleModifier(
                commandTargetIdentifier: commandTarget?.objectIdentifier,
                onDisappear: handleDisappear,
                onCommandTargetChange: registerZoomHandler,
                renderGeneration: renderScheduler.generation,
                renderTaskBody: renderTaskBody
            ))
            .environment(\.openURL, OpenURLAction { url in
                NSWorkspace.shared.open(url)
                return .handled
            })
    }

    /// WebView 及其纯展示配置，不含事件 modifier。拆分以减轻整条 View 表达式的类型推断负担。
    private var webViewBase: some View {
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
    }

    /// `.onAppear` 入口：导出 page、配置 WebPage、注册 zoom handler、同步内链 closure，并发起首次渲染请求。
    private func handleAppear() {
        exportedPage = page
        configurePageIfNeeded()
        registerZoomHandler()
        syncLinkedFileHandler()
        requestRender()
    }

    /// `scrollToLine` 变化：页面加载中暂存，否则立即滚动。
    private func handleScrollToLineChange(_ newValue: Int?) {
        guard let line = newValue else { return }
        if page.isLoading {
            pendingScrollToLine = line
        } else {
            scrollToLineNumber(line)
        }
    }

    /// `page.isLoading` 变化：加载完成后处理待滚动行号并恢复缩放。
    private func handleLoadingChange(_ isLoading: Bool) {
        if !isLoading, let line = pendingScrollToLine {
            pendingScrollToLine = nil
            scrollToLineNumber(line)
        }
        if !isLoading && zoomLevel != 1.0 {
            restoreZoom()
        }
    }

    /// `.task(id: generation)` 的任务体，抽成独立函数以减轻整条 View 表达式的类型推断负担。
    private func renderTaskBody() async {
        let generation = renderScheduler.generation
        await Task.yield()
        guard !Task.isCancelled, renderScheduler.accepts(generation), isConfigured else { return }
        applyLatestRender(generation: generation)
    }

    /// `.onDisappear` 清理：取消增量写入、失效世代、清理 zoom handler 与内链 closure。
    private func handleDisappear() {
        scrollSyncTimer?.invalidate()
        contentReplacementTask?.cancel()
        contentReplacementTask = nil
        _ = renderScheduler.request()
        commandTarget?.zoomHandler = nil
        navigationDecider.onOpenLinkedMarkdownFile = nil
    }

    /// `isFindBarVisible` 变化：关闭时清除查找高亮，并同步渲染复制按钮显隐。
    private func handleFindBarVisibleChange(_ isVisible: Bool) {
        if !isVisible {
            clearSearchHighlight()
        }
        syncDocumentCopyButtonVisibility()
    }

    /// 请求一次渲染：取消进行中的增量写入并递增世代。不解析 Markdown，也不调用 `page.load`。
    /// 三个文档输入的 `.onChange` 都只调用此方法，把“何时渲染”收敛到一个世代。
    private func requestRender() {
        contentReplacementTask?.cancel()
        contentReplacementTask = nil
        _ = renderScheduler.request()
    }

    /// 对当前输入构造最终快照，按策略执行唯一渲染动作。
    /// 必须在 `.task(id:)` 的 `Task.yield()` 之后调用，确保读到的是同一轮状态收敛后的值。
    private func applyLatestRender(generation: UInt) {
        let next = WebViewRenderSnapshot(
            fileURL: fileURL,
            content: content,
            contentVersion: contentVersion
        )

        switch WebViewRenderPolicy.action(previous: lastAppliedRender, next: next) {
        case .none:
            return
        case .loadPage:
            contentReplacementTask?.cancel()
            contentReplacementTask = nil
            lastAppliedRender = next
            loadContent(next)
        case .replaceContent:
            lastAppliedRender = next
            replaceContent(next, generation: generation)
        }
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

    /// 仅创建并配置 `WebPage`、导出引用、注入 navigation decider；不直接加载内容。
    /// 首次配置后内容加载由 `requestRender()` → `.task(id:)` → `applyLatestRender` 统一调度。
    private func configurePageIfNeeded() {
        guard !isConfigured else { return }
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
    }

    private func loadContent(_ snapshot: WebViewRenderSnapshot) {
        let baseURL = snapshot.fileURL?.deletingLastPathComponent()
        let renderResult = MarkdownHTMLService.render(snapshot.content, baseURL: baseURL)
        // 仅整页加载时获取缓存图标：按当前屏幕倍率取 data URL，传给页面壳注入 :root CSS 变量。
        // replaceContent、updateThemeCSS、copy click、5 秒 timer 与 mr:// handler 均不调用提供者。
        let documentCopyWebIcons = SFSymbolWebImageProvider.shared.documentCopyWebIcons(
            displayScale: displayScale
        )
        let html = MarkdownHTMLService.buildFullHTML(
            renderResult: renderResult,
            themeCSS: themeCSS,
            contentPadding: contentPadding,
            maxContentWidthFollowsWindow: maxContentWidthFollowsWindow,
            baseURL: baseURL,
            isDark: isDark,
            documentCopyTitle: L10n.tr(.contentCopy, language: language),
            documentCopiedTitle: L10n.tr(.contentCopied, language: language),
            documentCopyWebIcons: documentCopyWebIcons
        )

        scrollPosition = ScrollPosition(edge: .top)

        let effectiveBaseURL = baseURL ?? URL(string: "about:blank")!
        _ = page.load(html: html, baseURL: effectiveBaseURL)

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

    private func replaceContent(_ snapshot: WebViewRenderSnapshot, generation: UInt) {
        let baseURL = snapshot.fileURL?.deletingLastPathComponent()
        let renderResult = MarkdownHTMLService.render(snapshot.content, baseURL: baseURL)

        let escapedHTML = renderResult.html.jsEscaped

        contentReplacementTask?.cancel()
        contentReplacementTask = Task { @MainActor [escapedHTML, generation, page] in
            guard !Task.isCancelled, renderScheduler.accepts(generation) else { return }
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

/// 承载 WebView 生命周期末尾的几个 modifier（onDisappear / 命令目标变化 /
/// 渲染触发收敛的 `.task(id:)`）。抽成 `ViewModifier` 以打断主 `body` 的超长
/// modifier 链，让 Swift 类型推断在合理时间内完成。
private struct WebViewRenderLifecycleModifier: ViewModifier {
    let commandTargetIdentifier: ObjectIdentifier?
    let onDisappear: () -> Void
    let onCommandTargetChange: () -> Void
    let renderGeneration: UInt
    let renderTaskBody: () async -> Void

    func body(content: Content) -> some View {
        content
            .onDisappear { onDisappear() }
            // 回归修复：zoom handler 直接注册到注入的本窗口命令目标，
            // 不再发布独立 focusedSceneValue（覆盖会抢夺焦点路由）。
            .onChange(of: commandTargetIdentifier) { _, _ in onCommandTargetChange() }
            // 渲染触发收敛：三个文档输入只递增世代；本任务在一次 yield 后对最终快照
            // 执行唯一渲染动作，旧世代随新请求自动取消。
            .task(id: renderGeneration) {
                await renderTaskBody()
            }
    }
}

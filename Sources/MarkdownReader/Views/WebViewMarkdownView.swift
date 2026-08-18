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
    /// 内容一键复制总开关：控制阅读页右上角整篇内容复制按钮。运行时切换走
    /// 无重载 JavaScript bridge（`MR.setDocumentCopyButtonEnabled`），不触发 requestRender。
    var documentCopyEnabled: Bool = true
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

    /// 当前是否处于渲染模式。控制渲染闸门：仅 Rendered 时纯 content 变更才请求渲染，
    /// 进入 Rendered 时请求一次最新快照；切回 Raw 不请求。
    var isRenderedMode: Bool = false
    /// 实际 `requestRender()` 发起时同步报告该请求所属世代。DetailView 用它调用
    /// `RenderedModeTransitionState.track(generation:)`，使 Raw→Rendered 过渡等待真实目标。
    var onRenderRequested: ((UInt) -> Void)?
    /// 目标渲染世代的内容已更新或整页加载已结束时报告。仅匹配 `onRenderRequested`
    /// 报告过的世代才会触发；过期世代、取消或 JavaScript 失败均不报告。DetailView 用它
    /// 调用 `RenderedModeTransitionState.completeIfMatching(generation:)` 结束过渡。
    var onRenderGenerationCompleted: ((UInt) -> Void)?

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
    /// 当前整页已加载的运行时需求。增量替换前与下一份 HTML 的需求比较：需求变化即提升为
    /// 整页加载（新出现的图表/公式需对应脚本，已加载库无法卸载）。仅整页加载路径写入。
    @State private var loadedRuntimeRequirements: MarkdownHTMLService.MarkdownRuntimeRequirements?
    /// 当前进行中的增量 `MR.replaceContent` 写入任务，新请求或视图消失时取消。
    @State private var contentReplacementTask: Task<Void, Never>?
    /// 整页加载中等待完成的渲染世代。`page.load` 时记录，`page.isLoading` 变 false 且
    /// 世代仍最新时通过 `onRenderGenerationCompleted` 报告。用于 loadPage 完成边界。
    @State private var pendingLoadCompletionGeneration: UInt?
    /// `.none`（快照无变化）时若页面仍在加载而暂存的等待世代。页面加载结束后补报完成，
    /// 保证 Raw→Rendered→Raw→Rendered（未修改）这类无内容变化的过渡也能闭合。
    @State private var pendingNoneCompletionGeneration: UInt?
    /// 持有 navigationDecider，使其生命周期与视图一致，便于注入内链 closure。
    @State private var navigationDecider = MarkdownNavigationDecider()

    var body: some View {
        webViewBase
            .modifier(DocumentCopyEventsModifier(
                isDocumentCopyEnabled: documentCopyEnabled,
                isFindBarVisible: isFindBarVisible,
                language: language,
                onAppear: handleAppear,
                onDocumentCopyEnabledChange: handleDocumentCopyEnabledChange,
                onFindBarVisibleChange: handleFindBarVisibleChange,
                onUpdateDocumentCopyButtonLabels: updateDocumentCopyButtonLabels
            ))
            .modifier(DocumentContentEventsModifier(
                content: content,
                contentVersion: contentVersion,
                fileURL: fileURL,
                isRenderedMode: isRenderedMode,
                scrollToLine: scrollToLine,
                pageIsLoading: page.isLoading,
                themeCSS: themeCSS,
                contentPadding: contentPadding,
                maxContentWidthFollowsWindow: maxContentWidthFollowsWindow,
                searchQuery: searchQuery,
                searchCaseSensitive: searchCaseSensitive,
                searchWholeWord: searchWholeWord,
                searchCurrentIndex: searchCurrentIndex,
                displayScale: displayScale,
                onRequestRenderIfNeeded: requestRenderIfNeeded,
                onScrollToLineChange: handleScrollToLineChange,
                onLoadingChange: handleLoadingChange,
                onUpdateThemeCSS: updateThemeCSS,
                onUpdateContentPadding: updateContentPadding,
                onUpdateMaxContentWidth: updateMaxContentWidth,
                onUpdateSearchHighlight: updateSearchHighlight,
                onSetSearchCurrent: setSearchCurrent
            ))
            .modifier(WebViewRenderLifecycleModifier(
                commandTargetIdentifier: commandTarget?.objectIdentifier,
                onDisappear: handleDisappear,
                onCommandTargetChange: registerZoomHandler,
                renderGeneration: renderScheduler.generation,
                renderTaskBody: renderTaskBody
            ))
            .modifier(OpenExternalLinksModifier())
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

    /// `page.isLoading` 变化：加载完成后处理待滚动行号、恢复缩放，并补报等待中的完成世代。
    /// loadPage 与 `.none`（页面仍在加载时）分别记录 `pendingLoadCompletionGeneration` 和
    /// `pendingNoneCompletionGeneration`，二者可能属于不同世代；加载结束时各自校验
    /// `renderScheduler.accepts(gen)` 后报告——失效世代被忽略，最新世代补报完成。
    private func handleLoadingChange(_ isLoading: Bool) {
        if !isLoading, let line = pendingScrollToLine {
            pendingScrollToLine = nil
            scrollToLineNumber(line)
        }
        if !isLoading && zoomLevel != 1.0 {
            restoreZoom()
        }
        guard !isLoading else { return }

        if let loadGen = pendingLoadCompletionGeneration {
            pendingLoadCompletionGeneration = nil
            if renderScheduler.accepts(loadGen) {
                onRenderGenerationCompleted?(loadGen)
            }
        }
        if let noneGen = pendingNoneCompletionGeneration {
            pendingNoneCompletionGeneration = nil
            if renderScheduler.accepts(noneGen) {
                onRenderGenerationCompleted?(noneGen)
            }
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
    /// 清除两个 pending 完成世代，禁止已销毁页面回调 DetailView。
    private func handleDisappear() {
        scrollSyncTimer?.invalidate()
        contentReplacementTask?.cancel()
        contentReplacementTask = nil
        pendingLoadCompletionGeneration = nil
        pendingNoneCompletionGeneration = nil
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
    /// 同步报告该请求所属世代，供 DetailView 在 Raw→Rendered 过渡中 `track(generation:)`。
    @discardableResult
    private func requestRender() -> UInt {
        contentReplacementTask?.cancel()
        contentReplacementTask = nil
        let generation = renderScheduler.request()
        onRenderRequested?(generation)
        return generation
    }

    /// 渲染闸门入口：按变更种类与当前模式决定是否请求。`.content` 仅 Rendered 请求；
    /// `.fileURL`/`.contentVersion` 始终请求（预热隐藏 WebView）；`.displayMode` 仅进入
    /// Rendered 请求。闸门否决时直接返回，不递增世代、不报告，隐藏 WebView 保持上次快照。
    private func requestRenderIfNeeded(change: WebViewRenderChange) {
        guard WebViewRenderEligibility.shouldRequest(
            change: change, isRenderedMode: isRenderedMode
        ) else { return }
        _ = requestRender()
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
            // 快照无变化：页面已加载完成则立即报告该世代完成；仍在加载则暂存，
            // 待 `page.isLoading` 变 false 时补报。否则 Raw→Rendered→Raw→Rendered
            // （未修改）这类无内容变化的过渡会因等不到 complete 而永远卡住。
            reportCompletionIfIdle(generation: generation)
            return
        case .loadPage:
            contentReplacementTask?.cancel()
            contentReplacementTask = nil
            lastAppliedRender = next
            loadContent(next, generation: generation)
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

    private func loadContent(_ snapshot: WebViewRenderSnapshot, generation: UInt) {
        let baseURL = snapshot.fileURL?.deletingLastPathComponent()
        let renderResult = MarkdownHTMLService.render(snapshot.content, baseURL: baseURL)
        let runtimeRequirements = MarkdownHTMLService.MarkdownRuntimeRequirements.detect(in: renderResult)
        loadPage(snapshot, renderResult: renderResult, runtimeRequirements: runtimeRequirements, generation: generation)
    }

    /// 用已完成的单次 `RenderResult` 与检测到的运行时需求整页装配。不再次调用 `render`。
    /// 完整加载路径与运行时升级路径共用，确保每次整页加载都记录 `loadedRuntimeRequirements`。
    /// `generation` 记入 `pendingLoadCompletionGeneration`，待 `page.isLoading` 变 false 且世代
    /// 仍最新时通过 `onRenderGenerationCompleted` 报告——这是 loadPage 的真实完成边界。
    private func loadPage(
        _ snapshot: WebViewRenderSnapshot,
        renderResult: MarkdownHTMLService.RenderResult,
        runtimeRequirements: MarkdownHTMLService.MarkdownRuntimeRequirements,
        generation: UInt
    ) {
        let baseURL = snapshot.fileURL?.deletingLastPathComponent()
        loadedRuntimeRequirements = runtimeRequirements
        // 仅整页加载时获取缓存图标：按当前屏幕倍率取 data URL，传给页面壳注入 :root CSS 变量。
        // replaceContent、updateThemeCSS、copy click、5 秒 timer 与 mr:// handler 均不调用提供者。
        let documentCopyWebIcons = SFSymbolWebImageProvider.shared.documentCopyWebIcons(
            displayScale: displayScale
        )
        let documentCopyConfiguration = DocumentCopyPageConfiguration(
            isEnabled: documentCopyEnabled,
            format: .richText,
            rawMarkdown: nil,
            copyTitle: L10n.tr(.contentCopy, language: language),
            copiedTitle: L10n.tr(.contentCopied, language: language),
            webIcons: documentCopyWebIcons
        )
        let html = MarkdownHTMLService.buildFullHTML(
            renderResult: renderResult,
            themeCSS: themeCSS,
            contentPadding: contentPadding,
            maxContentWidthFollowsWindow: maxContentWidthFollowsWindow,
            baseURL: baseURL,
            isDark: isDark,
            documentCopyConfiguration: documentCopyConfiguration,
            runtimeRequirements: runtimeRequirements
        )

        scrollPosition = ScrollPosition(edge: .top)

        let effectiveBaseURL = baseURL ?? URL(string: "about:blank")!
        // 整页加载开始：记录等待完成的世代。`page.isLoading` 变 false 且世代仍最新时
        // 经 `handleLoadingChange` 报告完成。先置 pending 再 load，避免加载过快在回调
        // 注册前结束导致漏报。
        pendingNoneCompletionGeneration = nil
        pendingLoadCompletionGeneration = generation
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

        // 单次解析后即检测需求：与已加载需求比较，变化则复用该 RenderResult 整页加载，
        // 不调用 MR.replaceContent，也不创建 contentReplacementTask，且不重复解析 Markdown。
        let requirements = MarkdownHTMLService.MarkdownRuntimeRequirements.detect(in: renderResult)
        if WebViewRuntimePolicy.action(
            current: loadedRuntimeRequirements,
            next: requirements
        ) == .loadPage {
            loadPage(snapshot, renderResult: renderResult, runtimeRequirements: requirements, generation: generation)
            return
        }

        let escapedHTML = renderResult.html.jsEscaped

        contentReplacementTask?.cancel()
        contentReplacementTask = Task { @MainActor [escapedHTML, generation, page] in
            guard !Task.isCancelled, renderScheduler.accepts(generation) else { return }
            // 仅当 `MR.replaceContent` 成功返回且世代仍最新时才报告完成。
            // `try?` 把 JS 抛错转为 nil：nil 则视为失败，不报告——避免过渡完成时
            // 用户看到旧渲染或空白（固定合同 3）。取消、过期 generation 同样不报告。
            let result = try? await page.callJavaScript("MR.replaceContent('\(escapedHTML)')")
            guard result != nil, !Task.isCancelled, renderScheduler.accepts(generation) else { return }
            onRenderGenerationCompleted?(generation)
        }
    }

    /// 快照无变化（`.none`）时的完成报告：页面空闲则立即报告，否则暂存世代，
    /// 待 `page.isLoading` 变 false 时由 `handleLoadingChange` 补报。
    private func reportCompletionIfIdle(generation: UInt) {
        if page.isLoading {
            pendingNoneCompletionGeneration = generation
        } else {
            onRenderGenerationCompleted?(generation)
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

    /// 总开关变化：无重载地增删 DOM 按钮，不触发 requestRender/page.load/MR.replaceContent。
    /// 关闭时 JS 端 clear timer + remove 按钮；开启时幂等创建，并按当前查找栏状态同步显隐。
    private func handleDocumentCopyEnabledChange(_ isEnabled: Bool) {
        Task { @MainActor [isEnabled] in
            _ = try? await page.callJavaScript("MR.setDocumentCopyButtonEnabled(\(isEnabled))")
            // 创建/移除后仍需遵守查找栏显隐约定。
            _ = try? await page.callJavaScript("MR.setDocumentCopyButtonHidden(\(isFindBarVisible))")
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

/// 把外部链接交给系统打开。抽成独立 `ViewModifier` 以打断主 `body` 的超长 modifier 链，
/// 让 Swift 类型推断在合理时间内完成。
private struct OpenExternalLinksModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
    }
}

/// 内容复制相关 onChange。单独成 modifier 以减轻主 body 类型推断负担。
private struct DocumentCopyEventsModifier: ViewModifier {
    let isDocumentCopyEnabled: Bool
    let isFindBarVisible: Bool
    let language: Language
    let onAppear: () -> Void
    let onDocumentCopyEnabledChange: (Bool) -> Void
    let onFindBarVisibleChange: (Bool) -> Void
    let onUpdateDocumentCopyButtonLabels: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { onAppear() }
            .onChange(of: isFindBarVisible) { _, isVisible in onFindBarVisibleChange(isVisible) }
            .onChange(of: language) { _, _ in onUpdateDocumentCopyButtonLabels() }
            .onChange(of: isDocumentCopyEnabled) { _, isEnabled in onDocumentCopyEnabledChange(isEnabled) }
    }
}

/// 正文内容/查找/缩放相关 onChange。单独成 modifier 以减轻主 body 类型推断负担。
private struct DocumentContentEventsModifier: ViewModifier {
    let content: String
    let contentVersion: Int
    let fileURL: URL?
    let isRenderedMode: Bool
    let scrollToLine: Int?
    let pageIsLoading: Bool
    let themeCSS: String
    let contentPadding: CGFloat
    let maxContentWidthFollowsWindow: Bool
    let searchQuery: String
    let searchCaseSensitive: Bool
    let searchWholeWord: Bool
    let searchCurrentIndex: Int
    let displayScale: CGFloat
    /// 按变更种类走渲染闸门：`.content` 仅 Rendered 请求；`.fileURL`/`.contentVersion`/
    /// `.displayScale` 始终请求（预热隐藏 WebView）；`.displayMode` 仅进入 Rendered 请求。
    let onRequestRenderIfNeeded: (WebViewRenderChange) -> Void
    let onScrollToLineChange: (Int?) -> Void
    let onLoadingChange: (Bool) -> Void
    let onUpdateThemeCSS: (String) -> Void
    let onUpdateContentPadding: (CGFloat) -> Void
    let onUpdateMaxContentWidth: (Bool) -> Void
    let onUpdateSearchHighlight: () -> Void
    let onSetSearchCurrent: (Int) -> Void

    func body(content: Content) -> some View {
        content
            // 纯内容变更：仅 Rendered 时请求渲染；Raw 编辑期闸门否决，隐藏 WebView 保持快照。
            .onChange(of: self.content) { _, _ in onRequestRenderIfNeeded(.content) }
            .onChange(of: contentVersion) { _, _ in onRequestRenderIfNeeded(.contentVersion) }
            .onChange(of: fileURL) { _, _ in onRequestRenderIfNeeded(.fileURL) }
            // isRenderedMode false→true：请求一次最新快照；true→false：闸门否决，不请求。
            .onChange(of: isRenderedMode) { _, _ in onRequestRenderIfNeeded(.displayMode) }
            .onChange(of: scrollToLine) { _, newValue in onScrollToLineChange(newValue) }
            .onChange(of: pageIsLoading) { _, isLoading in onLoadingChange(isLoading) }
            .onChange(of: themeCSS) { _, _ in onUpdateThemeCSS(themeCSS) }
            .onChange(of: contentPadding) { _, newValue in onUpdateContentPadding(newValue) }
            .onChange(of: maxContentWidthFollowsWindow) { _, newValue in onUpdateMaxContentWidth(newValue) }
            .onChange(of: searchQuery) { _, _ in onUpdateSearchHighlight() }
            .onChange(of: searchCaseSensitive) { _, _ in onUpdateSearchHighlight() }
            .onChange(of: searchWholeWord) { _, _ in onUpdateSearchHighlight() }
            .onChange(of: searchCurrentIndex) { _, newValue in onSetSearchCurrent(newValue) }
            // 屏幕倍率变化需重载注入对应缓存图标 CSS 变量，始终请求，与模式无关。
            .onChange(of: displayScale) { _, _ in onRequestRenderIfNeeded(.contentVersion) }
    }
}

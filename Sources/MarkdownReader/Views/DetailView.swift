import SwiftUI
import MarkdownReaderKit
import WebKit

/// 仅绘制左侧边缘（含圆角）的 Shape，用于左边框描边
struct LeftEdgeShape: Shape {
    var radius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // 从顶部开始，绘制左上圆角
        path.move(to: CGPoint(x: radius, y: 0))
        path.addArc(
            tangent1End: CGPoint(x: 0, y: 0),
            tangent2End: CGPoint(x: 0, y: radius),
            radius: radius
        )
        // 左侧直线
        path.addLine(to: CGPoint(x: 0, y: rect.height - radius))
        // 左下圆角
        path.addArc(
            tangent1End: CGPoint(x: 0, y: rect.height),
            tangent2End: CGPoint(x: radius, y: rect.height),
            radius: radius
        )
        return path
    }
}

/// 右侧主体区容器（圆角），包含内容区和底部项目状态栏
struct DetailView: View {
    let appViewModel: AppViewModel
    let documentViewModel: DocumentViewModel
    let fileTreeViewModel: FileTreeViewModel
    let settings: SettingsModel
    var undoStore: WindowUndoStore?
    /// Task 11：导出 PDF / 另存面板以所属窗口为 sheet 宿主，避免抢夺其它窗口焦点。
    var owningWindow: NSWindow?
    /// 回归修复：本窗口命令目标（由 WindowSceneHost 发布并注入）。视图层直接在其上
    /// 注册 PDF/查找/重新加载/缩放 handler，不再发布独立 focusedSceneValue 覆盖焦点路由，
    /// 也不在按钮 closure 内临时 @FocusedValue 反查。
    var commandTarget: WindowCommandTarget?
    /// 回归修复：所属 session，用于 Markdown 内链按目录内/外部规则路由（需求 §6.7）。
    weak var session: WindowSession?
    @Environment(\.language) private var language
    @Environment(\.themeColors) private var themeColors

    /// 查找替换 ViewModel
    @State private var findReplaceViewModel = FindReplaceViewModel()

    /// NSTextView 搜索引用，用于 Raw 模式搜索/高亮/替换
    @State private var textViewSearchRef = TextViewSearchRef()

    /// 刷新确认弹窗状态
    @State private var showReloadAlert = false
    @State private var dontRemindAgain = false

    @State private var showUnsupportedFileAlert = false
    @State private var unsupportedFileExt = ""

    /// 渲染模式下当前可见标题的行号（用于大纲高亮同步）
    @State private var activeOutlineLineNumber: Int?

    /// PDF 导出失败提示
    @State private var showExportPDFError = false

    /// 顶部路径复制反馈（独立于内容区复制，5 秒对号）
    @State private var pathCopyState = CopyFeedbackState()
    @State private var pathCopyResetTask: Task<Void, Never>?

    /// 编辑模式内容区复制反馈（独立 5 秒对号）
    @State private var contentCopyState = CopyFeedbackState()
    @State private var contentCopyResetTask: Task<Void, Never>?

    /// 导出用的 WebPage 引用
    @State private var exportedPage: WebPage?


    var body: some View {
        VStack(spacing: 0) {
            titleBar

            Rectangle().fill(themeColors.border).frame(height: 1)

            // 内容区域
            contentArea
                .overlay {
                    // Task 11：拖拽 hover 直接读所属 session 的 appViewModel 状态（窗口级）。
                    if appViewModel.isDropTargeted {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(themeColors.accent, lineWidth: 2)
                            .padding(4)
                    }
                }
        }
        .background(themeColors.surface, in: .rect(
            topLeadingRadius: 10,
            bottomLeadingRadius: 10,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0
        ))
        .clipShape(.rect(
            topLeadingRadius: 10,
            bottomLeadingRadius: 10,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0
        ))
        .background(themeColors.bgSubtle)
        .overlay(
            LeftEdgeShape(radius: 10)
                .stroke(themeColors.border, lineWidth: 1)
        )
        // Task 11：拖拽 hover 状态经所属 session 的 appViewModel 绑定，不再用全局通知。
        // unsupported 提示已移除全局通知路径（FileDropOverlayView 不再发 unsupportedFileTypeDropped）；
        // 不支持文件类型的拒绝由 Coordinator 在路由时处理，此处保留 alert 但无广播触发者。
        .alert(L10n.tr(.exportPDFFailed, language: language), isPresented: $showExportPDFError) {
            Button(L10n.tr(.confirm, language: language), role: .cancel) {}
        }
        .alert(
            L10n.tr(.unsupportedFileTypeAlert, language: language, args: ["ext": unsupportedFileExt]),
            isPresented: $showUnsupportedFileAlert
        ) {
            Button(L10n.tr(.confirm, language: language), role: .cancel) {}
        }
        // 回归修复：注册 UI 上下文 handler 到本窗口命令目标（替代覆盖式 focusedSceneValue）。
        .onAppear { registerCommandHandlers() }
        .onChange(of: commandTarget?.objectIdentifier) { _, _ in registerCommandHandlers() }
        .onDisappear {
            // 视图退出：清理 handler，避免残留回调指向已销毁视图。
            commandTarget?.findHandler = nil
            commandTarget?.reloadHandler = nil
            commandTarget?.exportPDFHandler = nil
            // 视图退出：取消复制反馈计时并隐藏对号。
            invalidateCopyFeedback()
        }
    }

    // MARK: - TitleBar

    @ViewBuilder
    private var titleBar: some View {
        HStack(spacing: 0) {
            if !appViewModel.isSidebarVisible {
                TrafficLightButtons()
                    .padding(.leading, 12)

                Button {
                    appViewModel.toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 14))
                        .foregroundStyle(themeColors.fgSecondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr(.titleBarToggleSidebar, language: language))
                .padding(.leading, 8)

               Button {
                    // 回归修复：直接调用本窗口命令目标，不通过 FocusedValue 反查。
                    commandTarget?.perform(.openPanel)
               } label: {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(themeColors.fgSecondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr(.titleBarOpen, language: language))
                .padding(.leading, 4)

                // 新建文件按钮（始终可用，无需打开目录）
                Button {
                    // 回归修复：直接调用本窗口命令目标，不通过 FocusedValue 反查。
                    commandTarget?.perform(.newFile)
                } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 14))
                        .foregroundStyle(themeColors.fgSecondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr(.titleBarNewFile, language: language))
                .padding(.leading, 4)
            }

            // 文件路径或 Untitled 标识（左对齐，仅在有文档时显示）
            if documentViewModel.hasDocument {
                if documentViewModel.isUntitled {
                    Text(documentViewModel.fileName)
                        .font(.system(size: 12))
                        .foregroundStyle(themeColors.fgMuted)
                        .padding(.leading, 12)
                } else if let path = documentViewModel.currentFileURL?.path {
                    Text(path)
                        .font(.system(size: 12))
                        .foregroundStyle(themeColors.fgMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 12)

                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        if pasteboard.setString(path, forType: .string) {
                            beginPathCopyFeedback()
                        }
                    } label: {
                        Image(systemName: pathCopyState.isShowingSuccess ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .frame(width: 14)
                            .foregroundStyle(pathCopyState.isShowingSuccess ? themeColors.success : themeColors.fgMuted)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr(pathCopyState.isShowingSuccess ? .titleBarPathCopied : .titleBarCopyPath, language: language))
                    .padding(.leading, 2)
                }
            }

            Spacer()

            // 渲染 / 编辑模式切换（纯文本模式下隐藏，因为只有编辑模式可用）
            if documentViewModel.hasDocument && !documentViewModel.isPlainTextMode {
                Picker("", selection: Binding(
                    get: { documentViewModel.displayMode },
                    set: { documentViewModel.switchDisplayMode($0) }
                )) {
                    Text(L10n.tr(.displayModeRendered, language: language)).tag(DisplayMode.rendered)
                    Text(L10n.tr(.displayModeRaw, language: language)).tag(DisplayMode.raw)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .padding(.trailing, 8)
            }
            // 操作按钮组与大纲图标下对齐，横向间隔一致
            HStack(alignment: .bottom, spacing: 8) {
                // 刷新按钮（文件被外部修改时显示，在保存按钮左侧）
                if documentViewModel.hasDocument && documentViewModel.isFileModifiedExternally {
                    Button {
                        handleReloadButtonTapped()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14))
                            .foregroundStyle(themeColors.accent)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr(.titleBarReload, language: language))
                }

                // 保存按钮（在渲染模式切换右侧）
                if documentViewModel.hasDocument {
                    Button {
                        // 回归修复：直接调用本窗口命令目标，不通过 FocusedValue 反查。
                        commandTarget?.perform(.save)
                    } label: {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(documentViewModel.isDirty ? themeColors.accent : themeColors.fgMuted)
                    }
                    .buttonStyle(.plain)
                    .disabled(!documentViewModel.isDirty)
                    .help(L10n.tr(.titleBarSave, language: language))

                    Button {
                        exportPDF()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14))
                            .foregroundStyle(themeColors.fgMuted)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr(.titleBarExportPDF, language: language))
                }

                // 大纲切换按钮（始终显示在 titlebar 最右侧）
                Button {
                    appViewModel.toggleOutline()
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 14))
                        .foregroundStyle(outlineButtonColor)
                }
                .buttonStyle(.plain)
                .disabled(!documentViewModel.hasDocument)
                .help(L10n.tr(.titleBarToggleOutline, language: language))
            }
            .padding(.trailing, 12)
        }
        .frame(height: 50)
        .background(WindowDragArea())
        .alert(L10n.tr(.fileModifiedExternallyTitle, language: language), isPresented: $showReloadAlert) {
            Button(L10n.tr(.fileModifiedExternallyReload, language: language), role: .destructive) {
                Task {
                    await documentViewModel.reloadFromDisk()
                }
                if dontRemindAgain {
                    settings.skipFileModifiedAlert = true
                }
            }
            Button(L10n.tr(.unsavedCancel, language: language), role: .cancel) {
                dontRemindAgain = false
            }
        } message: {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr(.fileModifiedExternallyMessage, language: language))
                Toggle(L10n.tr(.fileModifiedExternallyDontRemind, language: language), isOn: $dontRemindAgain)
            }
        }
    }

    // MARK: - 复制反馈

    /// 顶部路径复制成功后启动 5 秒对号。连续点击时取消旧 task、以最新 generation
    /// 重新计时，旧计时不会提前清掉新对号。
    private func beginPathCopyFeedback() {
        pathCopyResetTask?.cancel()
        let generation = pathCopyState.begin()
        pathCopyResetTask = Task { @MainActor [generation] in
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            pathCopyState.reset(ifCurrent: generation)
        }
    }

    /// 编辑模式内容复制成功后启动 5 秒对号，语义同路径复制。
    private func beginContentCopyFeedback() {
        contentCopyResetTask?.cancel()
        let generation = contentCopyState.begin()
        contentCopyResetTask = Task { @MainActor [generation] in
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            contentCopyState.reset(ifCurrent: generation)
        }
    }

    /// 编辑模式复制：写入当前原始 Markdown。仅复制真实成功后才显示对号。
    /// 不调用 Select All，不改动 NSTextView selection 或 undo 栈。
    private func copyRawContent() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(documentViewModel.content, forType: .string) {
            beginContentCopyFeedback()
        }
    }

    /// 取消所有复制反馈计时并隐藏对号。模式/文件/视图生命周期变化时调用，
    /// 防止旧文档的成功态残留到新文档。
    private func invalidateCopyFeedback() {
        pathCopyResetTask?.cancel()
        pathCopyResetTask = nil
        pathCopyState.invalidate()
        contentCopyResetTask?.cancel()
        contentCopyResetTask = nil
        contentCopyState.invalidate()
    }

    // MARK: - 内容区

    @ViewBuilder
    private var contentArea: some View {
        if documentViewModel.hasDocument {
            documentContentWithOutline
        } else if appViewModel.rootDirectory == nil && !appViewModel.isSingleFileMode {
            WelcomeView(appViewModel: appViewModel, commandTarget: commandTarget)
        } else if let error = documentViewModel.fileError {
            ErrorView(
                icon: "exclamationmark.triangle",
                message: error.localizedDescription
            )
        } else if documentViewModel.isLoading {
            // 仅在首次加载（无已有文档）时显示进度指示器
            ProgressView()
                .tint(themeColors.fgSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !appViewModel.isSingleFileMode && fileTreeViewModel.isEmptyDirectory {
            ErrorView(
                icon: "folder",
                message: L10n.tr(.emptyDirectoryMessage, language: language)
            )
        } else {
            selectFilePlaceholder
        }
    }

    // MARK: - 文档内容（带大纲分栏）

    @ViewBuilder
    private var documentContentWithOutline: some View {
        HStack(spacing: 0) {
            // 左侧：Markdown 主内容区
            documentContentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 右侧：大纲侧边栏
            if appViewModel.isOutlineVisible {
                OutlineResizeHandle(appViewModel: appViewModel)

                outlineSidebar
                    .frame(width: appViewModel.outlineWidth)
            }
        }
    }

    // MARK: - 大纲侧边栏

    /// 大纲按钮颜色：激活时强调色，有文档时次要色，无文档时弱化色
    /// 处理刷新按钮点击
    private func handleReloadButtonTapped() {
        if documentViewModel.isDirty && !settings.skipFileModifiedAlert {
            showReloadAlert = true
        } else {
            Task {
                await documentViewModel.reloadFromDisk()
            }
        }
    }

    private func exportPDF() {
        guard documentViewModel.hasDocument else { return }
        let language = settings.languagePref.resolvedLanguage
        let stem = URL(fileURLWithPath: documentViewModel.fileName).deletingPathExtension().lastPathComponent
        let suggestedName = stem.isEmpty ? "Untitled.pdf" : "\(stem).pdf"
        let defaultDir = settings.lastOpenedDirectory
            ?? documentViewModel.currentFileURL?.deletingLastPathComponent()
        let hostWindow = owningWindow

        Task {
            guard let saveURL = await OpenPanelHelper.showExportPDFPanel(
                for: hostWindow,
                language: language,
                defaultDirectory: defaultDir,
                suggestedName: suggestedName
            ) else { return }
            await exportPDF(to: saveURL)
        }
    }

    private func exportPDF(to url: URL) async {
        do {
            let data: Data
            if let page = exportedPage, documentViewModel.displayMode == .rendered {
                data = try await PDFExportService.exportFromPage(page)
            } else {
                let baseURL = documentViewModel.currentFileURL?.deletingLastPathComponent()
                let contentWidth: CGFloat
                if settings.maxContentWidthFollowsWindow {
                    contentWidth = max(980, NSApp.keyWindow?.contentRect(forFrameRect: NSApp.keyWindow?.frame ?? .zero).width ?? 980)
                } else {
                    contentWidth = 980
                }
                let html = MarkdownHTMLService.buildFullHTML(
                    content: documentViewModel.content,
                    themeCSS: themeColors.cssCustomProperties + themeColors.codeHighlightCSS,
                    contentPadding: settings.contentPaddingPoints,
                    maxContentWidthFollowsWindow: settings.maxContentWidthFollowsWindow,
                    baseURL: baseURL,
                    isDark: settings.resolvedThemeType == .dark
                )
                data = try await PDFExportService.export(
                    html: html,
                    baseURL: baseURL,
                    contentWidth: contentWidth,
                    contentPadding: settings.contentPaddingPoints
                )
            }
            try data.write(to: url)
        } catch {
            showExportPDFError = true
        }
    }

    private var outlineButtonColor: Color {
        if appViewModel.isOutlineVisible {
            return themeColors.accent
        } else if documentViewModel.hasDocument {
            return themeColors.fgSecondary
        } else {
            return themeColors.fgMuted
        }
    }

    private var outlineSidebar: some View {
        OutlineView(
            items: documentViewModel.outlineItems,
            onSelect: { item in
                documentViewModel.requestScrollToLine(item.lineNumber)
            },
            activeLineNumber: activeOutlineLineNumber
        )
    }

    // MARK: - 查找替换

    private func openFindBar() {
        if !appViewModel.isFindBarVisible {
            appViewModel.showFindBar()
        }
    }

    private func openFindAndReplace() {
        if !appViewModel.isFindBarVisible {
            appViewModel.showFindBar()
        }
        findReplaceViewModel.expandReplace()
    }

    private func closeFindBar() {
        textViewSearchRef.clearSearchHighlights()
        findReplaceViewModel.clearSearch()
        appViewModel.hideFindBar()
    }

    private func performSearch() {
        let text = documentViewModel.content
        findReplaceViewModel.performSearch(in: text)

        if documentViewModel.displayMode == .raw {
            if findReplaceViewModel.hasResults {
                textViewSearchRef.reapplySearchHighlights(
                    matchRanges: findReplaceViewModel.matchRanges,
                    currentIndex: findReplaceViewModel.currentMatchIndex
                )
                textViewSearchRef.selectMatch(
                    at: findReplaceViewModel.currentMatchIndex,
                    in: findReplaceViewModel.matchRanges
                )
            } else {
                textViewSearchRef.clearSearchHighlights()
            }
        } else if findReplaceViewModel.hasResults {
            if let line = findReplaceViewModel.currentMatchLine {
                documentViewModel.requestScrollToLine(line)
            }
        }
    }

    private func performFindNext() {
        guard findReplaceViewModel.hasResults else {
            if !appViewModel.isFindBarVisible { openFindBar() }
            performSearch()
            return
        }
        findReplaceViewModel.goToNextMatch()
        navigateToCurrentMatch()
    }

    private func performFindPrevious() {
        guard findReplaceViewModel.hasResults else {
            if !appViewModel.isFindBarVisible { openFindBar() }
            performSearch()
            return
        }
        findReplaceViewModel.goToPreviousMatch()
        navigateToCurrentMatch()
    }

    private func navigateToCurrentMatch() {
        if documentViewModel.displayMode == .raw {
            textViewSearchRef.reapplySearchHighlights(
                matchRanges: findReplaceViewModel.matchRanges,
                currentIndex: findReplaceViewModel.currentMatchIndex
            )
            textViewSearchRef.selectMatch(
                at: findReplaceViewModel.currentMatchIndex,
                in: findReplaceViewModel.matchRanges
            )
        } else if let line = findReplaceViewModel.currentMatchLine {
            documentViewModel.requestScrollToLine(line)
        }
    }

    private func performReplace() {
        guard documentViewModel.displayMode == .raw,
              let currentRange = findReplaceViewModel.currentMatchRange else { return }

        let _ = textViewSearchRef.replaceCurrentMatch(at: currentRange, with: findReplaceViewModel.replaceText)
        documentViewModel.content = textViewSearchRef.textView?.string ?? documentViewModel.content
        performSearch()
    }

    private func performReplaceAll() {
        guard documentViewModel.displayMode == .raw,
              !findReplaceViewModel.matchRanges.isEmpty else { return }

        let _ = textViewSearchRef.replaceAllMatches(ranges: findReplaceViewModel.matchRanges, with: findReplaceViewModel.replaceText)
        documentViewModel.content = textViewSearchRef.textView?.string ?? documentViewModel.content
        performSearch()
    }

    // MARK: - 文档内容视图

    @ViewBuilder
    private var selectFilePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 36))
                .foregroundStyle(themeColors.fgMuted)
            Text(L10n.tr(.selectFileHint, language: language))
                .font(.subheadline)
                .foregroundStyle(themeColors.fgSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 文档内容视图

    @ViewBuilder
    private var documentContentView: some View {
        ZStack {
            // Raw 模式视图 — 始终保持存活，避免 NSTextView 被销毁导致 undo 历史丢失
            RawMarkdownView(
                content: Binding(
                    get: { documentViewModel.content },
                    set: { documentViewModel.content = $0 }
                ),
                fontSize: settings.sourceFontPointSize,
                contentPadding: settings.contentPaddingPoints,
                scrollToLine: documentViewModel.scrollToLineRequest,
                fileURL: documentViewModel.currentFileURL,
                isActive: documentViewModel.displayMode == .raw,
                isFindBarVisible: appViewModel.isFindBarVisible,
                searchRef: textViewSearchRef,
                onCursorLineNumberChanged: { lineNumber in
                    documentViewModel.cursorLineNumber = lineNumber
                },
                contentVersion: documentViewModel.contentVersion,
                undoStore: undoStore
            )
            .opacity(documentViewModel.displayMode == .raw ? 1 : 0)
            .allowsHitTesting(documentViewModel.displayMode == .raw)
            .onChange(of: documentViewModel.scrollToLineRequest) { _, newValue in
                if newValue != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        documentViewModel.clearScrollRequest()
                    }
                }
            }

            // 渲染模式视图 — 仅在渲染模式下显示
            if documentViewModel.displayMode == .rendered {
                WebViewMarkdownView(
                    content: documentViewModel.content,
                    fileURL: documentViewModel.currentFileURL,
                    contentPadding: settings.contentPaddingPoints,
                    maxContentWidthFollowsWindow: settings.maxContentWidthFollowsWindow,
                    scrollToLine: documentViewModel.scrollToLineRequest,
                    themeCSS: themeColors.cssCustomProperties + themeColors.codeHighlightCSS,
                    isDark: settings.resolvedThemeType == .dark,
                    searchQuery: findReplaceViewModel.searchText,
                    searchCaseSensitive: findReplaceViewModel.isCaseSensitive,
                    searchWholeWord: findReplaceViewModel.isWholeWord,
                    searchCurrentIndex: findReplaceViewModel.currentMatchIndex,
                    isFindBarVisible: appViewModel.isFindBarVisible,
                    contentVersion: documentViewModel.contentVersion,
                    onVisibleHeadingChanged: { heading in
                        activeOutlineLineNumber = heading?.lineNumber
                    },
                    onVisibleLineChanged: { lineNumber in
                        documentViewModel.renderedVisibleLineNumber = lineNumber
                    },
                    commandTarget: commandTarget,
                    onOpenLinkedMarkdownFile: { [weak session] url in
                        session?.handleLinkedMarkdownFile(url.standardizedFileURL)
                    },
                    exportedPage: $exportedPage
                )
                .onChange(of: documentViewModel.scrollToLineRequest) { _, newValue in
                    if newValue != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            documentViewModel.clearScrollRequest()
                        }
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if appViewModel.isFindBarVisible, documentViewModel.hasDocument {
                FindReplaceBar(
                    viewModel: findReplaceViewModel,
                    isRawMode: documentViewModel.displayMode == .raw,
                    onFindNext: { performFindNext() },
                    onFindPrevious: { performFindPrevious() },
                    onReplace: { performReplace() },
                    onReplaceAll: { performReplaceAll() },
                    onClose: { closeFindBar() }
                )
                .padding(.trailing, 16)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appViewModel.isFindBarVisible)
        .overlay(alignment: .topTrailing) {
            // 编辑模式内容区右上角原生复制按钮。
            // 仅 raw 模式 + 有文档 + 查找栏关闭时显示，避免与查找栏浮层重叠。
            if documentViewModel.hasDocument
                && documentViewModel.displayMode == .raw
                && !appViewModel.isFindBarVisible {
                Button {
                    copyRawContent()
                } label: {
                    Image(systemName: contentCopyState.isShowingSuccess ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .frame(width: 14, height: 14)
                        .foregroundStyle(contentCopyState.isShowingSuccess ? themeColors.success : themeColors.fgMuted)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(L10n.tr(contentCopyState.isShowingSuccess ? .contentCopied : .contentCopy, language: language))
                .padding(.trailing, 11)
                .padding(.top, 3)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: contentCopyState.isShowingSuccess)
        .onChange(of: findReplaceViewModel.searchText) { _, _ in performSearch() }
        .onChange(of: findReplaceViewModel.isCaseSensitive) { _, _ in performSearch() }
        .onChange(of: findReplaceViewModel.isWholeWord) { _, _ in performSearch() }
        .onChange(of: findReplaceViewModel.isRegularExpression) { _, _ in performSearch() }
        // 模式/文件切换：废弃旧文档的复制反馈，防止残留对号。
        .onChange(of: documentViewModel.displayMode) { _, _ in invalidateCopyFeedback() }
        .onChange(of: documentViewModel.currentFileURL) { _, _ in invalidateCopyFeedback() }
    }

    /// 把 find/reload/exportPDF handler 注册到注入的本窗口命令目标上。
    ///
    /// 回归修复根因 1：DetailView 不再发布独立 `focusedSceneValue(\.windowCommandTarget, …)`
    /// 覆盖 `WindowSceneHost` 的 scene 级发布（覆盖会让无 session 的临时 target 抢占
    /// 焦点路由）。handler 直接挂到由 WindowSceneHost 注入、绑定本 session 的 target 上；
    /// 视图重建时 handler 自然更新，session 释放后 target 变 no-op。
    private func registerCommandHandlers() {
        guard let target = commandTarget else { return }
        target.findHandler = { cmd in
            switch cmd {
            case .find: openFindBar()
            case .findNext: performFindNext()
            case .findPrevious: performFindPrevious()
            case .findAndReplace: openFindAndReplace()
            }
        }
        target.reloadHandler = { handleReloadButtonTapped() }
        target.exportPDFHandler = { exportPDF() }
    }
}

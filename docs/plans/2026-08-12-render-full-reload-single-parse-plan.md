# Markdown 完整重载单次解析优化 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让渲染模式的完整页面加载对一份 Markdown 只执行一次 `MarkdownHTMLService.render`，不改变 HTML、功能或刷新语义。

**Architecture:** 将“Markdown -> `RenderResult`”与“`RenderResult` -> 完整 HTML 页面壳”拆开。`WebViewMarkdownView.loadContent()` 先生成一次 `RenderResult`，再把该结果交给新的 `buildFullHTML(renderResult:...)` 重载；旧的 `buildFullHTML(content:...)` 保留为兼容入口，内部仍只渲染一次。删除 WebView 中未被读取的标题状态，避免为它重复解析同一文档。

**Tech Stack:** Swift 6.2、SwiftUI、WebKit `WebPage`、swift-markdown、XCTest、Swift Package Manager

---

## 一、背景与根因

完整加载路径当前如下：

```text
WebViewMarkdownView.loadContent()
  -> MarkdownHTMLService.buildFullHTML(content: ...)
       -> MarkdownHTMLService.render(content, ...)
  -> MarkdownHTMLService.render(content, ...)
       -> currentHeadings
  -> WebPage.load(html: ...)
```

第二次 `render` 会再次执行 Markdown 预处理、`Markdown.Document` 解析和 HTML formatter 遍历。它写入的 `currentHeadings` 没有任何读取点；页面大纲实际来自 `DocumentViewModel.outlineItems`，可见标题同步来自 WebView 的 DOM 回调。因此第二次解析对当前功能没有贡献，只增加完整加载、手动 Reload、外部文件变更刷新和渲染模式下文件切换的 CPU 时间与内存分配。

## 二、技术方案

### 2.1 唯一渲染结果作为页面装配输入

在 `MarkdownHTMLService` 增加一个以 `RenderResult` 为输入的 `buildFullHTML` 重载。该重载只负责插入：

- `renderResult.html`；
- 既有主题 CSS、content padding、最大正文宽度；
- 既有 `mr:///` CSS/JS 资源；
- 既有文档复制按钮的本地化 data attribute；
- 既有 `isDark` script data attribute。

它**不得**再次调用 `render`，也不得改变 HTML 壳、资源顺序或 copy-button 合同。

保留原有 `buildFullHTML(content:...)` 签名给 PDF 导出等调用方使用：其内部执行一次 `render` 后委托给新重载。这样本任务只优化 WebView 已经拥有渲染结果的路径，不扩大 PDF、Quick Look 或其他调用方的改动面。

### 2.2 WebView 完整加载只生成一次结果

`WebViewMarkdownView.loadContent()` 中先生成：

```swift
let renderResult = MarkdownHTMLService.render(content, baseURL: baseURL)
```

随后调用 `buildFullHTML(renderResult: renderResult, ...)`。不再为 `currentHeadings` 再次调用 `render`。

增量更新 `updateContent(_:)` 已经只渲染一次以获得待注入的 `renderResult.html`；本任务仅移除其中对无用 `currentHeadings` 的赋值，不更改其 JavaScript 调用、转义、查找、滚动、缩放或异步行为。

### 2.3 删除无效视图状态

删除 `@State private var currentHeadings` 和从未读取的 `lastLoadedURL`。不把 formatter 的 headings 接到右侧大纲，也不改变大纲解析机制；那是单独的产品/性能课题。

## 三、改动边界

### 包含

- 完整加载单次 Markdown 解析；
- 保持现有公共 `buildFullHTML(content:...)` 行为的重载重构；
- 为新重载及旧便利入口补充确定性单测；
- 真实应用中的打开、Reload、切换渲染模式和 PDF 回归验收。

### 不包含

- 不做 Mermaid、KaTeX、Prism 的按需加载或资源缓存；
- 不合并 `fileURL` / `content` / `contentVersion` 的渲染触发；
- 不把 Markdown 解析迁出主线程，不增加渲染队列、缓存或 instrumentation；
- 不改 `OutlineService`、`DocumentViewModel.outlineItems`、可见标题同步、查找、缩放、复制按钮、JavaScript、CSS；
- 不改 PDF、Quick Look、URL scheme handler、发布版本或依赖。

## 四、实施任务

### Task 1：为页面壳增加可复用的 `RenderResult` 输入

**Files:**

- Modify: `Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift:50-88`
- Create: `Tests/MarkdownReaderTests/MarkdownHTMLServiceTests.swift`

**Step 1: 写出新重载的失败测试**

在新测试文件中 `import MarkdownReaderKit`，以一个真实 `RenderResult` 调用尚不存在的重载：

```swift
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
```

**Step 2: 运行测试并确认失败原因正确**

Run:

```bash
swift test --filter MarkdownHTMLServiceTests/testBuildFullHTMLFromRenderResultEmbedsRenderedBodyAndShell
```

Expected: 编译失败，提示 `buildFullHTML(renderResult:...)` 尚不存在；不得用改弱断言或跳过测试绕过该失败。

**Step 3: 实现只装配页面壳的新重载**

将现有 `buildFullHTML(content:...)` 拆成两个入口：

```swift
public static func buildFullHTML(
    content: String,
    themeCSS: String,
    contentPadding: CGFloat,
    maxContentWidthFollowsWindow: Bool = false,
    baseURL: URL?,
    isDark: Bool = true,
    documentCopyTitle: String = "",
    documentCopiedTitle: String = ""
) -> String {
    buildFullHTML(
        renderResult: render(content, baseURL: baseURL),
        themeCSS: themeCSS,
        contentPadding: contentPadding,
        maxContentWidthFollowsWindow: maxContentWidthFollowsWindow,
        baseURL: baseURL,
        isDark: isDark,
        documentCopyTitle: documentCopyTitle,
        documentCopiedTitle: documentCopiedTitle
    )
}
```

新增的 `buildFullHTML(renderResult:...)` 复用原 HTML 模板，并将模板中的 `renderResult.html` 改为传入结果的 `html`。它不能接受原始 Markdown，也不能在内部调用 `render`。参数默认值、XML attribute escaping、CSS/JS tag 顺序及所有 HTML 字面量必须与原实现保持一致。

**Step 4: 补充旧便利入口回归测试**

添加第二个测试，调用原 `buildFullHTML(content:...)`，断言标题实际渲染为 `<h1 id=\"heading-1\"`，且完整页面仍包含 `mr-theme-style`、`markdown-reader.js` 与 `#mr-content`。这锁住 PDF 等未迁移调用方的既有输出合同。

**Step 5: 运行聚焦测试**

Run:

```bash
swift test --filter MarkdownHTMLServiceTests
```

Expected: 两个测试通过。测试文件只覆盖纯 `MarkdownReaderKit` HTML 生成，不创建 WebView，不联网。

### Task 2：让 WebView 完整加载复用该结果

**Files:**

- Modify: `Sources/MarkdownReader/Views/WebViewMarkdownView.swift:105-116,261-314`

**Step 1: 在 `loadContent()` 先渲染一次**

在构造完整 HTML 前创建 `renderResult`，并将其传给 Task 1 的新重载：

```swift
let renderResult = MarkdownHTMLService.render(content, baseURL: baseURL)
let html = MarkdownHTMLService.buildFullHTML(
    renderResult: renderResult,
    themeCSS: themeCSS,
    contentPadding: contentPadding,
    maxContentWidthFollowsWindow: maxContentWidthFollowsWindow,
    baseURL: baseURL,
    isDark: isDark,
    documentCopyTitle: L10n.tr(.contentCopy, language: language),
    documentCopiedTitle: L10n.tr(.contentCopied, language: language)
)
```

删除旧的第二个 `MarkdownHTMLService.render(content, baseURL: baseURL)` 调用。`scrollPosition` 重置、`page.load`、`lastLoadedContent`、查找栏显隐同步和待处理滚动请求必须保持原顺序与语义。

**Step 2: 删除未读取状态及赋值**

删除：

```swift
@State private var currentHeadings: [MarkdownHTMLService.HeadingInfo] = []
@State private var lastLoadedURL: URL?
```

以及 `loadContent()` / `updateContent(_:)` 中对它们的赋值。`updateContent(_:)` 继续保留它自己的单次 `render`，并继续把 `renderResult.html` 交给 `MR.replaceContent`。

**Step 3: 进行局部差异审查**

Run:

```bash
git diff -- Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift Sources/MarkdownReader/Views/WebViewMarkdownView.swift Tests/MarkdownReaderTests/MarkdownHTMLServiceTests.swift
```

Expected: `loadContent()` 中只有一次 `MarkdownHTMLService.render`；`updateContent(_:)` 中仍只有一次；没有修改 `.onChange`、JavaScript 字符串转义、`WebPage` 配置或文档复制按钮参数。

### Task 3：构建、真实流程与性能回归验收

**Files:**

- Verify: `Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift`
- Verify: `Sources/MarkdownReader/Views/WebViewMarkdownView.swift`
- Verify: `Sources/MarkdownReader/Views/DetailView.swift:435-462`
- Verify: `Tests/MarkdownReaderTests/MarkdownHTMLServiceTests.swift`

**Step 1: 运行自动验证**

Run:

```bash
swift test
swift build
git diff --check
```

Expected: 全部测试通过、构建成功、`git diff --check` 无输出。

**Step 2: 验证渲染模式完整加载**

在 Release 或 Debug 应用中打开包含以下元素的 Markdown：ATX 标题、表格、围栏代码、图片、数学公式、Mermaid 与 PlantUML。依次执行：

1. 首次打开；
2. 菜单 Reload；
3. 切换到另一份 Markdown 后再切回；
4. Raw -> Rendered；
5. 打开查找栏、定位大纲标题、缩放。

Expected: 页面内容、主题、代码高亮、图片、公式、图表、大纲定位、查找、滚动和复制按钮与改动前一致；不出现空白页、旧文档内容或重复 copy button。

**Step 3: 验证 PDF 未受影响**

在渲染模式和 Raw 模式各导出一次 PDF。

Expected: 渲染模式沿用现有 `exportedPage`；Raw 模式仍通过保留的 `buildFullHTML(content:...)` 生成完整内容，导出的标题、代码、图片和主题正常，且不包含内容复制按钮。

**Step 4: 验证优化事实并提交**

在代码审查和调试器断点中确认一次 `loadContent()` 只进入一次 `MarkdownHTMLService.render`。对同一份大文档重复 Reload，性能是否提升以 Instruments Time Profiler 记录为准；本任务的硬性验收是消除确定存在的第二次解析，而非承诺固定百分比。

提交时仅暂存本任务文件：

```bash
git add Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift Sources/MarkdownReader/Views/WebViewMarkdownView.swift Tests/MarkdownReaderTests/MarkdownHTMLServiceTests.swift
git commit -m "perf: avoid duplicate markdown render on full load"
```

## 五、完成标准

- WebView 的 `loadContent()` 对同一 `content` / `baseURL` 只调用一次 `MarkdownHTMLService.render`。
- 新的 `buildFullHTML(renderResult:...)` 不接受原始 Markdown，且不执行 Markdown 预处理或解析。
- 原 `buildFullHTML(content:...)` 签名及输出合同仍可供 PDF 等调用方使用，并只执行一次渲染。
- `currentHeadings`、`lastLoadedURL` 与其所有无效赋值不再存在。
- `swift test`、`swift build`、`git diff --check` 通过；完整加载和 PDF 手工回归无功能差异。

## 六、回滚

若出现 HTML 壳缺失、PDF 输出差异或 WebView 完整加载异常，回滚本任务涉及的三个源文件和新增单测即可恢复原先独立渲染路径；不涉及数据迁移、设置格式、资源格式或发布资产，因此没有用户数据回滚步骤。

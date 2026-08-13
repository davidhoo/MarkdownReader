# Content-Aware Runtime Loading Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让主阅读页只在渲染结果实际包含 Mermaid 或 KaTeX 时加载对应运行时；普通 Markdown 保持 Prism 与 MarkdownReader 核心脚本，但不再下载/解析 Mermaid、KaTeX 与 KaTeX CSS。

**Architecture:** `MarkdownHTMLService` 从单次 `RenderResult.html` 推导不可变的 `MarkdownRuntimeRequirements`，并由现有 `buildFullHTML(renderResult:...)` 按需求条件装配资源标签。`WebViewMarkdownView` 在整页加载时注入该需求；内容增量替换时先以既有单次解析得到新需求，需求变化便提升为整页加载，避免新出现的图表/公式因脚本未加载而失效。应用级 WebView 预热只保留基础运行时，不再抢先载入重量级可选库。

**Tech Stack:** Swift 6.2、SwiftUI、WebKit `WebPage`、swift-markdown、JavaScript、XCTest、Swift Package Manager

---

## 背景与根因

目前主阅读页的 `MarkdownHTMLService.buildFullHTML(renderResult:...)` 无条件写入以下资源：

- `mermaid.min.js`（约 3.2 MB）；
- `katex.min.js`（约 272 KB）；
- `katex.min.css`（约 24 KB）。

这发生在每一份普通 Markdown 的完整加载中，即使正文没有 Mermaid 或数学公式。`WebViewWarmupService` 也无条件预热同一组三方资源，导致只阅读普通文本时仍承担相同的启动解析和内存成本。

Quick Look 已有一个独立的 `buildContentAwareHTML(content:hasMermaid:hasKaTeX:)` 路径，但主阅读页没有使用它；直接复用该入口会丢失主阅读页的 `maxContentWidthFollowsWindow`、文档复制本地化属性和 SF Symbol CSS mask 变量，并会偏离当前 v2.2.8 的单次 `RenderResult` 合同。因此本任务在主阅读页现有 `buildFullHTML(renderResult:...)` 上增加运行时需求参数，而不迁移 Quick Look。

## 目标合同

| 渲染结果 | `mermaid.min.js` | `katex.min.js` / `katex.min.css` | Prism / `markdown-reader.js` |
|---|---:|---:|---:|
| 普通 Markdown 或非 Mermaid/KaTeX 代码 | 不加载 | 不加载 | 始终加载 |
| `mermaid` 代码块 | 加载 | 不加载 | 始终加载 |
| `$...$`、`$$...$$`、`math` / `latex` / `katex` 代码块 | 不加载 | 加载 | 始终加载 |
| 同时含图表和公式 | 加载 | 加载 | 始终加载 |

PlantUML 不在表中，因为它不依赖本地 Mermaid/KaTeX 库：`markdown-reader.js` 仍会识别 PlantUML 代码块并通过现有 Kroki 路径处理。Prism 也不能按本任务移除，因为代码高亮与 autoloader 对普通代码块仍是基础能力。

## 方案

### 1. 从已渲染 HTML 推导需求

新增公开值类型：

```swift
public struct MarkdownRuntimeRequirements: Equatable, Sendable {
    public let requiresMermaid: Bool
    public let requiresKaTeX: Bool

    public static let all = MarkdownRuntimeRequirements(
        requiresMermaid: true,
        requiresKaTeX: true
    )

    public static func detect(in renderResult: MarkdownHTMLService.RenderResult)
        -> MarkdownRuntimeRequirements
}
```

检测输入必须是 `RenderResult.html`，不是原始 Markdown：

- `class="language-mermaid"` 表示 Mermaid；
- `class="language-math`、`class="language-latex"`、`class="language-katex"` 中任一出现表示 KaTeX。

这样自动覆盖现有 `$...$` / `$$...$$` 预处理产生的 `language-math`，以及直接声明的 math/latex/katex 代码块；不会再维护一份易遗漏单美元公式的原始文本猜测规则。检测本身不额外解析 Markdown。

### 2. 主页面壳条件装配，默认保持完整

为两种 `buildFullHTML` 重载末尾新增默认参数：

```swift
runtimeRequirements: MarkdownRuntimeRequirements = .all
```

调用方未传入时，生成的 HTML 必须和当前完全一致：KaTeX CSS、Mermaid JS、KaTeX JS、Prism、autoloader 和 `markdown-reader.js` 顺序不变。这保护 Raw 模式 PDF 导出及所有当前未迁移调用方。

主阅读页传入检测结果时：

- 仅在 `requiresKaTeX` 时写入 KaTeX CSS 与 JS；
- 仅在 `requiresMermaid` 时写入 Mermaid JS；
- 始终写入 Prism、autoloader、`markdown-reader.js`、主题 CSS、正文宽度、文档复制标题和 `DocumentCopyWebIcons` CSS 变量。

不使用 `buildContentAwareHTML`，也不在本任务中删除、重写或改变 Quick Look 的独立 HTML 壳。

### 3. 增量内容变更的运行时升级

现有 WebView 调度对“同 URL、同 contentVersion、仅 content 改变”选择 `MR.replaceContent`。这对普通文本正确，但如果新内容第一次加入 Mermaid/KaTeX，当前页面可能没有相应脚本；反之，移除全部图表/公式时也无法卸载已加载库。

在 `WebViewMarkdownView` 增加：

```swift
@State private var loadedRuntimeRequirements: MarkdownRuntimeRequirements?
```

完整 `loadPage` 路径在已有的单次 `MarkdownHTMLService.render` 后检测并记录需求，再调用带参数的 `buildFullHTML`。增量 `replaceContent` 路径同样只渲染一次、从该结果检测需求：

1. 新旧需求相同：保留 `MR.replaceContent`；
2. 新旧需求不同或当前值为 `nil`：复用刚得到的 `RenderResult` 立即走 `loadPage`，不再调用 `MR.replaceContent`，也不得再次解析 Markdown。

为该规则在 `WebViewRenderScheduler.swift` 增加纯 `WebViewRuntimePolicy`，返回 `.replaceContent` 或 `.loadPage`。这样“功能需求变化必须整页加载”的决定可在无 WebKit 环境的单元测试中锁定。

### 4. 基础预热而非全量预热

`WebViewWarmupService` 的 HTML 保留 `markdown.css`、Prism、autoloader 与 `markdown-reader.js`，移除 KaTeX CSS、Mermaid JS 和 KaTeX JS。它仍创建同一个隐藏 `WebPage` 并保持现有幂等状态机；首次打开有图表/公式的文档会按文档自身需求加载可选库，普通文档不再在启动阶段付出这部分成本。

## 改动边界

### 包含

- 主阅读页按渲染结果条件加载 Mermaid/KaTeX；
- 在内容增量替换时安全地处理可选运行时需求变化；
- 基础 WebView 预热；
- 纯需求检测、HTML 壳、运行时升级策略和预热资源集的单元测试；
- 普通、Mermaid、KaTeX、混合、PlantUML 和 PDF 的真实应用回归。

### 不包含

- 不改 Quick Look 的 `buildContentAwareHTML` 或其超时策略；
- 不改 Markdown 解析器、数学语法支持、Mermaid/KaTeX/Prism 版本、资源文件或 `mr://` handler；
- 不改 PlantUML 网络请求、缓存或主题重绘；
- 不引入动态 `import()`、网络 CDN、运行时下载、后台解析、预取、资源缓存或设置项；
- 不改 v2.2.8 已完成的 latest-wins 渲染调度、SF Symbol 复制图标合同、Raw 编辑器、PDF/Quick Look 行为或发布流程。

## 实施任务

### Task 1: 锁定运行时需求检测和默认页面壳合同

**Files:**

- Modify: `Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift:50-103`
- Modify: `Tests/MarkdownReaderTests/MarkdownHTMLServiceTests.swift`

**Step 1: 写出需求检测失败测试**

在 `MarkdownHTMLServiceTests` 添加以下测试组：

```swift
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
    XCTAssertTrue(MarkdownRuntimeRequirements.detect(in: math).requiresKaTeX)
}
```

另加 `latex` fenced code block 与同时包含 Mermaid/KaTeX 的测试；断言只按 render 后的 class 得到需求，不在测试中复制正则或原始内容探测实现。

**Step 2: 写出页面壳资源集失败测试**

以普通 Markdown 的 `RenderResult` 调用新参数：

```swift
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
```

再断言默认不传参数的 `buildFullHTML` 仍同时包含三项可选资源，锁住 PDF 等兼容调用方的完整页面合同。

**Step 3: 运行测试并确认正确失败**

Run:

```bash
swift test --filter MarkdownHTMLServiceTests
```

Expected: 编译失败，提示 `MarkdownRuntimeRequirements` 和 `runtimeRequirements:` 尚不存在。

**Step 4: 实现值类型与条件 HTML 标签**

在 `MarkdownHTMLService.swift` 中新增 `MarkdownRuntimeRequirements`。提供公开成员初始化器、`.all`，并从 `renderResult.html` 精确检测上述四种 language class。

给两个 `buildFullHTML` 重载都添加末尾默认参数 `runtimeRequirements: .all`；将 KaTeX `<link>`、Mermaid `<script>`、KaTeX `<script>` 构造成局部条件字符串，并保持 Prism/markdown-reader 与既有 HTML 壳内容、资源顺序、copy-title attribute、宽度和 `DocumentCopyWebIcons` 注入不变。

**Step 5: 运行聚焦测试**

Run:

```bash
swift test --filter MarkdownHTMLServiceTests
swift test --filter DocumentCopyWebIconsTests
```

Expected: 新需求/资源测试与既有复制图标 CSS 合同测试均通过。

### Task 2: 让主阅读页在一次解析中应用需求，并安全处理需求变化

**Files:**

- Modify: `Sources/MarkdownReader/Views/WebViewRenderScheduler.swift:1-60`
- Modify: `Sources/MarkdownReader/Views/WebViewMarkdownView.swift:108-121,295-360`
- Modify: `Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift`

**Step 1: 写出纯运行时升级策略失败测试**

在 `WebViewRenderSchedulerTests` 添加：

```swift
func testUnchangedRuntimeRequirementsKeepIncrementalReplacement() {
    let plain = MarkdownRuntimeRequirements(requiresMermaid: false, requiresKaTeX: false)
    XCTAssertEqual(WebViewRuntimePolicy.action(current: plain, next: plain), .replaceContent)
}

func testAddingKaTeXPromotesReplacementToFullPageLoad() {
    let plain = MarkdownRuntimeRequirements(requiresMermaid: false, requiresKaTeX: false)
    let math = MarkdownRuntimeRequirements(requiresMermaid: false, requiresKaTeX: true)
    XCTAssertEqual(WebViewRuntimePolicy.action(current: plain, next: math), .loadPage)
}
```

增加“移除 Mermaid 也为 `.loadPage`”与 `current == nil` 为 `.loadPage` 的测试。该策略只判断已加载与下一份 HTML 的运行时需求，不替代既有 `fileURL` / `contentVersion` 渲染策略。

**Step 2: 运行测试并确认失败**

Run:

```bash
swift test --filter WebViewRenderSchedulerTests
```

Expected: 编译失败，提示 `WebViewRuntimePolicy` 尚不存在。

**Step 3: 实现纯策略**

在 `WebViewRenderScheduler.swift` 导入 `MarkdownReaderKit`，新增：

```swift
enum WebViewRuntimePolicy {
    static func action(
        current: MarkdownRuntimeRequirements?,
        next: MarkdownRuntimeRequirements
    ) -> WebViewRenderAction {
        current == next ? .replaceContent : .loadPage
    }
}
```

不得修改 `WebViewRenderSnapshot`、`WebViewRenderPolicy` 或 `WebViewRenderScheduler` 的现有 URL/version/latest-wins 合同。

**Step 4: 为 WebView 保存已加载需求**

在 `WebViewMarkdownView` 增加：

```swift
@State private var loadedRuntimeRequirements: MarkdownRuntimeRequirements?
```

将 `loadContent(_:)` 拆成“渲染一次并检测需求”与“使用已有结果整页装配”两个私有方法。完整加载路径必须：

1. 一次 `MarkdownHTMLService.render(snapshot.content, baseURL:)`；
2. 一次 `MarkdownRuntimeRequirements.detect(in:)`；
3. 记录 `loadedRuntimeRequirements`；
4. 以同一个 `RenderResult` 和 `runtimeRequirements:` 调用 `buildFullHTML`；
5. 保留现有 SF Symbol 图标获取、`page.load`、滚动重置、查找栏按钮同步与待滚动行号语义。

**Step 5: 在增量替换前检测并升级**

`replaceContent(_:generation:)` 仍对快照只解析一次。将 `renderResult.html` 转义前先检测：

```swift
let requirements = MarkdownRuntimeRequirements.detect(in: renderResult)
if WebViewRuntimePolicy.action(
    current: loadedRuntimeRequirements,
    next: requirements
) == .loadPage {
    loadPage(snapshot, renderResult: renderResult, runtimeRequirements: requirements)
    return
}
```

`loadPage` 必须直接复用传入的 `RenderResult`，不得重新调用 `render`；升级分支不得创建 `contentReplacementTask`。只有需求不变才继续现有 generation-checked、可取消的 `MR.replaceContent`。

**Step 6: 运行聚焦验证**

Run:

```bash
swift test --filter WebViewRenderSchedulerTests
swift test --filter MarkdownHTMLServiceTests
git diff -- Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift Sources/MarkdownReader/Views/WebViewRenderScheduler.swift Sources/MarkdownReader/Views/WebViewMarkdownView.swift Tests/MarkdownReaderTests/MarkdownHTMLServiceTests.swift Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift
```

Expected: 需求升级策略、原 latest-wins 策略、页面壳与单次解析合同均通过；局部 diff 中无对 Raw 编辑器、JS/CSS、Quick Look 的修改。

### Task 3: 将应用级预热收窄为基础运行时

**Files:**

- Modify: `Sources/MarkdownReader/Services/WebViewWarmupService.swift:5-62`
- Modify: `Tests/MarkdownReaderTests/AppStartupCoordinatorTests.swift`

**Step 1: 写出预热资源集失败测试**

把预热 HTML 提取为测试可读的内部静态常量（例如 `static let warmupHTML`），并在 `AppStartupCoordinatorTests` 中断言：

```swift
let html = WebViewWarmupService.warmupHTML
XCTAssertTrue(html.contains("mr:///js/prism-core.min.js"))
XCTAssertTrue(html.contains("mr:///js/markdown-reader.js"))
XCTAssertFalse(html.contains("mr:///js/mermaid.min.js"))
XCTAssertFalse(html.contains("mr:///js/katex.min.js"))
XCTAssertFalse(html.contains("mr:///css/katex.min.css"))
```

保留既有 `warmUpIfNeeded()` 多窗口幂等测试，不以页面异步加载完成时间作为单测条件。

**Step 2: 运行并确认失败**

Run:

```bash
swift test --filter AppStartupCoordinatorTests
```

Expected: 资源集断言失败，因为当前预热 HTML 仍含 Mermaid/KaTeX。

**Step 3: 实现基础预热**

将 HTML 字面量移到 `warmupHTML`，并从它移除 KaTeX CSS、Mermaid JS 与 KaTeX JS。保留既有的 `MarkdownURLSchemeHandler`、`WebPage.Configuration`、`markdown.css`、Prism、autoloader、`markdown-reader.js`、`page.load`、`warmedPage` 与 `.idle -> .warming -> .ready` 语义。

**Step 4: 运行聚焦测试**

Run:

```bash
swift test --filter AppStartupCoordinatorTests
```

Expected: 资源集与幂等测试均通过。

### Task 4: 全量回归与实际资源验证

**Files:**

- Verify: `Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift`
- Verify: `Sources/MarkdownReader/Views/WebViewMarkdownView.swift`
- Verify: `Sources/MarkdownReader/Services/WebViewWarmupService.swift`
- Verify: `Sources/MarkdownReaderQL/MarkdownQLPreviewProvider.swift`

**Step 1: 执行自动验证**

Run:

```bash
swift test
swift build
git diff --check
```

Expected: 全部通过，且 `git diff --check` 无输出。

**Step 2: 验证普通页面的资源边界**

用 Web Inspector Network 或 `MarkdownURLSchemeHandler.reply(for:)` 的临时断点（验证后移除）打开只含标题、段落、表格与 `swift` 代码块的文件。

Expected: 请求 `markdown.css`、Prism、autoloader 与 `markdown-reader.js`；不请求 `mermaid.min.js`、`katex.min.js` 或 `katex.min.css`。确认代码高亮、查找、缩放、标题同步、复制按钮和 PDF 导出仍正常。

**Step 3: 验证可选运行时与内容升级**

依次打开 Mermaid-only、KaTeX-only、混合 Mermaid+KaTeX、PlantUML-only 文档：

- Mermaid-only 只请求 Mermaid 可选运行时；
- KaTeX-only 只请求 KaTeX CSS/JS；
- 混合文档请求两者；
- PlantUML-only 不请求 Mermaid/KaTeX，仍出现现有 loading/success/error 状态。

然后在同一文档身份、同一 `contentVersion` 下通过测试钩子或可复现编辑流程依次将普通内容改成含 KaTeX、再移除 KaTeX。Expected: 两次需求变化均走一次完整 page load；每一次 Markdown 变化只解析一次，页面不出现原始公式、空白区、旧 DOM 或重复复制按钮。

**Step 4: 回归 PDF 与 Quick Look 边界**

- Raw 模式导出 PDF：因调用方未传 `runtimeRequirements`，默认完整 HTML 仍含所需资源，公式和图表正常；
- Rendered 模式导出：继续导出当前 `exportedPage`；
- Quick Look：只验证当前预览功能正常，不修改其 `buildContentAwareHTML`、检测逻辑或超时。

**Step 5: 提交窄范围改动**

```bash
git add Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift Sources/MarkdownReader/Views/WebViewRenderScheduler.swift Sources/MarkdownReader/Views/WebViewMarkdownView.swift Sources/MarkdownReader/Services/WebViewWarmupService.swift Tests/MarkdownReaderTests/MarkdownHTMLServiceTests.swift Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift Tests/MarkdownReaderTests/AppStartupCoordinatorTests.swift
git commit -m "perf: load markdown runtimes on demand"
```

## 完成标准

- 主阅读页仅在渲染结果确实需要时加载 Mermaid 与 KaTeX；普通文档不加载三项可选资源。
- 可选运行时检测来自已有 `RenderResult.html`，不增加 Markdown 解析，也不会漏掉单美元公式或 `latex` / `katex` fenced code block。
- 内容增量更新若改变运行时需求，复用已有 `RenderResult` 执行一次完整加载；需求不变仍走既有 `MR.replaceContent` 和 latest-wins generation。
- 默认 `buildFullHTML` 保持完整资源集，以保护 Raw PDF 和未迁移调用方；复制图标、主题、宽度与本地化属性保持不变。
- WebView 预热仅加载基础运行时，幂等语义不变。
- `swift test`、`swift build`、`git diff --check` 成功，且普通/图表/公式/PlantUML/PDF/Quick Look 手工回归通过。

## 回滚

若出现公式/图表未渲染、内容替换显示旧 DOM、PDF 资源缺失或启动异常，回滚本任务的以下文件即可恢复全量加载：

- `Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift`
- `Sources/MarkdownReader/Views/WebViewRenderScheduler.swift`
- `Sources/MarkdownReader/Views/WebViewMarkdownView.swift`
- `Sources/MarkdownReader/Services/WebViewWarmupService.swift`
- 本任务新增/修改的三个测试文件。

不涉及用户数据、设置、资源格式、数据库或远程状态，无需迁移或用户侧回滚操作。

## 不包含

- 不将 Quick Look 合并到主阅读页 HTML builder；
- 不删除 `buildContentAwareHTML`，也不改变 Quick Look 的资源判断；
- 不做所有 Prism 语言按需拆分、Mermaid/KaTeX 资源压缩、CDN 或 WebKit cache 改造；
- 不更改 PlantUML、图片惰加载、后台解析、渲染触发收敛、SF Symbol、界面、设置或版本发布。

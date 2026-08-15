# WebView Render Trigger Coalescing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将渲染模式中 `fileURL`、`content`、`contentVersion` 引发的多次 WebView 操作合并为一次 final-state 渲染，同时保留强制 Reload 与内容增量替换语义。

**Architecture:** 在视图层增加纯 `WebViewRenderSnapshot` / `WebViewRenderPolicy`，它依据“文件身份、内容、强制刷新世代”选择 `.loadPage`、`.replaceContent` 或 `.none`。`WebViewMarkdownView` 的三个输入监听器只递增一个渲染请求世代；`.task(id:)` 在一次 `Task.yield()` 后读取最终快照并执行唯一操作，取消旧的增量 JavaScript 请求。

**Tech Stack:** Swift 6.2、SwiftUI `@State` / `.task(id:)`、Swift Concurrency、WebKit `WebPage`、XCTest、Swift Package Manager

---

## 实施前提

- 以当前 v2.2.7 基线为准：`loadContent()` 已经通过 `buildFullHTML(renderResult:...)` 避免重复 Markdown 解析。
- 本任务只改变 `WebViewMarkdownView` 的触发和调度层，**不改** `DocumentViewModel` 的 `contentVersion`、文件加载事务或 Raw 编辑器同步。
- 不创建/切换分支、不暂存或提交工作区中与本任务无关的改动。

### Task 1: 先用纯策略锁住渲染类型与 latest-wins 世代

**Files:**

- Create: `Sources/MarkdownReader/Views/WebViewRenderScheduler.swift`
- Create: `Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift`

**Step 1: 写出失败的策略测试**

在测试文件中添加 `@testable import MarkdownReader`，定义固定 URL helper，并断言以下 API 尚不存在：

```swift
func testInitialSnapshotLoadsFullPage() {
    let snapshot = WebViewRenderSnapshot(
        fileURL: url("a.md"), content: "# A", contentVersion: 1
    )

    XCTAssertEqual(
        WebViewRenderPolicy.action(previous: nil, next: snapshot),
        .loadPage
    )
}

func testContentOnlyChangeUsesIncrementalReplacement() {
    let previous = WebViewRenderSnapshot(
        fileURL: url("a.md"), content: "# A", contentVersion: 1
    )
    let next = WebViewRenderSnapshot(
        fileURL: url("a.md"), content: "# A changed", contentVersion: 1
    )

    XCTAssertEqual(
        WebViewRenderPolicy.action(previous: previous, next: next),
        .replaceContent
    )
}
```

再分别写出：文件 URL 改变（内容/版本相同）返回 `.loadPage`；版本改变（URL/内容相同）返回 `.loadPage`；完全相同返回 `.none`。

**Step 2: 写出失败的世代失效测试**

为 `WebViewRenderScheduler` 写入：

```swift
func testNewestRequestInvalidatesAllEarlierRequests() {
    var scheduler = WebViewRenderScheduler()
    let fileChange = scheduler.request()
    let contentChange = scheduler.request()
    let versionChange = scheduler.request()

    XCTAssertFalse(scheduler.accepts(fileChange))
    XCTAssertFalse(scheduler.accepts(contentChange))
    XCTAssertTrue(scheduler.accepts(versionChange))
}
```

这模拟一次文件切换内三个 SwiftUI 观察点依次触发；测试只验证 latest-wins token，不模拟 WebKit。

**Step 3: 运行聚焦测试并确认正确失败**

Run:

```bash
swift test --filter WebViewRenderSchedulerTests
```

Expected: 编译失败，提示 `WebViewRenderSnapshot`、`WebViewRenderPolicy`、`WebViewRenderScheduler` 尚不存在。

**Step 4: 实现最小纯策略与世代类型**

在 `WebViewRenderScheduler.swift` 实现：

```swift
struct WebViewRenderSnapshot: Equatable {
    let fileURL: URL?
    let content: String
    let contentVersion: Int
}

enum WebViewRenderAction: Equatable {
    case none
    case replaceContent
    case loadPage
}

enum WebViewRenderPolicy {
    static func action(
        previous: WebViewRenderSnapshot?,
        next: WebViewRenderSnapshot
    ) -> WebViewRenderAction {
        guard let previous else { return .loadPage }
        guard previous.fileURL == next.fileURL else { return .loadPage }
        guard previous.contentVersion == next.contentVersion else { return .loadPage }
        return previous.content == next.content ? .none : .replaceContent
    }
}

struct WebViewRenderScheduler {
    private(set) var generation: UInt = 0

    mutating func request() -> UInt {
        generation &+= 1
        return generation
    }

    func accepts(_ generation: UInt) -> Bool {
        generation == self.generation
    }
}
```

不要把这个纯决策放入 `DocumentViewModel`，不要增加 `@Observable`，也不要让策略了解 `WebPage`、主题或查找状态。

**Step 5: 运行测试并提交独立的策略基线**

Run:

```bash
swift test --filter WebViewRenderSchedulerTests
git diff --check
```

Expected: 所有新测试通过，diff 检查无输出。

Commit:

```bash
git add Sources/MarkdownReader/Views/WebViewRenderScheduler.swift Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift
git commit -m "test: define webview render scheduling policy"
```

### Task 2: 用一个 `.task(id:)` 收敛 WebView 的三个触发器

**Files:**

- Modify: `Sources/MarkdownReader/Views/WebViewMarkdownView.swift:105-156,237-308`

**Step 1: 添加状态与唯一请求入口**

在 `WebViewMarkdownView` 的 `@State` 区增加：

```swift
@State private var renderScheduler = WebViewRenderScheduler()
@State private var lastAppliedRender: WebViewRenderSnapshot?
@State private var contentReplacementTask: Task<Void, Never>?
```

实现：

```swift
private func requestRender() {
    contentReplacementTask?.cancel()
    contentReplacementTask = nil
    _ = renderScheduler.request()
}
```

保留 `page`、`scrollPosition`、`pendingScrollToLine`、`zoomLevel`、`navigationDecider` 和已有 scroll timer；删除仅为旧三分支触发逻辑服务的 `lastLoadedContent`、`lastHandledContentVersion`。

**Step 2: 让所有文档输入只请求渲染**

将三个监听器改成同一形式：

```swift
.onChange(of: content) { _, _ in requestRender() }
.onChange(of: contentVersion) { _, _ in requestRender() }
.onChange(of: fileURL) { _, _ in requestRender() }
```

在 WebView modifier 链中添加唯一出口：

```swift
.task(id: renderScheduler.generation) {
    let generation = renderScheduler.generation
    await Task.yield()
    guard !Task.isCancelled, renderScheduler.accepts(generation), isConfigured else { return }
    applyLatestRender(generation: generation)
}
```

`Task.yield()` 后必须从当前 View 输入构造快照，禁止在任一 `.onChange` 中捕获半更新的 `content`/`fileURL`。不要用 `DispatchQueue.main.asyncAfter`、`Timer` 或任意毫秒级 debounce。

**Step 3: 拆分页面配置与应用操作**

将 `configureAndLoad()` 改为 `configurePageIfNeeded()`：只创建/配置 `WebPage`、设置 `exportedPage` 和 navigation decider；不再直接调用 `loadContent()`。`.onAppear` 调用配置、注册已有 handler、同步内链 closure，再调用 `requestRender()`。

实现：

```swift
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
```

`loadContent(_:)` 必须只使用传入快照的 `fileURL`/`content`，保留 v2.2.7 的单次 `MarkdownHTMLService.render`、`WebPage.load`、滚动重置、查找栏按钮同步和待处理行号滚动。不得改动主题、padding、查找、缩放、内链或 `WebPage` 配置逻辑。

**Step 4: 运行聚焦测试与审查差异**

Run:

```bash
swift test --filter WebViewRenderSchedulerTests
git diff -- Sources/MarkdownReader/Views/WebViewRenderScheduler.swift Sources/MarkdownReader/Views/WebViewMarkdownView.swift Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift
```

Expected: 所有纯策略/世代测试通过；审查确认 `WebViewMarkdownView` 只存在一个 generation-driven 文档渲染出口。SwiftUI/WebKit 生命周期不使用脆弱的源文本匹配测试，实际调度结果由 Task 3 的断点和功能回归验证。

### Task 3: 取消旧增量 JavaScript 写入并完成回归验收

**Files:**

- Modify: `Sources/MarkdownReader/Views/WebViewMarkdownView.swift:294-308,205-210`
- Verify: `Sources/MarkdownReader/ViewModels/DocumentViewModel.swift:14-16,217-275,614-653`
- Verify: `Sources/MarkdownReader/Views/DetailView.swift:636-671`
- Verify: `Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift`

**Step 1: 让增量替换受世代保护**

将 `updateContent(_:)` 改名为 `replaceContent(_:generation:)`，接收 `WebViewRenderSnapshot` 与请求世代。保留现有 HTML 转义顺序和 `MR.replaceContent` 字符串，改为保存可取消任务：

```swift
contentReplacementTask?.cancel()
contentReplacementTask = Task { @MainActor [escapedHTML, generation] in
    guard !Task.isCancelled, renderScheduler.accepts(generation) else { return }
    _ = try? await page.callJavaScript("MR.replaceContent('\\(escapedHTML)')")
}
```

在 `.onDisappear` 中取消并置空该 task，再保留已有 cleanup。不要给 JavaScript 错误增加 UI 告警或日志；本任务只解决请求新旧关系。

**Step 2: 运行全量自动验证**

Run:

```bash
swift test
swift build
git diff --check
```

Expected: 所有测试通过，构建成功，`git diff --check` 无输出。

**Step 3: 验证单次文件切换与最终状态**

在 Debug 构建为 `applyLatestRender(generation:)` 中的 `.loadPage` 分支设置临时断点（不提交额外日志），执行：

1. 打开 A.md，再选择 B.md；
2. 在文件树中快速 A -> B -> C；
3. 对当前文件执行 Reload，即使磁盘文本未变；
4. 外部修改未脏文件，等待文件监控自动刷新；
5. Raw -> Rendered，随后切换两个文件并回到当前文件。

Expected:

- 每个稳定选择结果只命中一次 `.loadPage`；快速切换最终只显示 C.md；
- Reload 与外部刷新各保持一次完整加载；
- 没有 A/B 的旧 HTML、旧图片基路径、重复内容复制按钮或空白页；
- 同文件、同版本的纯内容替换只命中 `.replaceContent`。

**Step 4: 运行功能回归**

用包含标题、表格、代码块、图片、KaTeX、Mermaid、PlantUML 的文档验证：

- 大纲跳转和可见标题同步；
- 查找高亮/关闭查找栏；
- 缩放；
- 渲染内容复制按钮；
- 渲染模式与 Raw 模式 PDF 导出。

Expected: 所有行为与本任务前一致。Raw PDF 继续走 `MarkdownHTMLService.buildFullHTML(content:...)`；渲染模式继续导出已加载的 `exportedPage`。

**Step 5: 提交窄范围实现**

```bash
git add Sources/MarkdownReader/Views/WebViewRenderScheduler.swift Sources/MarkdownReader/Views/WebViewMarkdownView.swift Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift
git commit -m "perf: coalesce webview render triggers"
```

## 完成标准

- `WebViewMarkdownView` 的 `fileURL`、`content`、`contentVersion` 不再各自直接调用完整/增量渲染；三者只会请求同一个 generation-driven 出口。
- 一次文件切换、Reload 或外部刷新只产生一次最终完整页面加载；最后选择的文件永远胜出。
- 文件不变、版本不变、仅内容不同仍使用 `MR.replaceContent`；完全相同快照不进行任何 WebView 操作。
- 旧的异步增量 JavaScript 写入在新请求与 view 消失时被取消/世代拒绝。
- `DocumentViewModel` 的字段、赋值顺序、`contentVersion` 及 Raw 编辑器的 `EditorSyncPolicy` 不变。
- `swift test`、`swift build`、`git diff --check` 成功，且手工回归通过。

## 回滚

若出现页面不刷新、Reload 未强制刷新、内容/图片属于错误文件或 JavaScript 更新丢失，回滚本任务的三个文件：

- `Sources/MarkdownReader/Views/WebViewRenderScheduler.swift`；
- `Sources/MarkdownReader/Views/WebViewMarkdownView.swift`；
- `Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift`。

该任务不改变持久化数据、设置、资源或外部接口；回滚无需数据迁移或用户操作。

## 不包含

- 不延迟或修改 `DocumentViewModel.loadFile(at:)` 的 URL/content/version 更新；
- 不改 Markdown 解析、HTML 生成、资源按需加载、WebKit URL scheme 或 JavaScript/CSS；
- 不引入后台解析、预取、缓存、性能统计或新的用户设置；
- 不改 Raw 编辑器、窗口路由、文件树、PDF、Quick Look、版本或发布流程。

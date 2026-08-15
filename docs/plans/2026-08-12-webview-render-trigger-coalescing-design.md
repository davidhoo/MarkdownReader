# WebView 渲染触发收敛技术方案

## 背景

v2.2.7 已让一次完整加载只解析一次 Markdown；当前剩余问题在于渲染**触发**仍是分散的。

`DocumentViewModel.loadFile(at:)` 在一次文件切换事务内依次更新 `currentFileURL`、`content` 与 `contentVersion`。`WebViewMarkdownView` 分别监听这三个输入：

- `fileURL` 变化直接调用 `loadContent()`；
- `content` 变化直接调用 `loadContent()` 或 `updateContent(_:)`；
- `contentVersion` 变化直接调用 `loadContent()`。

因此一次逻辑上的“切换到 B.md”可能被拆为多次 WebView 加载或一次增量替换加一次完整加载。后续快速选文件、外部刷新和同内容 Reload 还会放大该问题。既有 `contentVersion` 同时承担 Raw 编辑器的强制覆盖合同，不能为 WebView 优化而删除、延迟或改变其递增时机。

## 目标

将 `fileURL`、`content`、`contentVersion` 视为同一份渲染快照的三个字段。任意字段变化只表示“当前快照已失效”；在本次 SwiftUI 状态更新收敛后，只对最终快照执行一次正确类型的渲染操作。

成功标准：

- 单次文件切换最多发起一次完整 `WebPage.load`；
- 单次程序化 Reload（即使文本未变）最多发起一次完整 `WebPage.load`；
- 同文件、同版本的纯内容变化仍走既有 `MR.replaceContent` 增量路径；
- 后到请求永远覆盖先到请求，不把旧文件 HTML 写回新文件页面；
- 不向用户引入可感知的定时防抖延迟。

## 选定架构

### 1. 不可变 `WebViewRenderSnapshot`

在 `Sources/MarkdownReader/Views/WebViewRenderScheduler.swift` 定义纯值类型：

```swift
struct WebViewRenderSnapshot: Equatable {
    let fileURL: URL?
    let content: String
    let contentVersion: Int
}
```

快照只表示 WebView 实际需要渲染的状态，不包含主题、padding、查找和缩放。这些现有的局部 JavaScript 更新继续独立执行，不能被误升级成完整页面重载。

### 2. 可测试的渲染决策

在同一文件定义：

```swift
enum WebViewRenderAction: Equatable {
    case none
    case replaceContent
    case loadPage
}

enum WebViewRenderPolicy {
    static func action(
        previous: WebViewRenderSnapshot?,
        next: WebViewRenderSnapshot
    ) -> WebViewRenderAction
}
```

决策规则固定为：

1. 没有已应用快照：`loadPage`；
2. `fileURL` 改变：`loadPage`，确保资源基路径、滚动重置和整页初始化均属于新文档；
3. `contentVersion` 改变：`loadPage`，保留 Reload、外部刷新及同内容强制刷新的现有语义；
4. 仅 `content` 改变：`replaceContent`；
5. 三项都相同：`none`。

该策略与 SwiftUI/WebKit 无关，必须以单元测试锁定，避免未来为了某个 UI 回归重新把三个事件处理器拆开。

### 3. 零延迟、latest-wins 的世代调度

`WebViewMarkdownView` 持有一个只递增的请求世代和最后一个已应用快照：

```swift
@State private var renderScheduler = WebViewRenderScheduler()
@State private var lastAppliedRender: WebViewRenderSnapshot?
@State private var contentReplacementTask: Task<Void, Never>?
```

`fileURL`、`content`、`contentVersion` 的所有 `.onChange` 仅调用 `requestRender()`。该方法先取消尚未开始或正在等待的增量 JavaScript 写入，再递增 `renderScheduler.generation`；它不解析 Markdown，也不调用 `page.load`。

视图使用 `.task(id: renderScheduler.generation)` 作为唯一调度出口：

1. 任务先 `await Task.yield()`，把同一轮视图更新中的多个字段变化收敛到一个 main-actor turn；
2. 检查任务没有被 `.task(id:)` 取消，并检查配置已完成；
3. 从**当前** `fileURL`、`content`、`contentVersion` 构造最终快照；
4. 根据 `WebViewRenderPolicy` 选择 `loadPage`、`replaceContent` 或 `none`；
5. 记录开始应用的快照。

`Task.yield()` 只是让同一状态事务完成的零时间让渡，不是 50/100 ms 的防抖；用户连续切换文件时，旧 `.task(id:)` 自动取消，只保留最后一个世代。

### 4. 页面加载与增量替换

把现有 `loadContent()` 改为接收 `WebViewRenderSnapshot`，只从快照读取 URL 和内容。它继续：

- 调用一次 `MarkdownHTMLService.render`；
- 调用 `buildFullHTML(renderResult:...)`；
- 重置 `scrollPosition`；
- 调用 `page.load`；
- 处理查找栏按钮显隐与待处理行号滚动。

把 `updateContent(_:)` 同样改为接收快照。它继续保留现有 HTML 转义与 `MR.replaceContent`，但其异步 `page.callJavaScript` 任务须捕获发起世代，并在调用前检查：

```swift
guard !Task.isCancelled, renderScheduler.accepts(generation) else { return }
```

`replaceContent` 分支在启动该任务时把 `lastAppliedRender` 更新为最新快照；这保证 B 的增量请求被新请求取消后，随后的 A 请求仍会被识别为一次必须的 A 替换，而不会错误地成为 `.none`。

新的渲染请求或视图消失时取消 `contentReplacementTask`。完整加载也先取消该任务，避免一个旧的增量 DOM 替换与新页面加载竞争。无法由 WebKit 中断的已进入执行阶段的调用仍由后续 `page.load` 覆盖；本方案不改变 WebKit 的导航模型。

### 5. 生命周期

`configureAndLoad()` 重命名为只配置页面的 `configurePageIfNeeded()`：创建 `WebPage` 后不直接加载内容，而是调用 `requestRender()`。`.onAppear` 也只完成配置、注册 handler、同步内链 handler，并发起一次请求。

`.onDisappear` 除了已有的 scroll timer、zoom handler 与 navigation closure 清理外，还取消 `contentReplacementTask` 并使当前世代失效。`.task(id:)` 会随视图消失自动取消，不保留后台渲染。

## 数据流

```text
fileURL / content / contentVersion 任一变化
                │
                ▼
       requestRender(): cancel + scheduler.generation += 1
                │
                ▼
       .task(id: scheduler.generation) -> Task.yield()
                │
                ▼
       读取最终 RenderSnapshot
                │
                ▼
         WebViewRenderPolicy
       ┌────────┼─────────────┐
       ▼        ▼             ▼
   loadPage  replaceContent  none
```

## 错误与并发边界

- `MarkdownHTMLService.render` 与 `page.load` 的当前错误/页面行为保持不变；此方案不吞掉或改写其错误处理。
- 增量 JavaScript 的错误继续沿用当前忽略方式；任务取消不打印、也不展示用户错误。
- 不把 SwiftUI `View` 作为跨 actor 捕获对象；任务和 `page.callJavaScript` 都保持 `@MainActor`。
- 不把任何渲染状态移动到 `DocumentViewModel`。它负责文档真实状态、脏标记、缓存与 Raw 编辑器合同；WebView 的合并、取消和 DOM 生命周期属于视图层。

## 验证

- 纯单元测试覆盖完整加载、URL 变化、版本变化、内容变化和无变化的五种策略结果；
- 纯单元测试覆盖新请求使旧世代失效；
- 真实应用验证打开、A -> B 快速切换、相同内容 Reload、外部更新、Raw -> Rendered、查找、大纲、缩放和 PDF；
- 调试器断点或 OSLog 临时观测确认一次文件切换只走一个最终 `loadPage`；实现完成前的临时观测不得保留为正式用户日志；
- `swift test`、`swift build`、`git diff --check` 全部通过。

## 不包含

- 不更改 `DocumentViewModel.loadFile(at:)` 的赋值顺序或 `contentVersion` 合同；
- 不更改 Markdown 解析、HTML 页面壳、WebKit URL scheme、Mermaid/KaTeX/Prism、JS/CSS；
- 不增加时间防抖、跨文件缓存、后台 Markdown 解析、预渲染或性能埋点；
- 不修改 Raw 编辑器、文件树选择、窗口路由、PDF/Quick Look、设置或发布流程。

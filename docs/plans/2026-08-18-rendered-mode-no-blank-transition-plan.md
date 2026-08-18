# 编辑切换渲染模式无空白 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 编辑状态切换到渲染状态时不再露出空白；普通编辑不在后台持续重渲染，且不恢复已回退的分栏预览。

**Architecture:** RawMarkdownView 与 WebViewMarkdownView 常驻于同一个 ZStack。WebView 在文档进入内容区时于后台完成首次整页加载；Raw 编辑期间忽略纯 content 变更。切到 Rendered 时，需求未变则对既有页面执行一次 MR.replaceContent；首次页面未就绪或 Mermaid/KaTeX 需求变化而必须 page.load 时，继续显示冻结的 Raw 画面，等目标渲染世代确认完成才显示 WebView。

**Tech Stack:** Swift 6.2、SwiftUI、WebPage/WebKit、swift-markdown、XCTest、Swift Package Manager。

---

## 一、问题、范围与固定合同

### 根因

DetailView.documentContentView 当前只在 displayMode 为 rendered 时创建 WebViewMarkdownView。Raw -> Rendered 时 Raw 立即透明，而新 WebView 尚须创建 WebPage、解析 Markdown、组装 HTML、调用 page.load 并等待资源和布局，因此中间显示空白。

现有 WebViewRenderPolicy 的首次快照规则仍应是 loadPage；不可为消除空白而改变首次加载、文件切换或 contentVersion 的强制刷新合同。

### 包含

- 常驻单个渲染 WebView，保留已加载页面和生命周期状态。
- Raw 编辑期暂停纯内容变化对隐藏 WebView 的渲染。
- Raw -> Rendered 的 generation 驱动过渡；增量替换与整页加载均完成后才露出 WebView。
- 纯策略单测、编译验证和 GUI 回归矩阵。

### 固定合同

1. 同一文档在 Raw 与 Rendered 间往返时，WebPage 不销毁；Raw 编辑器的 per-file undo、滚动和焦点合同不变。
2. Raw 编辑的每次击键不得调用 MarkdownHTMLService.render、MR.replaceContent 或 page.load。
3. Raw -> Rendered 必须显示最新 documentViewModel.content，不得露出空白，也不得先显示旧渲染内容。
4. 普通 Markdown 走一次 MR.replaceContent；新增或删除 Mermaid / KaTeX 时继续走既有整页加载策略。
5. 整页加载时继续显示 Raw 的只读过渡画面；ViewModel 已是 Rendered，过渡层不得再接收编辑。
6. 不做磁盘缓存，不恢复分栏预览，不加入时间防抖，不改变 PDF、Quick Look、文件切换或 contentVersion 语义。

## 二、目标数据流

    首次进入内容区 / 文件或 contentVersion 改变
      -> 常驻 WebView requestRender()
      -> loadPage（隐藏状态下预热）

    Raw 期间纯 content 改变
      -> 不 requestRender；WebView 保持上次已应用快照

    Raw -> Rendered
      -> DetailView 开始 transitionPending，Raw 保持可见但不可编辑
      -> WebView requestRender() 读取最新快照
           ├─ requirements 相同：MR.replaceContent -> generation 完成
           └─ requirements 改变或初始页未就绪：page.load -> isLoading == false
      -> 仅匹配当前目标 generation 的完成回调可结束过渡
      -> 隐藏 Raw，显示 WebView

必须区分“快照已接受”和“页面已完成”。lastAppliedRender 不能在 page.load 尚未完成时允许 WebView 显示。

## 三、实施任务

### Task 0：建立隔离基线并固定 red 观察

**Files:**

- Create: 无。
- Verify: Sources/MarkdownReader/Views/DetailView.swift、Sources/MarkdownReader/Views/WebViewMarkdownView.swift、Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift。

**Step 1: 创建干净 worktree**

    git status --short --branch
    git fetch origin main --tags
    git worktree add -b codex/rendered-mode-no-blank ../MarkdownReader-rendered-mode-no-blank main
    cd ../MarkdownReader-rendered-mode-no-blank
    git status --short --branch
    git log -1 --oneline

Expected: 新 worktree 干净。若主线已前进，先审查三个相关文件的差异；不要触碰原工作区已有的未跟踪文件。

**Step 2: 记录当前失败**

用包含标题、代码块、长段落的本地 Markdown：Raw 中编辑一行后立即切 Rendered，确认当前在新 WebView 加载前露出空白。再在 Raw 新增 Mermaid 代码块，确认其会走整页加载分支。样本文档和截图均不提交。

### Task 1：为过渡状态写失败测试并实现纯状态机

**Files:**

- Modify: Sources/MarkdownReader/Views/WebViewRenderScheduler.swift
- Modify: Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift

**Step 1: 写失败测试**

在既有 scheduler 测试中加入：

    func testRenderedTransitionWaitsForRequestedGeneration() {
        var transition = RenderedModeTransitionState()
        transition.begin()
        transition.track(generation: 8)

        XCTAssertTrue(transition.keepsRawVisible)
        XCTAssertFalse(transition.completeIfMatching(generation: 7))
        XCTAssertTrue(transition.keepsRawVisible)
        XCTAssertTrue(transition.completeIfMatching(generation: 8))
        XCTAssertFalse(transition.keepsRawVisible)
    }

    func testNewTransitionInvalidatesOlderCompletion() {
        var transition = RenderedModeTransitionState()
        transition.begin()
        transition.track(generation: 4)
        transition.track(generation: 5)

        XCTAssertFalse(transition.completeIfMatching(generation: 4))
        XCTAssertTrue(transition.completeIfMatching(generation: 5))
    }

**Step 2: 确认 red**

    swift test --filter WebViewRenderSchedulerTests

Expected: 编译失败，缺少 RenderedModeTransitionState。

**Step 3: 最小实现**

在 scheduler 文件新增不依赖 SwiftUI/WebKit 的类型：

    struct RenderedModeTransitionState: Equatable {
        private(set) var targetGeneration: UInt?
        private(set) var keepsRawVisible = false

        mutating func begin() { /* 立即置 true，target 为空 */ }
        mutating func track(generation: UInt) { /* 记录真实 target generation */ }
        mutating func completeIfMatching(generation: UInt) -> Bool { /* 仅匹配时置 false */ }
        mutating func cancel() { /* 清除 target 并置 false */ }
    }

它仅管理 Raw 过渡层是否可见，不能取代 WebViewRenderScheduler 的 latest-wins 判定。

**Step 4: 确认 green**

    swift test --filter WebViewRenderSchedulerTests

Expected: 既有 render policy、runtime policy 和新增过渡测试均通过。

**Step 5: Commit**

    git add Sources/MarkdownReader/Views/WebViewRenderScheduler.swift Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift
    git commit -m "test: define rendered mode transition state"

### Task 2：为 Raw 编辑期建立纯渲染闸门

**Files:**

- Modify: Sources/MarkdownReader/Views/WebViewRenderScheduler.swift
- Modify: Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift

**Step 1: 写失败测试**

为小型 change-kind 枚举和纯策略 WebViewRenderEligibility.shouldRequest(change:isRenderedMode:) 加入：

    func testRawContentEditDoesNotRequestWebViewRender() {
        XCTAssertFalse(WebViewRenderEligibility.shouldRequest(
            change: .content, isRenderedMode: false
        ))
    }

    func testFileAndForcedRefreshStillPrewarmWhileRaw() {
        XCTAssertTrue(WebViewRenderEligibility.shouldRequest(
            change: .fileURL, isRenderedMode: false
        ))
        XCTAssertTrue(WebViewRenderEligibility.shouldRequest(
            change: .contentVersion, isRenderedMode: false
        ))
    }

    func testEnteringRenderedModeRequestsLatestContent() {
        XCTAssertTrue(WebViewRenderEligibility.shouldRequest(
            change: .displayMode, isRenderedMode: true
        ))
    }

**Step 2: 确认 red**

    swift test --filter WebViewRenderSchedulerTests

Expected: 编译失败，缺少 eligibility 类型或策略。

**Step 3: 最小实现与 green**

实现只含 content、fileURL、contentVersion、displayMode 的枚举和策略：

- content 仅在 isRenderedMode 为 true 时请求；
- fileURL、contentVersion 始终请求，保证隐藏 WebView 在新文件和 Reload 后预热；
- displayMode 仅在进入 Rendered 时请求。

    swift test --filter WebViewRenderSchedulerTests

Expected: 全部 scheduler tests 通过。

**Step 4: Commit**

    git add Sources/MarkdownReader/Views/WebViewRenderScheduler.swift Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift
    git commit -m "test: gate hidden webview content rendering"

### Task 3：实现常驻 WebView 和 generation 完成回调

**Files:**

- Modify: Sources/MarkdownReader/Views/DetailView.swift:604-721
- Modify: Sources/MarkdownReader/Views/WebViewMarkdownView.swift:74-495,571-620
- Modify: Sources/MarkdownReader/Views/WebViewRenderScheduler.swift
- Test: Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift

**Step 1: 扩展 WebViewMarkdownView 的输入和事件**

新增：

- isRenderedMode: Bool。
- onRenderRequested: (UInt) -> Void；只能由实际 requestRender() 报告 generation。
- onRenderGenerationCompleted: (UInt) -> Void；只能在最新 generation 的内容已更新或整页加载已结束后报告。

把文档 input 的 onChange 收敛成 Task 2 的 eligibility 策略：

- fileURL 和 contentVersion：不论模式都 requestRender，保证隐藏的常驻 WebView 在新文件和 Reload 后预热；
- content：只有 Rendered 才 requestRender；
- isRenderedMode 从 false 变 true：请求一次最新快照；变 false 不请求；
- handleAppear() 仍发起首次请求，即使初始为 Raw。

**Step 2: 将“完成”落在真实边界**

- none：仅当页面不在加载中时立即完成；仍加载时记录等待完成 generation。
- replaceContent：page.callJavaScript 成功返回后，再检查 renderScheduler.accepts(generation) 才回调完成；取消、过期 generation 或 JavaScript 失败都不得回调。
- loadPage：记录等待 generation；仅在 page.isLoading 变 false 且 generation 仍最新时回调完成。
- handleDisappear() 清除等待 generation、取消 contentReplacementTask，不允许已销毁页面回调 DetailView。

保留 pending line-scroll、zoom restore、内链 handler 和文档复制行为。不得用 timer、asyncAfter 或固定 loading 时长判断页面就绪。

**Step 3: 改造 DetailView 视图树**

1. 添加 @State private var renderedTransition = RenderedModeTransitionState()。
2. Raw 继续常驻；可见条件改为 displayMode 为 raw 或 renderedTransition.keepsRawVisible。命中测试仍仅允许 displayMode 为 raw。
3. 删除包裹 WebViewMarkdownView 的 if displayMode == rendered；改为始终插入同一个 WebView，用 opacity 与 hit testing 控制可见性和交互。
4. 在 titleBar Picker 的 Binding setter 内，Raw -> Rendered 时先调用 renderedTransition.begin()，再调用 documentViewModel.switchDisplayMode(mode)，保证同一 SwiftUI 更新中 Raw 已被保留；WebView 随后经 onRenderRequested 提供真实 generation，调用 track(generation:)。不得由 DetailView 猜 generation。若将来出现其他模式切换入口，必须复用这一“先 begin、后切 mode”的路径。
5. onRenderGenerationCompleted 调用 completeIfMatching。完成前 Raw 保持可见，完成后才露出 WebView。Rendered -> Raw 及 DetailView 消失时调用 cancel()。
6. exportedPage 继续绑定这唯一 WebView；现有 exportPDF() 仍只在 Rendered 状态导出。

实现前在运行时确认 macOS 26 的 opacity(0) WebView 会继续导航。若不成立，改为保留 WebView 在布局树且以非交互遮罩覆盖；不可用接近零的不透明度或固定延迟规避问题。

**Step 4: 运行 focused 验证**

    swift test --filter WebViewRenderSchedulerTests
    swift build

Expected: tests 通过、主 target 编译通过；不得出现 Swift 6 actor isolation、closure capture 或 WebPage 生命周期警告。

**Step 5: Commit**

    git add Sources/MarkdownReader/Views/DetailView.swift Sources/MarkdownReader/Views/WebViewMarkdownView.swift Sources/MarkdownReader/Views/WebViewRenderScheduler.swift Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift
    git commit -m "fix: keep rendered page ready across mode switches"

### Task 4：全量验证与 GUI 验收

**Files:**

- Modify: 无；若验证发现可复现缺陷，先补对应 red 测试，再做最小修正。
- Verify: Task 3 的四个文件。

**Step 1: 执行自动验证**

    swift test
    swift build
    swift build -c release
    git diff --check
    git status --short

Expected: 前四项成功，git diff --check 无输出；status 只含本任务预期文件。

**Step 2: 运行实际应用**

    swift run MarkdownReader

| 场景 | 验收结果 |
|---|---|
| 普通 Markdown，Raw 编辑 1–3 行后切 Rendered | 不露出底色空白；最终只显示最新渲染内容。 |
| Rendered -> Raw -> Rendered，未修改 | 立即显示已就绪页面，不重新整页 load。 |
| 长文档 Raw 连续输入 | 不因每个字符重渲染隐藏 WebView，编辑无新增卡顿。 |
| Raw 中新增/删除 Mermaid 或 KaTeX 后切 Rendered | 可保留只读 Raw 过渡画面；最终图表/公式正确，无空白或旧内容。 |
| Raw 中切换文件、外部 Reload 后切 Rendered | 新文件和相对资源路径正确，无旧文件闪回。 |
| 查找、大纲、缩放、内容复制、PDF 导出 | 现有行为不变；PDF 使用当前常驻 page。 |
| 快速切模式/切文件、关闭窗口 | 无崩溃、无 stale JS 覆盖、无析构后回调。 |

**Step 3: Commit 测试补充（如有）**

Task 4 没有代码变化时不创建空提交。若补了必要自动化测试，必须先 red/green，再：

    git add <only-verified-files>
    git commit -m "test: cover rendered mode transition regression"

## 四、回滚

本任务只影响 DetailView、WebViewMarkdownView、WebViewRenderScheduler 和其测试。若出现隐藏 WebView 不完成导航、旧内容可见、Raw 输入性能下降、PDF 引用错误页面或生命周期崩溃，回滚本任务提交即可恢复当前条件创建 WebView 的行为。不要回滚 972b677 的编辑器末尾滚动修复，也不改变 v2.3.1 的分栏预览回退。

## 五、不包含

- Markdown HTML、RenderResult、WebView 页面或资源的磁盘/跨进程缓存。
- 分栏预览、实时预览按钮、第二个 WebView、200 ms 输入防抖。
- DocumentViewModel.switchDisplayMode(_) 的源码位置同步、per-file undo、文件内容缓存与 contentVersion 合同。
- Markdown 解析、HTML/CSS/JavaScript、Mermaid/KaTeX/Prism 资源、URL scheme handler、PDF、Quick Look、设置、版本或本地化。
- 用定时器、固定延迟或 loading mask 掩盖 WebView 生命周期问题。

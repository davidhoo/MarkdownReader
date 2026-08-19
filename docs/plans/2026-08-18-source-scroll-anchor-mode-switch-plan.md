# MarkdownReader 单栏模式切换源码锚点同步 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** 让单栏 Raw（编辑）与 Rendered（渲染）模式在切换时稳定定位到同一阅读位置；支持多行 Markdown 块、异步渲染和快速连续切换，不移动光标或选区。

**Architecture:** 用可带小数的 `SourceScrollAnchor` 代替单一整数 `SourceLine` 作为模式切换的位置载体。渲染 HTML 为可定位块输出完整源码行范围，Raw 与 Rendered 都以视口顶部为同一锚点语义在范围内做比例换算；一次性 `ScrollTransfer` 明确目的模式、内容版本和请求身份，只有目标视图可以确认并清除。现有 `SourceLine`、大纲和查找跳转保持原协议，不能被此次改造混用或替换。

**Tech Stack:** Swift 6、SwiftUI、AppKit (`NSTextView`)、WebPage/WebKit JavaScript bridge、swift-markdown、XCTest、Swift Package Manager。

---

## 一、问题与固定契约

当前实现虽已分别记录 `rawVisibleSourceLine` 与 `renderedVisibleSourceLine`，但仍有三类结构性问题：

1. 采样、落点语义不一致：Raw 读视口顶部，Rendered 以距顶部阈值选块，而两个目标端分别使用约 1/3 与居中定位。
2. `data-line` 只代表渲染块起始行。Raw 停在一个多行段落、表格或代码块内部时，没有足够信息在 Rendered 中恢复块内位置。
3. Raw 和 Rendered 是常驻视图，却共用无目的地的 `scrollToSourceLineRequest`，并通过两个固定延迟清除请求；隐藏视图可以抢先消费或清除请求，快速切换还会让旧异步结果覆盖新状态。

本任务建立如下合同：

| 名称 | 含义 | 仅用于 |
|---|---|---|
| `SourceLine` | 整数、1-based 源码行 | 大纲、查找、标题跳转及既有公开协议 |
| `SourceScrollAnchor` | `sourcePosition` 为 1-based 小数源码位置，含全文进度兜底 | Raw ↔ Rendered 模式切换 |
| `ScrollTransfer` | 带 UUID、目标模式、内容版本和锚点的一次性交接 | 单栏模式切换的目的视图消费/确认 |

- 两个模式都以**视口顶部**采样、也以**视口顶部**落点；切换定位不使用平滑动画。
- `sourcePosition` 的 `18.4` 表示第 18 行到第 19 行之间的 40% 位置。它不是数组索引，也不得传给大纲或查找。
- 完整块范围为闭区间 `[start, end]`；映射时使用半开范围 `[start, end + 1)`，从而单行块也有非零跨度。
- 源码范围、DOM 布局或 Raw 排版任一不可用时，才使用 `documentProgress`；两者都不可用时降级到文档顶部。
- 仅目标模式可消费 `ScrollTransfer`；定位真正应用后以相同 UUID 回执。不得再通过 `asyncAfter` 猜测消费完成。
- 任何采样或回执都必须验证 `contentVersion` 和切换 token；过期内容、过期模式或快速 A→B→A 切换产生的回调必须丢弃。

## 二、范围

### 包含

- 单栏 Raw → Rendered、Rendered → Raw 的位置交接。
- 多行段落、嵌套列表、代码块、表格和标题的源码范围映射。
- Raw / WebView 的同步采样与立即定位。
- 现有 Rendered 过渡遮罩等待“目标页面已渲染且锚点已落位”。
- TDD、单元/真实 AppKit 布局测试、完整构建和 GUI 验收。

### 不包含

- 分栏编辑模式、持续双向滚动、滚动主控端或滚动回环抑制。
- 文档重新打开后的滚动位置持久化、渲染缓存或磁盘缓存。
- 大纲、查找、PDF、Quick Look、主题、缩放、复制、WebView 生命周期或内容渲染策略的功能改动。
- 改动现有 `RenderedModeTransitionState` 的“防空白”语义以外的动画/加载行为。
- 通过移动 `NSTextView` 光标、选区或调用 `scrollRangeToVisible` 来实现模式切换定位。

## 三、实施任务

### Task 1：定义锚点和目标化交接的纯状态合同（RED → GREEN）

**Files:**

- Create: `Sources/MarkdownReaderKit/Models/SourceScrollAnchor.swift`
- Modify: `Sources/MarkdownReader/ViewModels/DocumentViewModel.swift`
- Modify: `Tests/MarkdownReaderTests/SourcePositionSyncTests.swift`

**Step 1: 写失败测试**

先追加纯模型断言，覆盖小数位置、进度和交接身份：

```swift
func testSourceScrollAnchorPreservesFractionalSourcePosition() {
    let anchor = SourceScrollAnchor(sourcePosition: 18.4, documentProgress: 0.63)

    XCTAssertEqual(anchor.sourcePosition, 18.4, accuracy: 0.0001)
    XCTAssertEqual(anchor.documentProgress, 0.63, accuracy: 0.0001)
}

@MainActor
func testScrollTransferCanOnlyBeAcknowledgedByItsDestinationAndID() {
    let viewModel = DocumentViewModel()
    let transfer = viewModel.beginScrollTransfer(
        destination: .rendered,
        anchor: SourceScrollAnchor(sourcePosition: 18.4, documentProgress: 0.63)
    )

    viewModel.acknowledgeScrollTransfer(id: transfer.id, destination: .raw)
    XCTAssertEqual(viewModel.scrollTransfer?.id, transfer.id)

    viewModel.acknowledgeScrollTransfer(id: transfer.id, destination: .rendered)
    XCTAssertNil(viewModel.scrollTransfer)
}
```

再加两例：错误 UUID 不得清除当前请求；`documentProgress` 只能落在 `0...1`（由 initializer 明确钳制或 precondition，选择一种并在实现与测试中保持一致）。

**Step 2: 运行 RED**

Run: `swift test --filter SourcePositionSyncTests`

Expected: 因缺少 `SourceScrollAnchor`、`ScrollTransfer` 和 ViewModel API 而编译失败。

**Step 3: 写最小实现**

1. 在 Kit 新增 `SourceScrollAnchor: Equatable, Sendable`，保存 `sourcePosition: Double` 与 `documentProgress: Double`。`sourcePosition >= 1`；进度在初始化边界钳制到 `0...1`。
2. 在 `DocumentViewModel` 新增仅供模式切换使用的 `scrollTransfer: ScrollTransfer?`，不要复用或重命名现有大纲/查找的 `scrollToSourceLineRequest`。
3. `ScrollTransfer` 保存 `id: UUID`、`destination: DisplayMode`、`contentVersion: Int`、`anchor`。
4. `beginScrollTransfer` 生成新 UUID 覆盖旧交接；`acknowledgeScrollTransfer` 仅当 id、destination、contentVersion 全部匹配时清除。

**Step 4: 运行 GREEN**

Run: `swift test --filter SourcePositionSyncTests`

Expected: 纯模型测试通过；现有 `SourceLine`、大纲和查找断言不需要修改。

### Task 2：让渲染 HTML 暴露完整源码块范围（RED → GREEN）

**Files:**

- Modify: `Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift`
- Modify: `Tests/MarkdownReaderTests/SourcePositionSyncTests.swift`

**Step 1: 写失败测试**

添加一个含多行段落、列表和围栏代码块的 Markdown：

```swift
func testRenderedBlocksExposeInclusiveSourceRanges() {
    let markdown = """
    # Title

    first paragraph line
    second paragraph line

    - first item
    - second item

    ```swift
    let value = 1
    ```
    """

    let html = MarkdownHTMLService.render(markdown).html

    XCTAssertTrue(html.contains(#"<p data-source-start=\"3\" data-source-end=\"4\">"#))
    XCTAssertTrue(html.contains(#"<pre data-source-start=\"8\" data-source-end=\"10\">"#))
}
```

另测无可信 `Markup.range` 的元素不输出 `data-source-start`、`data-source-end` 或第 0 行的伪锚点。

**Step 2: 运行 RED**

Run: `swift test --filter SourcePositionSyncTests`

Expected: 缺少范围属性，或多行块仍只有 `data-line`，断言失败。

**Step 3: 写最小实现**

1. 在 `CustomHTMLFormatter` 增加私有 helper，从 `Markup.range` 生成 `data-source-start` / `data-source-end`。结束行按 Markdown range 的实际闭区间计算；若上界位于下一行第 1 列，结束行应回退一行，且最终不得小于开始行。
2. 将该 helper 用于 heading、paragraph、code block、block quote、unordered/ordered list、list item、table、thematic break 等现有带 `data-line` 的可定位块。
3. 保留现有 `data-line`，使大纲/查找与 `MR.scrollToLine` 行为不变；不为无 range 的块制造 `0` 位置。
4. 不为 inline 元素、HTML block 或复制控件增加范围属性。

**Step 4: 运行 GREEN**

Run: `swift test --filter SourcePositionSyncTests`

Expected: 多行与单行块范围正确；既有标题 `data-line` 测试仍通过。

### Task 3：实现纯映射策略与 Rendered JavaScript bridge（RED → GREEN）

**Files:**

- Modify: `Sources/MarkdownReader/Resources/js/markdown-reader.js`
- Modify: `Sources/MarkdownReader/Views/WebViewMarkdownView.swift`
- Modify: `Tests/MarkdownReaderTests/SourcePositionSyncTests.swift`

**Step 1: 写失败测试**

为 Swift 侧纯策略新增测试，至少覆盖：

```swift
func testSourceAnchorUsesExactPositionBeforeDocumentProgressFallback() {
    let anchor = SourceScrollAnchor(sourcePosition: 18.4, documentProgress: 0.63)
    XCTAssertEqual(SourceAnchorResolution.mode(for: anchor, canResolveSourcePosition: true), .sourcePosition)
    XCTAssertEqual(SourceAnchorResolution.mode(for: anchor, canResolveSourcePosition: false), .documentProgress)
}
```

如果现有测试目标无法直接执行 WebView JavaScript，不伪造 `WebPage` 成功。改为断言 bridge 输入/结果解码、HTML 源码范围，以及在 GUI 验收中覆盖浏览器布局行为。

**Step 2: 运行 RED**

Run: `swift test --filter SourcePositionSyncTests`

Expected: 缺少策略类型或 bridge 解码入口而失败。

**Step 3: 写最小实现**

在 `markdown-reader.js` 新增且仅供模式交接使用的 API：

```javascript
MR.captureSourceScrollAnchor()
MR.scrollToSourceScrollAnchor(sourcePosition, documentProgress)
```

实现规则：

1. `capture` 读取 `window.scrollY`（视口顶部），收集所有具有完整范围的元素；使用 content box（排除 CSS padding）构造 `{ start, end, top, bottom, height }`。
2. 顶部被多个嵌套块覆盖时，选择高度最小的块；在块内以垂直比例计算 `start + progress * (end + 1 - start)`。
3. 顶部位于两个块之间时，用前后块的布局和源码范围线性插值；在首块之前或尾块之后钳制到边界。
4. `scrollTo` 反向使用相同规则：优先选择包含小数源码位置的最小块，计算对应内容 box Y；找不到时在相邻源码范围之间插值，最终才用全文 `documentProgress`。
5. 定位使用即时 `window.scrollTo({ top, behavior: "auto" })`；在至少一个 `requestAnimationFrame` 后返回 `true`，供 Swift 侧当作“已落位”回执。失败返回 `false`。
6. 不修改 `MR.getTopVisibleLine`、`MR.scrollToLine`、大纲高亮、搜索或复制 API。

在 `WebViewMarkdownView`：

1. 增加输入 `scrollTransfer: ScrollTransfer?`、输出 `onScrollTransferApplied: (UUID) -> Void` 和 `captureSourceScrollAnchor` completion。
2. 只在 `transfer.destination == .rendered`、`transfer.contentVersion == contentVersion` 且页面/最新渲染世代就绪时调用新 bridge。
3. JS 回报成功后才调用回执；页面加载中保存待处理 transfer，加载结束后验证它仍是同一 id/version 再执行。
4. 删除此路径对 `scrollToSourceLineRequest` 的任何读写；该旧输入仍专用于大纲/查找。

**Step 4: 运行 GREEN**

Run: `swift test --filter SourcePositionSyncTests`

Expected: 纯策略/解码测试通过；编译器确认新的 WebView 交接 API 完整接线。

### Task 4：实现 Raw 锚点采样和无光标定位（RED → GREEN）

**Files:**

- Modify: `Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift`
- Modify: `Sources/MarkdownReader/Views/RawMarkdownView.swift`
- Modify: `Tests/MarkdownReaderTests/SourcePositionSyncTests.swift`

**Step 1: 写失败的真实 AppKit 布局测试**

在现有 `NSTextView` / `NSScrollView` fixture 上增加：

1. 60 行不同长度文本，视口放在第 20 行中部；采样锚点应位于 `20...21` 之间，而非整数行或第 1 行。
2. 用该锚点应用到一个新建的同配置编辑器；其视口顶部对应行和行内比例应与源编辑器相差不超过一个 line fragment 的小误差。
3. 读取与应用前后 `selectedRange()` 完全相同。
4. 测 Unicode UTF-16 内容、文档顶部和最后一行，确认不越界。

**Step 2: 运行 RED**

Run: `swift test --filter SourcePositionSyncTests`

Expected: 缺少 Raw 锚点 helper 或实现仍使用 `scrollRangeToVisible`，测试失败。

**Step 3: 写最小实现**

1. 在 `SyntaxHighlightedEditor` 附近新增内部 `RawSourceScrollAnchor` helper：把 `NSClipView.bounds` 顶部转换为 text container 坐标，取得 glyph / character / line fragment。
2. 通过已有 UTF-16 行转换得到 1-based 行号，再以 `(viewportTop - fragment.minY) / fragment.height` 计算并钳制行内比例，构造小数 `sourcePosition`；同时计算 Raw 全文滚动进度。
3. 反向定位时，将小数行号拆成目标 `SourceLine` 与行内比例，通过 layout manager 定位 fragment，直接设置 clip view 的 bounds origin 并按文档高度、视口高度、系统 inset 钳制；不得设置选区，也不得调用 `scrollRangeToVisible`。
4. Raw 仅在 `ScrollTransfer.destination == .raw` 且 version/id 匹配时应用并回执。隐藏 Raw 不能采样、不能消费 Rendered 目标请求。
5. `RawMarkdownView` 只透传新的 capture / transfer / acknowledge closure；删除此次模式切换路径对 `rawVisibleSourceLine` 的依赖，但暂不删除其余可能仍服务 UI 的已有可见行回调，先用 `rg` 确认引用后最小处理。

**Step 4: 运行 GREEN**

Run: `swift test --filter SourcePositionSyncTests`

Expected: Raw 采样、比例应用、选区不变及 UTF-16 边界全部通过。

### Task 5：由 DetailView 协调采样、渲染和确认（RED → GREEN）

**Files:**

- Modify: `Sources/MarkdownReader/ViewModels/DocumentViewModel.swift`
- Modify: `Sources/MarkdownReader/Views/DetailView.swift`
- Modify: `Sources/MarkdownReader/Views/WebViewMarkdownView.swift`
- Modify: `Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift`
- Modify: `Tests/MarkdownReaderTests/SourcePositionSyncTests.swift`

**Step 1: 写失败的交接生命周期测试**

在 ViewModel 测试中覆盖：

```swift
@MainActor
func testNewModeSwitchInvalidatesOlderUnacknowledgedTransfer() {
    let viewModel = DocumentViewModel()
    let first = viewModel.beginScrollTransfer(
        destination: .rendered,
        anchor: SourceScrollAnchor(sourcePosition: 18.4, documentProgress: 0.63)
    )
    let second = viewModel.beginScrollTransfer(
        destination: .raw,
        anchor: SourceScrollAnchor(sourcePosition: 6.2, documentProgress: 0.18)
    )

    viewModel.acknowledgeScrollTransfer(id: first.id, destination: .rendered)
    XCTAssertEqual(viewModel.scrollTransfer?.id, second.id)
}
```

再加一个内容版本改变后旧回执不能清除新请求的断言。

**Step 2: 运行 RED**

Run: `swift test --filter SourcePositionSyncTests`

Expected: 生命周期测试未被现有无身份 `SourceLine?` 请求满足。

**Step 3: 写最小实现**

1. 将 `DetailView` 分段 Picker 的 set closure 改为“先向当前活跃视图采样，再创建目标 `ScrollTransfer`，最后更新 display mode”的协调入口。Rendered 采样是异步 JavaScript，必须用切换 token 防止较晚回调覆盖后一次选择。
2. Raw → Rendered 继续调用 `renderedTransition.begin()`，但结束条件改为：目标渲染世代完成 **且** 相同 transfer 已由 WebView 回执。Raw 保持可见直到两个条件均满足。
3. Rendered → Raw 在 Raw 成功应用相同 transfer 后显示并聚焦编辑器；采样失败时用 `documentProgress` 继续交接，不得回退到旧的 `renderedVisibleSourceLine`。
4. 移除 `DetailView` 中两个针对 `scrollToSourceLineRequest` 的 `asyncAfter` 清除 observer。`clearScrollRequest()` 和旧 `scrollToSourceLineRequest` 仅保留给大纲/查找等既有用途，不能被模式切换调用。
5. 切换按钮连续操作时，未完成的渲染过渡、pending JS scroll 和 Raw pending apply 都必须只接受最新 token/id；旧请求不得结束新的遮罩状态。

**Step 4: 运行 GREEN**

Run: `swift test --filter SourcePositionSyncTests`

Expected: 目标校验、快速切换和内容版本失效测试通过；现有模式切换/渲染过渡测试不回归。

### Task 6：完整验证与 GUI 验收

**Files:**

- Verify: `Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift`
- Verify: `Sources/MarkdownReader/Resources/js/markdown-reader.js`
- Verify: `Sources/MarkdownReader/Views/WebViewMarkdownView.swift`
- Verify: `Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift`
- Verify: `Sources/MarkdownReader/Views/DetailView.swift`
- Verify: `Tests/MarkdownReaderTests/SourcePositionSyncTests.swift`

**Step 1: 运行针对性测试**

Run: `swift test --filter SourcePositionSyncTests`

Expected: 源码范围、锚点、Raw AppKit 布局、请求身份与过期交接测试均通过。

**Step 2: 运行完整自动验证**

Run: `swift test`

Run: `swift build`

Run: `swift build -c release`

Run: `git diff --check`

Run: `git status --short --branch`

Expected: 全部测试通过，Debug/Release 构建成功，diff 无空白错误；只报告本任务明确修改的文件，不覆盖用户已有工作。

**Step 3: GUI 验收矩阵**

Run: `swift run MarkdownReader`

使用包含多行段落、嵌套列表、围栏代码块、表格、图片和文首/文末内容的长 Markdown，逐项确认：

1. Raw 停在多行段落中部 → Rendered：同一段内容在渲染视口顶部附近，而非只跳到段首或最近标题。
2. Rendered 停在长块中部 → Raw：编辑器显示同一源码范围的相对位置，不回到上一次 Raw 停留点。
3. 文首 padding、文末、代码块与表格均不越界、不出现明显位置反转。
4. Raw 或 Rendered 经大纲跳转后切换，仍以当前实际阅读位置为准。
5. Raw 修改内容后首次切 Rendered：新内容立即正确显示，且没有空白闪现回归。
6. 连续快速切换 10 次、在一次 Rendered 采样未返回时再次切换：最终只服从最后一次选择。
7. 模式切换不改变 Raw 光标/选区；大纲、查找、PDF、Quick Look 与缩放行为保持原样。

## 四、回滚

- 若渲染页无法恢复锚点或出现空白，先保留现有 WebView 常驻和渲染 ACK 机制，仅回退此次 `ScrollTransfer` 接线；不得回退不相关的渲染稳定性修复。
- 若仅个别 Markdown 块映射错误，保留交接状态机，收窄该块的 `data-source-start/end` 生成；不要改回整数行号或增加新的延迟清除器。
- 若 Raw 定位改变光标、选区或引入文末抖动，回退 Raw 的 anchor apply 路径并恢复现有编辑器滚动保护；不要用 `setSelectedRange` 作为替代定位手段。
- 需要撤回时使用可恢复的 `git revert` 针对实际实施提交；不得使用 `git reset --hard`，也不得删除未跟踪的任务文档。

## 五、实施边界

- 本文档不指定 commit 信息、commit 命令或提交拆分；由实施时的当前工作区状态和用户授权决定。
- 本任务完成后，若未来实现分栏编辑，应复用 `SourceScrollAnchor`、HTML 范围映射和目标化回执，但另立需求处理连续双向同步与防回环。

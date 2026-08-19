# MarkdownReader 单栏模式切换锚点与旧行号请求冲突修复 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** 修复单栏模式下 Rendered → Raw 会回到文首的问题，让 Raw ↔ Rendered 都只以最新的 `SourceScrollAnchor` 完成位置交接。

**Architecture:** `ScrollTransfer` 是 Raw/Rendered 模式切换唯一的位置通道；`scrollToSourceLineRequest` 只保留给大纲与查找等显式跳转。模式切换不得再发布旧行号请求，并要清除正在等待的旧请求；分段控件、菜单和快捷键必须进入同一 `DetailView` 切换管线，确保主动采样、token 校验与交接回执全部执行。

**Tech Stack:** Swift 6、SwiftUI、AppKit (`NSTextView`)、WebPage/WebKit JavaScript bridge、XCTest、Swift Package Manager。

---

## 一、已确认根因

当前 `DetailView.handleDisplayModeSwitch` 已启动 `SourceScrollAnchor` / `ScrollTransfer` 交接，但它先调用 `DocumentViewModel.switchDisplayMode(_:)`。后者仍在两个方向调用 `requestScroll`：

- Raw → Rendered：`rawVisibleSourceLine`；
- Rendered → Raw：`renderedVisibleSourceLine`。

Rendered → Raw 时，该旧请求会传入 `SyntaxHighlightedEditor.updateNSView` 并异步执行按行滚动；新的锚点交接也在此后被应用和回执。回执清空 `scrollTransfer` 会触发一次新的 SwiftUI 更新，而旧 `scrollToSourceLineRequest` 在 0.5 秒后才清除，于是编辑器又一次按旧行号滚动，覆盖已经正确落位的锚点。

`renderedVisibleSourceLine` 还是 300ms 防抖的被动滚动采样；用户刚滚动就切换时，它常仍为 `.first`，所以最终表象是直接回到顶部。

此外，菜单和快捷键经 `WindowCommandTarget.perform(.switchDisplayMode)` 直接调用 `DocumentViewModel.switchDisplayMode`，完全绕过 `DetailView.handleDisplayModeSwitch`；即使修复分段控件，该入口也会失去主动采样和 token 保护。

## 二、固定合同与范围

### 固定合同

| 场景 | 唯一位置通道 | 不得使用 |
|---|---|---|
| Raw ↔ Rendered 模式切换 | `SourceScrollAnchor` + `ScrollTransfer` | `scrollToSourceLineRequest`、`rawVisibleSourceLine`、`renderedVisibleSourceLine` |
| 大纲点击、查找上一个/下一个、标题跳转 | `scrollToSourceLineRequest` | `ScrollTransfer` |

- 模式切换开始前取消遗留的旧行号请求；之后直到目标视图回执，不得产生新的旧行号请求。
- 模式切换的位置以源视图**当下主动采样**到的锚点为准，而不是 300ms 防抖缓存。
- 分段控件、菜单和快捷键必须共用同一切换入口。
- 保持已有 `RenderedModeTransitionState` 防空白语义；不为本修复新增延迟作为同步手段。

### 包含

- 单栏 Raw → Rendered 和 Rendered → Raw 的旧行号请求隔离。
- 分段控件、菜单和快捷键的模式切换入口统一。
- 针对本回归的 XCTest 与人工 GUI 验收。

### 不包含

- 分栏编辑、持续双向滚动或滚动回环抑制。
- 渲染缓存、磁盘缓存、重新打开后的滚动位置恢复。
- 改写 `SourceScrollAnchor` 的映射算法、HTML `data-source-*` 范围或 JavaScript bridge。
- 改变大纲、查找、PDF、Quick Look、主题、缩放或渲染调度功能。
- 重构既有 `scrollToSourceLineRequest` 的 `asyncAfter` 清理机制；本任务只保证模式切换不再生产或依赖该请求。

## 三、实施任务

### Task 1：先锁定“模式切换不发布旧行号请求”的状态合同（RED → GREEN）

**Files:**

- Modify: `Tests/MarkdownReaderTests/SourcePositionSyncTests.swift`
- Modify: `Sources/MarkdownReader/ViewModels/DocumentViewModel.swift`

**Step 1: 写失败测试**

替换当前会固化错误行为的两项测试：

- `testRawToRenderedRequestsVisibleRawSourceLine`
- `testRenderedToRawRequestsVisibleRenderedSourceLine`

改为以下合同：

```swift
@MainActor
func testRawToRenderedModeSwitchDoesNotPublishLegacyLineRequest() {
    let viewModel = DocumentViewModel()
    viewModel.displayMode = .raw
    viewModel.rawVisibleSourceLine = SourceLine(oneBased: 18)

    viewModel.switchDisplayMode(.rendered)

    XCTAssertEqual(viewModel.displayMode, .rendered)
    XCTAssertNil(viewModel.scrollToSourceLineRequest)
}

@MainActor
func testRenderedToRawModeSwitchCancelsPendingLegacyLineRequest() {
    let viewModel = DocumentViewModel()
    viewModel.displayMode = .rendered
    viewModel.requestScroll(to: SourceLine(oneBased: 1))

    viewModel.switchDisplayMode(.raw)

    XCTAssertEqual(viewModel.displayMode, .raw)
    XCTAssertNil(viewModel.scrollToSourceLineRequest)
}
```

保留并补充一项显式跳转测试，证明本修复没有夺走大纲/查找的能力：直接调用 `requestScroll(to:)` 仍应保留传入的 1-based `SourceLine`，直到现有消费者清除。

**Step 2: 运行 RED**

Run: `swift test --filter SourcePositionSyncTests`

Expected: 上述两项失败，因为 `switchDisplayMode(_:)` 仍会把缓存的可见行写入 `scrollToSourceLineRequest`。

**Step 3: 写最小实现**

在 `DocumentViewModel.switchDisplayMode(_:)` 中：

1. 保留纯文本模式保护、`displayMode` 更新和 `displayModeCache` 更新。
2. 删除 Raw → Rendered 与 Rendered → Raw 分支中的 `requestScroll(...)` 调用；模式切换不再读取 `rawVisibleSourceLine` 或 `renderedVisibleSourceLine`。
3. 在真实模式发生变化时调用 `clearScrollRequest()`，取消先前大纲/查找留下、尚未清除的旧行号请求。
4. 更新方法与属性注释：`scrollToSourceLineRequest` 不再描述为“模式切换共用”，明确它仅服务显式按行跳转。

不要删除 `rawVisibleSourceLine` / `renderedVisibleSourceLine` 本身，也不要在本任务中更改 WebView 的被动滚动报告；它们可能仍被大纲高亮等既有逻辑使用。

**Step 4: 运行 GREEN**

Run: `swift test --filter SourcePositionSyncTests`

Expected: 新的模式切换合同通过；`SourceLine`、`ScrollTransfer`、锚点映射和显式跳转既有测试继续通过。

### Task 2：统一分段控件、菜单和快捷键的模式切换入口（RED → GREEN）

**Files:**

- Modify: `Sources/MarkdownReader/ViewModels/WindowCommandTarget.swift`
- Modify: `Sources/MarkdownReader/Views/DetailView.swift`
- Modify: `Tests/MarkdownReaderTests/WindowCommandTargetTests.swift`

**Step 1: 写失败测试**

在 `WindowCommandTargetTests` 添加一个可观察的 handler 测试：

```swift
func testDisplayModeCommandUsesRegisteredViewHandler() {
    let coordinator = WindowCoordinator()
    let session = makeSession(coordinator: coordinator)
    let target = WindowCommandTarget(session: session)
    var received: DisplayMode?
    target.displayModeSwitchHandler = { received = $0 }

    target.perform(.switchDisplayMode(.raw))

    XCTAssertEqual(received, .raw)
    XCTAssertNotEqual(session.documentViewModel.displayMode, .raw)
}
```

另加一项无 handler 的安全回退测试：它可直接改变模式，但不能发布 `scrollToSourceLineRequest`（Task 1 的新合同必须同样成立）。

**Step 2: 运行 RED**

Run: `swift test --filter WindowCommandTargetTests`

Expected: 因缺少 `displayModeSwitchHandler` 而编译失败；或现有实现直接修改 ViewModel，导致 handler 断言失败。

**Step 3: 写最小实现**

1. 在 `WindowCommandTarget` 增加 `displayModeSwitchHandler: ((DisplayMode) -> Void)?`，含注释说明这是需要视图级采样上下文的命令。
2. 处理 `.switchDisplayMode(mode)` 时，若 handler 已注册则只调用 handler；若 handler 为 `nil`，保留直接调用 `session.documentViewModel.switchDisplayMode(mode)` 的安全回退。回退仍受 Task 1 约束，绝不能生成旧行号请求。
3. 在 `DetailView.registerCommandHandlers()` 将该 handler 注册为 `handleDisplayModeSwitch`；在 `onDisappear` 清空它，与 find/reload/export handler 的生命周期一致。
4. `handleDisplayModeSwitch` 保持现有 token、`pendingModeSwitch`、Raw/Rendered 主动 capture 和 `ScrollTransfer` 流程；它调用的 `switchDisplayMode` 已不再创建旧行号请求。
5. 不要让菜单调用 `Picker` binding，也不要把采样/token 逻辑移入 `WindowCommandTarget`；该类没有 WebView/NSTextView 的视图上下文。

**Step 4: 运行 GREEN**

Run: `swift test --filter WindowCommandTargetTests`

Expected: 已注册 handler 时菜单命令进入 `DetailView` 管线；无 handler 回退不泄漏旧行号请求。

### Task 3：验证交接完成后不会被旧请求覆盖（回归测试与代码审阅）

**Files:**

- Modify: `Tests/MarkdownReaderTests/SourcePositionSyncTests.swift`
- Review: `Sources/MarkdownReader/Views/DetailView.swift:687-744`
- Review: `Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift:718-739`

**Step 1: 写失败的状态顺序测试**

在 `SourcePositionSyncTests` 增加以 ViewModel 状态为边界的测试：先建立一个显式旧请求，再模拟 Rendered → Raw 模式切换和 `beginScrollTransfer`，断言旧请求已清除、交接仍存在，且正确 `.raw` 回执后交接被清除：

```swift
@MainActor
func testRenderedToRawTransferHasNoLegacyRequestToReplayAfterAcknowledgement() {
    let viewModel = DocumentViewModel()
    viewModel.displayMode = .rendered
    viewModel.requestScroll(to: .first)

    viewModel.switchDisplayMode(.raw)
    let transfer = viewModel.beginScrollTransfer(
        destination: .raw,
        anchor: SourceScrollAnchor(sourcePosition: 42.4, documentProgress: 0.58)
    )

    XCTAssertNil(viewModel.scrollToSourceLineRequest)
    XCTAssertEqual(viewModel.scrollTransfer?.id, transfer.id)

    viewModel.acknowledgeScrollTransfer(
        id: transfer.id,
        destination: .raw,
        contentVersion: transfer.contentVersion
    )
    XCTAssertNil(viewModel.scrollTransfer)
    XCTAssertNil(viewModel.scrollToSourceLineRequest)
}
```

**Step 2: 运行 RED / GREEN**

Run: `swift test --filter SourcePositionSyncTests/testRenderedToRawTransferHasNoLegacyRequestToReplayAfterAcknowledgement`

Expected before Task 1: FAIL（旧请求仍为 `.first`）。完成 Task 1 后: PASS。

**Step 3: 代码审阅门槛**

逐项确认：

- `DetailView.handleDisplayModeSwitch` 仍只从主动 capture 回调调用 `beginScrollTransfer`；
- `SyntaxHighlightedEditor` 的旧 `scrollToSourceLine` 分支不会在正常模式切换中收到值；
- `ScrollTransfer.destination == .raw` 的应用及回执顺序未改变；
- `scrollToSourceLineRequest` 的两处既有 `asyncAfter` 只会由大纲/查找的显式请求触发，不作为模式切换完成条件。

禁止通过延长 0.5 秒/2.5 秒延迟、增加新的 sleep，或在锚点应用后再补一次按行滚动来“修复”。

### Task 4：完整验证与人工 GUI 验收

**Files:**

- Verify only: 工作区差异与下列实现涉及文件。

**Step 1: 自动验证**

Run:

```bash
swift test
swift build
swift build -c release
git diff --check
```

Expected: 全部成功；`git diff --check` 无输出。

**Step 2: 人工 GUI 验收**

Run:

```bash
swift run MarkdownReader
```

使用包含长段落、列表、表格、围栏代码块和多个标题的 Markdown，在窗口中部验证：

1. Rendered 滚到段落/代码块中部，立即切 Raw：源码显示同一内容附近，绝不回到第 1 行。
2. Rendered 滚动后等待不足 300ms 立刻切 Raw：仍以主动 capture 的位置为准，不能取旧的 `.first` 缓存。
3. Raw 滚到中部切 Rendered：仍定位同一内容附近，且没有空白闪现回归。
4. 用分段控件、菜单项与快捷键各完成一次 Rendered → Raw 和 Raw → Rendered；三种入口结果一致。
5. 大纲跳转、查找上一个/下一个在各自正常模式仍能按行跳转。
6. 连续快速切换 10 次，且在一次 Rendered capture 尚未返回时再次切换：最终只服从最后一次选择，不出现旧位置反跳。
7. 修改 Raw 内容后首次切 Rendered：新内容立即正确显示，位置交接有效且无空白闪现。

**Step 3: 记录验收结果**

在交付说明中逐项写明自动测试结果与 7 项 GUI 结果；任何一项 GUI 未通过时，状态应是“未完成”，不得以 XCTest 通过代替。

## 四、回滚边界

若发现大纲/查找的显式跳转回归，只回滚本任务对“模式切换不产生 legacy request”与命令路由的改动；不要回滚既有 `SourceScrollAnchor`、JavaScript bridge、`ScrollTransfer` 或防空白过渡实现。先复现是哪一种显式跳转请求未被消费，再单独修复其请求生命周期。

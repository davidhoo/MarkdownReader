# MarkdownReader 显式滚动请求取消与单消费者修复 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** 修复“大纲导航后从 Rendered 切 Raw，先正确落位再跳回错误位置”的竞态，确保已取消的显式按行滚动请求绝不会覆盖模式切换的 `SourceScrollAnchor` 交接。

**Architecture:** `DocumentViewModel.SourceScrollRequest` 已带 UUID；本任务让该 UUID真正成为可取消的执行令牌。显式按行跳转只能由当前可见模式消费：Raw 仅在 `isActive == true` 时调度，Rendered 仅在 `isRenderedMode == true` 时处理。两个目标端都必须在“调度”和“异步执行/加载完成”两个边界验证请求 ID 仍是 ViewModel 当前请求；模式切换清空请求后，所有已排队或暂存的旧动作自动失效。

**Tech Stack:** Swift 6、SwiftUI、AppKit (`NSTextView` / `NSScrollView`)、WebPage/WebKit JavaScript bridge、XCTest、Swift Package Manager。

---

## 一、已确认根因

大纲点击发布 `.outlineTop` 的 `SourceScrollRequest`。当前 `SyntaxHighlightedEditor.updateNSView` 在每一次更新中，只要请求仍非 nil 就执行：

```swift
DispatchQueue.main.async {
    self.scrollToLineInTextView(textView, request: request, content: textView.string)
}
```

这个闭包捕获旧 request，却没有在执行前验证它是否仍有效；也没有记录该 request 是否已经调度过。Rendered 平滑大纲滚动会产生多个 SwiftUI 更新，因此同一大纲请求可能向隐藏 Raw 编辑器排入多个旧闭包。

切换 Rendered → Raw 时，`DocumentViewModel.switchDisplayMode(_:)` 会将 `scrollToSourceLineRequest` 清空，但无法撤回已排队的闭包。随后新的 `ScrollTransfer` 正确应用源码锚点，所以用户先看到正确位置；最后一个旧 Raw 闭包运行，把编辑器拉回大纲标题，造成“先对、后错”。

WebView 也有相同类别的风险：页面加载中会把请求保存到 `pendingScrollToSourceLine`，当前对请求变 nil 的处理没有清空该 pending 状态，加载结束后可能在隐藏 Rendered 视图执行旧定位。

## 二、固定合同与范围

### 固定合同

| 请求类别 | 可消费者 | 取消条件 | 旧动作结果 |
|---|---|---|---|
| `.outlineTop` / `.reveal` 显式按行跳转 | 当前可见的 Raw 或 Rendered，不能是隐藏视图 | ViewModel 请求变 nil、UUID 改变、模式不再匹配 | 丢弃，不滚动、不报告可见行 |
| `ScrollTransfer` 模式切换交接 | transfer 的 `destination` 视图 | 既有 token / id / contentVersion 不匹配 | 保持现有丢弃逻辑 |

- 每个显式请求 UUID 在一个视图端最多调度一次；无关 SwiftUI 更新不得重复创建滚动动画。
- 执行已调度的 Raw 闭包前，必须再次验证：当前 Raw 是活跃模式，且 `parent.scrollToSourceLineRequest?.id == capturedRequest.id`。
- Rendered 在请求清空、离开 Rendered 模式或页面加载结束时，也必须用同一 UUID 验证并清理 `pendingScrollToSourceLine`。
- 模式切换优先级高于大纲/查找：一旦开始切换，旧显式请求不得改变交接完成后的滚动位置。
- 不改变 `.outlineTop` 的 12pt 顶部落点、`.reveal` 的既有查找落点、`SourceScrollAnchor` 算法或 `ScrollTransfer` 回执协议。

### 包含

- Raw 显式请求的单次调度、执行前取消验证。
- WebView 显式请求 pending 的取消与模式可见性验证。
- 覆盖“大纲请求已排队 → Rendered → Raw 切换 → 锚点落位”的回归测试。
- 自动验证与人工 GUI 矩阵。

### 不包含

- 更改大纲顶部对齐、查找定位、模式切换位置映射、分栏编辑或滚动持久化。
- 改动 `SourceScrollRequest` 的字段、`SourceLine` 的 1-based 协议、HTML `data-line` 或 JavaScript 落点算法。
- 用延迟、sleep、延长 0.5 秒 / 2.5 秒清理时间，或额外一次滚动来掩盖竞态。
- 改动 Raw 光标、选区、Undo、语法高亮或 Rendered 防空白过渡。

## 三、实施任务

### Task 1：先为请求生命周期建立可测试的取消策略（RED → GREEN）

**Files:**

- Modify: `Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift`
- Modify: `Tests/MarkdownReaderTests/SyntaxHighlightedEditorScrollTests.swift`

**Step 1: 写失败测试**

在 `SyntaxHighlightedEditorScrollTests` 中，为一个不依赖 AppKit 的内部 helper（建议 `ExplicitScrollRequestExecutionPolicy`）添加下列测试。该 helper 的职责仅是决定是否调度与是否仍可执行，避免用真实主队列时序写脆弱测试。

```swift
func testExplicitRequestSchedulesOnlyOnceForSameID() {
    let id = UUID()

    XCTAssertTrue(ExplicitScrollRequestExecutionPolicy.shouldSchedule(
        requestID: id,
        lastScheduledRequestID: nil
    ))
    XCTAssertFalse(ExplicitScrollRequestExecutionPolicy.shouldSchedule(
        requestID: id,
        lastScheduledRequestID: id
    ))
}

func testCancelledExplicitRequestCannotExecuteAfterModeSwitch() {
    let request = DocumentViewModel.SourceScrollRequest(
        id: UUID(),
        sourceLine: SourceLine(oneBased: 42),
        placement: .outlineTop
    )

    XCTAssertFalse(ExplicitScrollRequestExecutionPolicy.shouldExecute(
        capturedRequestID: request.id,
        currentRequest: nil,
        isDestinationActive: true
    ))
}

func testReplacedOrInactiveExplicitRequestCannotExecute() {
    let old = DocumentViewModel.SourceScrollRequest(
        id: UUID(), sourceLine: SourceLine(oneBased: 42), placement: .outlineTop
    )
    let replacement = DocumentViewModel.SourceScrollRequest(
        id: UUID(), sourceLine: SourceLine(oneBased: 57), placement: .outlineTop
    )

    XCTAssertFalse(ExplicitScrollRequestExecutionPolicy.shouldExecute(
        capturedRequestID: old.id, currentRequest: replacement, isDestinationActive: true
    ))
    XCTAssertFalse(ExplicitScrollRequestExecutionPolicy.shouldExecute(
        capturedRequestID: old.id, currentRequest: old, isDestinationActive: false
    ))
}
```

再加入一个正向测试：请求 ID 相同且 destination active 时返回 `true`。

**Step 2: 运行 RED**

Run: `swift test --filter SyntaxHighlightedEditorScrollTests`

Expected: 因缺少 `ExplicitScrollRequestExecutionPolicy` 而编译失败。

**Step 3: 写最小实现**

在 `SyntaxHighlightedEditor.swift`、靠近 `SourceLineNavigationGeometry` 的纯 helper 区增加：

```swift
enum ExplicitScrollRequestExecutionPolicy {
    static func shouldSchedule(
        requestID: UUID,
        lastScheduledRequestID: UUID?
    ) -> Bool {
        requestID != lastScheduledRequestID
    }

    static func shouldExecute(
        capturedRequestID: UUID,
        currentRequest: DocumentViewModel.SourceScrollRequest?,
        isDestinationActive: Bool
    ) -> Bool {
        isDestinationActive && currentRequest?.id == capturedRequestID
    }
}
```

此 helper 不触碰 `ScrollTransfer`，不保存可变全局状态，也不承载 AppKit 调用。

**Step 4: 运行 GREEN**

Run: `swift test --filter SyntaxHighlightedEditorScrollTests`

Expected: 新的策略测试通过；既有编辑器底部滚动和大纲顶部落点测试继续通过。

### Task 2：Raw 仅消费活跃请求，并使已排队闭包可取消（RED → GREEN）

**Files:**

- Modify: `Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift:638-780,859-900`
- Modify: `Tests/MarkdownReaderTests/SyntaxHighlightedEditorScrollTests.swift`

**Step 1: 写失败的协调器状态测试**

在 `SyntaxHighlightedEditorScrollTests` 增加最小状态序列测试：

1. 建立 `.outlineTop` request；
2. 模拟它已被 Raw 调度；
3. 调用 `clearScrollRequest()`（等价于真实模式变化）；
4. 断言 Task 1 的执行策略拒绝该已捕获 UUID；
5. 以同一 request ID 再次检查 `shouldSchedule`，断言不会重复调度。

测试必须明确说明：这是“已排队、尚未执行的闭包”场景，而不是只断言 ViewModel 当前请求为 nil。

**Step 2: 运行 RED**

Run: `swift test --filter SyntaxHighlightedEditorScrollTests`

Expected: 当前实现没有 coordinator 的 request ID 状态，且 async 闭包无执行前验证，测试或编译失败。

**Step 3: 写最小实现**

1. 在 `SyntaxHighlightedEditor.Coordinator` 增加 `lastScheduledExplicitScrollRequestID: UUID?`。
2. `updateNSView` 的显式按行请求分支改为仅在 `isActive == true` 时考虑 request；隐藏 Raw 不得调度或执行大纲/查找滚动。
3. 收到非 nil request 时，只有 `ExplicitScrollRequestExecutionPolicy.shouldSchedule` 返回 true 才记录 ID 并排入 `DispatchQueue.main.async`。
4. 异步闭包中、调用 `scrollToLineInTextView` 前再次读取 coordinator 最新的 `parent`，并用：

```swift
guard ExplicitScrollRequestExecutionPolicy.shouldExecute(
    capturedRequestID: request.id,
    currentRequest: coordinator.parent.scrollToSourceLineRequest,
    isDestinationActive: coordinator.parent.isActive
) else { return }
```

验证失败时不得调用 `scrollToLineInTextView`，也不得调用 `reportVisibleSourceLineOnce()`。
5. 当当前请求为 nil 时将 `lastScheduledExplicitScrollRequestID` 置为 nil，使下一次新的 UUID 请求可正常处理。不得以 `sourceLine` 判断重复，连续点击同一标题必须仍可执行。
6. `scrollTransfer.destination == .raw` 分支和 `rawCaptureRequest` 分支保持原顺序与逻辑不变。

**Step 4: 运行 GREEN**

Run: `swift test --filter SyntaxHighlightedEditorScrollTests`

Expected: 同一请求不重复排队；切换后已捕获的旧请求不能执行；真实 AppKit 的 `.outlineTop`、`.reveal`、选区与文末钳制测试全部通过。

### Task 3：Rendered pending 请求也遵守可见性与取消令牌（RED → GREEN）

**Files:**

- Modify: `Sources/MarkdownReader/Views/WebViewMarkdownView.swift:132-140,233-241,295-309,498-505,563-568,831-880`
- Modify: `Tests/MarkdownReaderTests/SourcePositionSyncTests.swift`

**Step 1: 写失败测试**

在 `SourcePositionSyncTests` 为一个纯 helper（建议 `RenderedExplicitScrollRequestPolicy`）建立与 Raw 对称的状态合同：

```swift
@MainActor
func testRenderedPendingRequestIsDiscardedAfterCancellation() {
    let request = DocumentViewModel.SourceScrollRequest(
        id: UUID(), sourceLine: SourceLine(oneBased: 42), placement: .outlineTop
    )

    XCTAssertFalse(RenderedExplicitScrollRequestPolicy.shouldApplyPending(
        pendingRequest: request,
        currentRequest: nil,
        isRenderedMode: true,
        isLoading: false
    ))
}

@MainActor
func testRenderedPendingRequestRequiresCurrentRequestAndRenderedMode() {
    let request = DocumentViewModel.SourceScrollRequest(
        id: UUID(), sourceLine: SourceLine(oneBased: 42), placement: .outlineTop
    )

    XCTAssertTrue(RenderedExplicitScrollRequestPolicy.shouldApplyPending(
        pendingRequest: request,
        currentRequest: request,
        isRenderedMode: true,
        isLoading: false
    ))
    XCTAssertFalse(RenderedExplicitScrollRequestPolicy.shouldApplyPending(
        pendingRequest: request,
        currentRequest: request,
        isRenderedMode: false,
        isLoading: false
    ))
}
```

**Step 2: 运行 RED**

Run: `swift test --filter SourcePositionSyncTests`

Expected: 因缺少 pending 决策 helper 而编译失败。

**Step 3: 写最小实现**

1. 在 `WebViewMarkdownView.swift` 增加纯 `RenderedExplicitScrollRequestPolicy`；它只在 pending ID 与当前请求 ID 相同、`isRenderedMode == true` 且页面不加载时允许执行。
2. `handleScrollToLineChange(nil)` 必须清空 `pendingScrollToSourceLine`；当 `isRenderedMode == false` 时也不得新建 pending 或直接执行 JavaScript。
3. 在 `handleLoadingChange` 消费 pending 前，调用该策略；无效时先清空 pending，再不执行 `scrollToLineRequest`。
4. `applyLatestRender` 中仅当当前是 Rendered 模式、请求仍存在时创建 pending；其 0.8 秒兜底清理只能清除相同 UUID 的 pending，不能恢复或执行已经取消的请求。
5. `scrollToLineRequest` 入口前再保留一次可见模式/id 防御性验证；JavaScript 参数构造和 `.outlineTop` / `.reveal` 落点算法不改。
6. 进入或离开 Rendered 模式时，如有与当前模式不兼容的 pending request，立即清除。不得以 WebView 是否仍常驻为由在隐藏状态执行滚动。

**Step 4: 运行 GREEN**

Run: `swift test --filter SourcePositionSyncTests`

Expected: pending 请求在取消、模式变化或替换时被丢弃；原有 `RenderedLineNavigationBridge`、源码锚点和模式切换测试继续通过。

### Task 4：端到端回归验证

**Files:**

- Verify only: 本任务涉及的源文件、测试和工作区差异。

**Step 1: 自动验证**

Run:

```bash
swift test --filter SyntaxHighlightedEditorScrollTests
swift test --filter SourcePositionSyncTests
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

用包含至少 6 个中段标题、长段落和围栏代码块的 Markdown 验收：

1. Rendered 点击一个中段大纲标题，随后立刻切 Raw：先到正确位置后，静置至少 1 秒也不得再次跳动。
2. 重复第 1 项，但在 Rendered 大纲平滑动画尚未结束时切 Raw：最终只保留主动采样的锚点位置，不跳回标题旧位置。
3. Raw 点击大纲标题后切 Rendered：位置交接正常，无空白闪现，也无二次跳动。
4. 在 Raw 和 Rendered 各连续点击同一标题两次、再点击另一标题：每次可见模式都响应，最终只停在最后一次选择。
5. 在 Raw/Rendered 各使用查找上一个/下一个，再切模式：查找定位保留既有 `.reveal` 体验，旧请求不能在交接后反跳。
6. Rendered 页面加载或修改内容后立刻点击大纲、再切 Raw：无隐藏 WebView 的延迟旧定位。
7. 连续快速切换 10 次，且其中一次前先点大纲：最终只服从最后一次模式选择与最后一次可见位置。
8. 不使用大纲/查找时，Raw ↔ Rendered 既有同步仍正常，且 Raw → Rendered 无空白闪现。

**Step 3: 交付记录**

交付说明逐项列出自动验证与 8 项 GUI 结果。任何一项 GUI 未通过时均为未完成；不得以 ViewModel 状态测试或构建成功替代实际异步 UI 验收。

## 四、回滚边界

若本任务造成显式大纲或查找完全不响应，只回滚“单消费者 / UUID 取消验证”相关代码；不要回滚已验证的 `.outlineTop` 落点、`SourceScrollRequest` 模型、`SourceScrollAnchor` 或 `ScrollTransfer`。先判断是哪一个请求在当前可见模式下被错误拒绝，再针对该可见性或 UUID 判定修复。

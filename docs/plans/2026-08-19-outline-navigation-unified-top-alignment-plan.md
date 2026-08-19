# MarkdownReader 大纲导航统一顶部对齐 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** 让 Raw 与 Rendered 的大纲点击都将目标标题稳定定位在视口顶部下方约 12pt，而不是 Raw 约 1/3、Rendered 居中。

**Architecture:** 明确区分“导航到大纲标题”和“查找结果定位”两种显式源码行请求。大纲请求携带 `.outlineTop` 落点策略，Raw 与 Rendered 分别按同一个 12pt 视觉顶部边距定位；查找保留原有的 Raw 约 1/3 与 Rendered 居中行为。Raw ↔ Rendered 模式切换继续仅使用 `SourceScrollAnchor` / `ScrollTransfer`，与本任务完全隔离。

**Tech Stack:** Swift 6、SwiftUI、AppKit (`NSTextView` / `NSScrollView`)、WebPage/WebKit JavaScript bridge、XCTest、Swift Package Manager。

---

## 一、交互依据与固定合同

参考 `markdown-preview`：大纲点击是“导航”，将标题滚到视口顶部下方一个很小的固定边距；模式切换是“位置交接”，恢复视口顶部锚点且不重新居中。两类操作不应共享落点策略。

当前 MarkdownReader 的大纲点击调用 `requestScroll(to: item.sourceLine)`：

- Raw 先 `scrollRangeToVisible`，再将目标行放到视口约 1/3；
- Rendered 调用 `MR.scrollToLine`，用 `scrollIntoView(... block: 'center')` 居中。

它们视觉重心不同，用户点击相同标题会产生明显跳变；更重要的是，这个行号请求还被查找使用，直接修改现有函数会意外改变查找行为。

本任务固定如下合同：

| 触发来源 | 请求意图 | Raw 落点 | Rendered 落点 |
|---|---|---|---|
| 大纲点击 | `.outlineTop` | 标题源码行距视口顶约 12pt | 对应渲染标题距视口顶约 12pt |
| 查找上一个/下一个、其他既有显式定位 | `.reveal` | 保持现有约 1/3 位置 | 保持现有居中位置 |
| Raw ↔ Rendered 模式切换 | `ScrollTransfer` | 源码锚点视口顶部交接 | 源码锚点视口顶部交接 |

- “12pt”是正常文档中目标标题 glyph / DOM 元素顶部距可视区域顶部的视觉边距；文档开头、末尾受可滚动范围钳制是正确行为。
- 大纲定位保留平滑动画，Raw 与 Rendered 动画时长统一为 0.25 秒、`easeOut`。
- Rendered 使用当前 `zoomLevel` 将 12pt 转成 CSS 像素后传入 JavaScript，避免缩放时边距随网页缩放被放大或缩小。
- 每一次大纲点击都必须带新请求身份；连续点击同一个标题也必须重新触发定位。
- 不移动 Raw 的光标/选区，不改动 `SourceScrollAnchor`、`ScrollTransfer`、渲染防空白过渡或旧请求的清理时机。

## 二、范围

### 包含

- 为显式按源码行跳转增加最小的“落点策略”与请求身份。
- 仅大纲点击在 Raw / Rendered 使用统一顶部边距。
- 修正 Rendered 最近 `data-line` 兜底分支中不可重新赋值的 JavaScript `let` 变量。
- 单元测试、真实 AppKit 布局测试、构建和人工 GUI 验收。

### 不包含

- 修改查找、模式切换、分栏编辑、持续双向滚动、滚动位置持久化或渲染缓存。
- 将大纲点击改为影响光标、选区或编辑焦点。
- 更改标题解析、`data-line` / `data-source-*` HTML 协议、WebView 渲染调度、主题或内容 padding。
- 用额外 `sleep`、延长现有 0.5 秒 / 2.5 秒清理延迟来掩盖定位问题。

## 三、实施任务

### Task 1：把显式行号请求的“意图”和身份建模（RED → GREEN）

**Files:**

- Modify: `Sources/MarkdownReader/ViewModels/DocumentViewModel.swift`
- Modify: `Tests/MarkdownReaderTests/SourcePositionSyncTests.swift`

**Step 1: 写失败测试**

在 `SourcePositionSyncTests` 增加请求模型合同。名称可按项目风格微调，但语义必须等价：

```swift
@MainActor
func testOutlineScrollRequestCarriesTopAlignment() {
    let viewModel = DocumentViewModel()

    viewModel.requestOutlineScroll(to: SourceLine(oneBased: 24))

    XCTAssertEqual(viewModel.scrollToSourceLineRequest?.sourceLine.oneBased, 24)
    XCTAssertEqual(viewModel.scrollToSourceLineRequest?.placement, .outlineTop)
}

@MainActor
func testFindScrollRequestKeepsRevealPlacement() {
    let viewModel = DocumentViewModel()

    viewModel.requestScroll(to: SourceLine(oneBased: 24))

    XCTAssertEqual(viewModel.scrollToSourceLineRequest?.placement, .reveal)
}

@MainActor
func testRepeatedOutlineSelectionGetsNewRequestIdentity() {
    let viewModel = DocumentViewModel()
    viewModel.requestOutlineScroll(to: SourceLine(oneBased: 24))
    let firstID = try! XCTUnwrap(viewModel.scrollToSourceLineRequest?.id)

    viewModel.requestOutlineScroll(to: SourceLine(oneBased: 24))

    XCTAssertNotEqual(viewModel.scrollToSourceLineRequest?.id, firstID)
}
```

将现有直接读取 `scrollToSourceLineRequest?.oneBased` 的断言更新为 `.sourceLine.oneBased`；不要修改 `SourceLine` 的 1-based 合同。

**Step 2: 运行 RED**

Run: `swift test --filter SourcePositionSyncTests`

Expected: 因缺少请求类型、`.outlineTop` 和 `requestOutlineScroll(to:)` 而编译失败。

**Step 3: 写最小实现**

1. 在 `DocumentViewModel.swift` 的显式跳转区新增内部可测试的值类型，例如：

```swift
enum SourceScrollPlacement: Equatable, Sendable {
    case reveal
    case outlineTop
}

struct SourceScrollRequest: Equatable, Sendable {
    let id: UUID
    let sourceLine: SourceLine
    let placement: SourceScrollPlacement
}
```

2. 将 `scrollToSourceLineRequest` 改为 `SourceScrollRequest?`。
3. 保留现有 `requestScroll(to:)` 名称与调用方；它创建 `.reveal` 请求和新的 UUID。
4. 新增 `requestOutlineScroll(to:)`；它创建 `.outlineTop` 请求和新的 UUID。
5. `clearScrollRequest()` 仍只清空当前请求。`switchDisplayMode(_:)` 继续清空遗留显式请求，且绝不创建此请求。
6. 更新属性与方法注释，明确这是大纲/查找等显式跳转模型，不是模式切换交接模型。

**Step 4: 运行 GREEN**

Run: `swift test --filter SourcePositionSyncTests`

Expected: 三项新合同通过；已有模式切换“不发布 legacy request”与 `ScrollTransfer` 测试继续通过。

### Task 2：让大纲点击发布 `.outlineTop` 请求（RED → GREEN）

**Files:**

- Modify: `Sources/MarkdownReader/Views/DetailView.swift:497-504`
- Modify: `Tests/MarkdownReaderTests/SourcePositionSyncTests.swift`

**Step 1: 写失败测试**

无需构造 SwiftUI `OutlineView`；用 Task 1 的 `DocumentViewModel.requestOutlineScroll` 合同作为大纲回调的可测试边界。补一项保护性测试，断言 `.reveal` 与 `.outlineTop` 同时具有同一 `SourceLine` 协议，避免把行号改回裸 `Int`。

**Step 2: 实现最小调用点改动**

将大纲的 `onSelect` 从：

```swift
documentViewModel.requestScroll(to: item.sourceLine)
```

改为：

```swift
documentViewModel.requestOutlineScroll(to: item.sourceLine)
```

查找、查找上一个/下一个和其他 `requestScroll(to:)` 调用保持不动。

**Step 3: 运行 GREEN**

Run: `swift test --filter SourcePositionSyncTests`

Expected: 大纲请求具有 `.outlineTop`，查找请求仍为 `.reveal`。

### Task 3：Raw 以统一 12pt 顶部边距定位大纲标题（RED → GREEN）

**Files:**

- Modify: `Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift:447-810`
- Modify: `Sources/MarkdownReader/Views/RawMarkdownView.swift`
- Modify: `Tests/MarkdownReaderTests/SyntaxHighlightedEditorScrollTests.swift`

**Step 1: 写失败的纯几何测试**

在 `SyntaxHighlightedEditorScrollTests` 为一个内部纯 helper（建议 `SourceLineNavigationGeometry`）写边界测试：

```swift
func testOutlineTopOriginUsesTwelvePointMargin() {
    let origin = SourceLineNavigationGeometry.origin(
        targetY: 500,
        placement: .outlineTop,
        topMargin: 12,
        viewportHeight: 120,
        documentHeight: 1_000,
        bottomInset: 0
    )
    XCTAssertEqual(origin, 488, accuracy: 0.001)
}

func testOutlineTopOriginClampsAtDocumentEnd() {
    let origin = SourceLineNavigationGeometry.origin(
        targetY: 980,
        placement: .outlineTop,
        topMargin: 12,
        viewportHeight: 120,
        documentHeight: 1_000,
        bottomInset: 8
    )
    XCTAssertEqual(origin, 888, accuracy: 0.001)
}
```

另测 `.reveal` 保持当前 `targetY - viewportHeight / 3` 的结果，防止查找体验被意外改成顶部对齐。

**Step 2: 运行 RED**

Run: `swift test --filter SyntaxHighlightedEditorScrollTests`

Expected: 因缺少 `SourceLineNavigationGeometry` 或 placement 输入而编译失败。

**Step 3: 写最小实现**

1. `RawMarkdownView` 和 `SyntaxHighlightedEditor` 的输入从 `SourceLine?` 改为 `SourceScrollRequest?`，只在请求变更时处理其 `sourceLine` 与 `placement`。
2. 将现有 `scrollToLineInTextView` 改为接收 `SourceScrollRequest` 或 `(SourceLine, SourceScrollPlacement)`。
3. 提取不依赖 AppKit 的 `SourceLineNavigationGeometry.origin(...)`：
   - `.outlineTop`：`targetY - 12`；
   - `.reveal`：保持 `targetY - viewportHeight / 3`；
   - 两者都用当前文档高度、`contentView.bounds.height` 与系统 bottom inset 进行钳制。
4. Raw 大纲跳转不要调用会改变选区的 API；可保留已有 `scrollRangeToVisible` 作为布局准备，但最终必须立即以 helper 计算出的 origin 覆盖它。
5. Raw 动画统一改为 0.25 秒、`.easeOut`；这一时长适用于现有显式按行请求，不要用于 `RawSourceScrollAnchor.apply`。
6. `onVisibleSourceLineChanged`、高亮、Undo、底部 overscroll 与模式切换交接逻辑不改。

**Step 4: 写并运行真实 AppKit 布局测试**

在同一测试文件用现有真实 `NSTextView` / `NSScrollView` fixture 验证：

1. 中段目标行的最终 clip bounds 使标题行位于视口顶部约 12pt；
2. 文首不会产生负 origin；
3. 文末受最大 origin 钳制；
4. 跳转前后 `selectedRange()` 完全相同。

Run: `swift test --filter SyntaxHighlightedEditorScrollTests`

Expected: 纯几何与真实布局测试通过。

### Task 4：Rendered 以同一顶部边距定位，并保留查找居中（RED → GREEN）

**Files:**

- Modify: `Sources/MarkdownReader/Views/WebViewMarkdownView.swift:233-241,563-567`
- Modify: `Sources/MarkdownReader/Resources/js/markdown-reader.js:19-39`
- Modify: `Tests/MarkdownReaderTests/SourcePositionSyncTests.swift`

**Step 1: 写失败的桥接请求合同测试**

在 Swift 侧抽出纯的 JavaScript 参数构造 helper（例如 `RenderedLineNavigationBridge.arguments(for:zoomLevel:)`），并测试：

```swift
func testRenderedOutlineBridgeUsesTopPlacementAndZoomAdjustedMargin() {
    let request = SourceScrollRequest(
        id: UUID(),
        sourceLine: SourceLine(oneBased: 24),
        placement: .outlineTop
    )

    let arguments = RenderedLineNavigationBridge.arguments(for: request, zoomLevel: 2)

    XCTAssertEqual(arguments.lineNumber, 24)
    XCTAssertEqual(arguments.placement, .outlineTop)
    XCTAssertEqual(arguments.topMarginCSSPixels, 6, accuracy: 0.001)
}
```

再断言 `.reveal` 不携带顶部边距，继续走原来的居中策略。

**Step 2: 运行 RED**

Run: `swift test --filter SourcePositionSyncTests`

Expected: 因缺少 bridge helper / 参数模型而编译失败。

**Step 3: 写最小实现**

1. `WebViewMarkdownView` 的 `scrollToSourceLine`、`pendingScrollToSourceLine` 和相关 handler 改为传递完整 `SourceScrollRequest`；加载结束后仍校验并消费同一请求。
2. 以当前 `zoomLevel` 将 12pt 换算为 `12 / max(zoomLevel, 0.001)` CSS 像素；通过纯 helper 生成安全的 `MR.scrollToLine(...)` 参数。
3. 把 JavaScript API 扩展为 `MR.scrollToLine(lineNumber, placement, topMarginCSSPixels)`：
   - `.outlineTop`：找到精确 `data-line` 或最近块后，计算元素绝对 top，调用 `window.scrollTo({ top: max(0, targetTop - topMarginCSSPixels), behavior: 'smooth' })`；
   - `.reveal`：保留现有 `scrollIntoView({ behavior: 'smooth', block: 'center' })`；
   - `data-line` 找不到时也必须遵守同一 placement。
4. 修复现有最近块兜底：`closest` 与最小距离是可变状态，必须使用 `let` / `const` 之外可重新赋值的声明，或使用无副作用的 `reduce`；不得在 fallback 分支抛 JavaScript `TypeError`。
5. 不修改 `MR.scrollToSourceScrollAnchor`、`MR.captureSourceScrollAnchor`、`MR.getTopVisibleLine` 或模式切换的 `ScrollTransfer` API。

**Step 4: 运行 GREEN**

Run: `swift test --filter SourcePositionSyncTests`

Expected: bridge 参数测试通过；现有源码范围、锚点与模式切换测试继续通过。

### Task 5：完整验证与人工 GUI 验收

**Files:**

- Verify only: 本任务涉及的源文件、测试和工作区差异。

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

用含多个中段标题、短文档最后一个标题、长围栏代码块和非 ASCII 文本的 Markdown 验收：

1. 在 Raw 点击中段大纲标题：标题源码行位于视口顶部下方约 12pt，不移动光标或选区。
2. 在 Rendered 点击同一标题：渲染标题位于视口顶部下方约 12pt，不再居中。
3. Raw 与 Rendered 分别点击同一个标题，视觉落点一致；只比较标题到视口顶部的边距，不比较两种排版的像素内容高度。
4. 点击文首标题不会越界；点击接近文末的标题平滑滚到可达到的最末位置。
5. 连续点击同一个标题两次、连续点击不同标题：每次都响应，最终只停在最后一次选择。
6. 查找上一个/下一个仍保持原有 Raw 约 1/3、Rendered 居中定位。
7. 完成大纲点击后再 Raw ↔ Rendered 切换：模式切换仍按当前视口源码锚点交接，无文首跳转、无空白闪现。
8. 将渲染文字缩放到 50%、100%、200% 后重复 Rendered 大纲点击：标题的**视觉**顶部边距仍约 12pt。

**Step 3: 交付记录**

交付说明逐项记录自动验证和 8 项 GUI 结果。任何 GUI 项未通过，都应报告为未完成，不得以 XCTest 或构建成功替代。

## 四、回滚边界

若查找定位或模式切换出现回归，只回滚本任务新增的 `SourceScrollPlacement` / `SourceScrollRequest` 传播与大纲顶部落点实现；保留已验证的 `SourceScrollAnchor`、`ScrollTransfer`、Rendered 防空白过渡和 `SourceLine` 的 1-based 协议。不要通过恢复 Raw 1/3 与 Rendered 居中差异来掩盖请求意图区分不完整的问题。

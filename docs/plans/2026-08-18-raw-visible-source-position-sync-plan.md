# MarkdownReader Raw 实际可见位置同步 Implementation Plan

> For Claude: REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 编辑模式手动滚动或通过大纲跳转后，首次切回渲染模式定位到编辑器当前实际可见的源码块。

**Architecture:** DocumentViewModel 增加 rawVisibleSourceLine，并在 Raw → Rendered 时使用它作为唯一锚点。SyntaxHighlightedEditor 监听活跃 NSScrollView 的实际滚动，读取 viewport 顶部的 UTF-16 字符偏移后转为现有 1-based SourceLine；不移动光标，不同步像素 Y 值。

**Tech Stack:** Swift 6、SwiftUI、AppKit、XCTest、Swift Package Manager。

---

## 根因与固定契约

当前 Raw → Rendered 读取 cursorSourceLine。它只在文本修改或光标选区变化时更新；用户仅滚动编辑器，或在 Raw 中点大纲导致滚动时，光标仍停在旧行，切回 Rendered 就回到旧位置。

| 切换方向 | 位置来源 | 含义 |
|---|---|---|
| Rendered → Raw | renderedVisibleSourceLine | Rendered viewport 顶部的源码行，保持既有逻辑 |
| Raw → Rendered | rawVisibleSourceLine | Raw viewport 顶部的源码行，本任务新增 |

- 所有跨层位置继续使用 1-based SourceLine，不传裸 Int。
- 锚点代表同一源码块进入视口，不要求 Raw / Rendered 的像素 Y 相等。
- 仅活跃 Raw 编辑器可以写回 rawVisibleSourceLine；隐藏的常驻 Raw 视图不得覆盖 Rendered 状态。

## 范围

### 包含

- 监听 Raw 编辑器实际滚动并计算可见源码行。
- Raw → Rendered 改用 Raw 可见行。
- Raw 中大纲/查找跳转后再切模式的回归覆盖。
- TDD、AppKit 测试、完整构建和 GUI 验收。

### 不包含

- 已验证的问题 1：WebView 常驻、渲染完成 ACK、切换空白处理。
- WebView 的滚动监听、HTML/CSS、渲染策略、缩放、PDF、Quick Look。
- 为同步而移动光标或选区。
- 文件重开后的滚动持久化、像素位置持久化。
- bottomOverscroll、语法高亮恢复和编辑器末尾滚动抖动修复。

## 实施任务

### Task 1：先锁定 ViewModel 契约（RED）

**Files:**

- Modify: Tests/MarkdownReaderTests/SourcePositionSyncTests.swift
- Verify: Sources/MarkdownReader/ViewModels/DocumentViewModel.swift:94-101,317-335

**Step 1: 写失败测试**

将现有 testRawToRenderedRequestsCursorSourceLine 替换为：

~~~swift
@MainActor
func testRawToRenderedRequestsVisibleRawSourceLine() {
    let viewModel = DocumentViewModel()
    viewModel.displayMode = .raw
    viewModel.rawVisibleSourceLine = SourceLine(oneBased: 18)

    viewModel.switchDisplayMode(.rendered)

    XCTAssertEqual(viewModel.scrollToSourceLineRequest?.oneBased, 18)
}
~~~

再加一例：可见行是 18、光标行是 3 时，请求仍必须为 18。该测试证明视口而非插入点是同步来源。

**Step 2: 运行 RED**

Run: swift test --filter SourcePositionSyncTests

Expected: 因 rawVisibleSourceLine 不存在或仍读取 cursorSourceLine 而失败。

### Task 2：提取 UTF-16 可见行转换（RED → GREEN）

**Files:**

- Modify: Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift
- Modify: Tests/MarkdownReaderTests/SourcePositionSyncTests.swift

**Step 1: 写失败测试**

为新的纯 helper RawVisibleSourceLine.sourceLine(in:utf16CharacterOffset:) 写测试：

~~~swift
func testRawVisibleSourceLineUsesTopVisibleUTF16Offset() {
    let content = "a\n𝄞\nthird"

    XCTAssertEqual(
        RawVisibleSourceLine.sourceLine(in: content, utf16CharacterOffset: 2)?.oneBased,
        2
    )
}
~~~

另测空内容、偏移 0、超出 (content as NSString).length 的偏移；超出时钳制至最后可定位行，不能产生无效 SourceLine。

**Step 2: 运行 RED**

Run: swift test --filter SourcePositionSyncTests

Expected: 缺少 RawVisibleSourceLine。

**Step 3: 写最小实现**

在 RawSourceLineOffset 附近新增纯 helper：以 NSString 的 UTF-16 长度钳制偏移，取前缀中的换行数并构造 1-based SourceLine。该 helper 不得访问 AppKit 对象、滚动视图或选区。

**Step 4: 运行 GREEN**

Run: swift test --filter SourcePositionSyncTests

Expected: 新旧 SourceLine / UTF-16 测试通过。

### Task 3：报告活跃 Raw 编辑器的实际滚动位置（RED → GREEN）

**Files:**

- Modify: Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift:300-800
- Modify: Sources/MarkdownReader/Views/RawMarkdownView.swift:6-37
- Modify: Sources/MarkdownReader/Views/DetailView.swift:659-692
- Test: Tests/MarkdownReaderTests/SourcePositionSyncTests.swift

**Step 1: 写失败的 AppKit 测试**

创建最小 NSScrollView / NSTextView fixture，填入至少 50 行文本，把视口滚到中部，读取待实现的可见行。断言结果是中部行而不是第 1 行，并断言 selectedRange() 在读取前后完全相同。

Run: swift test --filter SourcePositionSyncTests

Expected: 当前没有可见行读取入口或滚动观察，测试失败。

**Step 2: 增加回调链**

1. SyntaxHighlightedEditor 新增 onVisibleSourceLineChanged: ((SourceLine) -> Void)?。
2. RawMarkdownView 直接透传该回调。
3. DetailView 将回调写入 documentViewModel.rawVisibleSourceLine。
4. 删除只服务模式切换的 onCursorSourceLineChanged / cursorSourceLine 路径，避免两种含义再次混用。

回调只能报告状态，禁止调用 requestScroll(to:) 造成滚动回环。

**Step 3: 观察和计算滚动位置**

在 SyntaxHighlightedEditor.Coordinator：

1. 设置 scrollView.contentView.postsBoundsChangedNotifications = true。
2. 注册 NSView.boundsDidChangeNotification；保存 observer token，并在 coordinator deinit 移除。
3. 收到通知后以约 100ms DispatchWorkItem 防抖。
4. 仅 parent.isActive == true 时回调。
5. 用 contentView.bounds.origin 减去 textContainerOrigin，通过 NSLayoutManager.glyphIndex(for:in:) 与 characterIndexForGlyph(at:) 得到顶部 UTF-16 偏移，再交给 Task 2 helper。

缺少 layout / text container 时不猜测行号，等待下一次通知。不得触碰 setSelectedRange。

**Step 4: 覆盖 Raw 内程序化跳转**

scrollToLineInTextView 动画结束后用同一读取路径报告一次可见行。这保证 Raw 中点大纲或查找跳转后，即使用户没有再次手动滚动，下一次切到 Rendered 仍使用新位置。

**Step 5: 运行 GREEN**

Run: swift test --filter SourcePositionSyncTests

Expected: AppKit 滚动读取、光标不变、Raw 大纲跳转、Raw → Rendered 锚点均通过。

### Task 4：切换状态迁移与全量验证

**Files:**

- Modify: Sources/MarkdownReader/ViewModels/DocumentViewModel.swift:94-101,317-335
- Modify: Tests/MarkdownReaderTests/SourcePositionSyncTests.swift

**Step 1: 最小迁移**

~~~swift
var rawVisibleSourceLine: SourceLine = .first

// switchDisplayMode(_:) 的 Raw → Rendered 分支
requestScroll(to: rawVisibleSourceLine)
~~~

Rendered → Raw 继续使用既有 renderedVisibleSourceLine，不改 WebView 代码。

**Step 2: 检查旧路径已清除**

Run: rg -n 'cursorSourceLine|onCursorSourceLineChanged' Sources Tests

Expected: 没有生产引用。

**Step 3: 完整自动验证**

Run: swift test
Run: swift build
Run: swift build -c release
Run: git diff --check
Run: git status --short --branch

Expected: 测试全绿、Debug/Release 可构建、无 diff 空白错误；不得新增 warning 或失败。

**Step 4: GUI 验收**

Run: swift run MarkdownReader

在长 Markdown 中确认：

1. Rendered 滚到中部 → Raw：两边显示同一源码块附近。
2. Raw 只滚动、不移动光标 → Rendered：Rendered 跟随 Raw 当前可见块，而不是旧光标行。
3. Raw 点击大纲后等待一秒 → Rendered：仍显示所点标题附近。
4. Raw 查找跳转后 → Rendered：仍显示命中项附近。
5. 拖动滚动条、触控板、Page Down 各验证一次，光标/选区不变化。
6. 往返 10 次并编辑内容，问题 1 仍成立：第一次切 Rendered 就显示新内容且没有空白。

**Step 5: 提交**

Run: git add Sources/MarkdownReader/ViewModels/DocumentViewModel.swift Sources/MarkdownReader/Views/RawMarkdownView.swift Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift Sources/MarkdownReader/Views/DetailView.swift Tests/MarkdownReaderTests/SourcePositionSyncTests.swift
Run: git commit -m "fix: sync rendered view to raw visible source line"

不得把现有任务文档意外纳入本次代码提交；若要提交文档，另行单独确认和提交。

## 回滚

若发现滚动抖动、光标被移动或隐藏 Raw 覆盖 Rendered 状态，停止发布并回滚该单独提交：

Run: git revert <raw-visible-source-position-fix-commit>
Run: swift test

不要使用 git reset --hard；不得回滚已验证的 WebView 常驻 / 渲染 ACK 修复，也不得删除当前未跟踪的任务文档。


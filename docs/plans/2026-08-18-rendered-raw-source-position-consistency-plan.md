# Markdown Reader 渲染与编辑源码位置一致性 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** 让 Raw 与 Rendered 围绕同一份 Markdown 源码位置双向切换，并让大纲、查找跳转和渲染页大纲高亮使用同一行号契约。

**Architecture:** 在 `MarkdownReaderKit` 新增不可与数组索引混淆的 `SourceLine` 值类型，统一为 1-based 源码行号；所有跨层状态、回调和跳转请求传递该类型。仅在 `NSTextView` 的字符偏移计算边界转换为 0-based 行索引，WebView 的 `data-line` / JavaScript 保持既有 1-based 协议。`DocumentViewModel` 在两种模式切换时各自选择已记录的 source anchor，消除 Rendered → Raw 的缺失方向。

**Tech Stack:** Swift 6.2、SwiftUI、AppKit (`NSTextView`)、WebPage/WebKit、swift-markdown、XCTest、Swift Package Manager。

---

## 一、问题、目标与固定契约

### 当前问题

1. `renderedVisibleLineNumber` 在 `WebViewMarkdownView` 的滚动回调中写入，却没有被 `DocumentViewModel.switchDisplayMode(_:)` 读取；从 Rendered 切回 Raw 时，编辑器只显示它自己先前遗留的滚动位置。
2. 同一个 `scrollToLineRequest: Int` 同时承载不同单位：`OutlineService` 和 `FindReplaceViewModel` 输出 0-based，Raw 跳转也按 0-based 解释；HTML `data-line`、Raw 光标和 WebView 可见行则为 1-based。因而大纲活跃态比较、Rendered 大纲跳转与 Rendered 查找跳转都会出现一行或一个块的偏差。

### 固定行号协议

| 名称 | 类型 | 值域 | 说明 |
|---|---|---:|---|
| `SourceLine` | `MarkdownReaderKit` 值类型 | `1...` | 任何跨模块、跨模式的 Markdown 源码行位置；禁止裸 `Int` 传递。 |
| `SourceLine.oneBased` | `Int` | `1...` | 对应 swift-markdown `SourceLocation.line`、HTML `data-line` 和 JavaScript `MR.scrollToLine`。 |
| `SourceLine.zeroBasedIndex` | `Int` | `0...` | 仅在 Raw 编辑器从 `content.components(separatedBy: "\n")` 计算字符偏移时使用。 |
| 未定位的 HTML 块 | 不创建 `SourceLine` | — | 保持现有 `data-line="0"` 的降级输出；不可作为模式切换、大纲高亮或跳转目标。 |

### 成功标准

- Raw → Rendered：切换后光标所在的源码块进入 Rendered 视口中央附近。
- Rendered → Raw：切换后 Rendered 顶部可见的源码块进入 Raw 视口；不再回到上一次 Raw 停留位置。
- 点击同一个大纲条目、在查找栏跳转同一个匹配项，在两种模式均定位到同一源码块；当前 Rendered 标题能高亮对应的大纲条目。
- 不以“两个视图的像素 Y 值相等”为验收目标：字体、折行、表格和图片高度不同；验收目标是同一 `SourceLine` 锚点。

## 二、范围

### 包含

- `SourceLine` 的定义与转换边界。
- 大纲、查找、Raw 光标、WebView 可见行、切换请求与活跃大纲的统一行号协议。
- Rendered → Raw 位置同步。
- 单元测试、真实 `NSTextView` 跳转测试，以及 GUI 回归矩阵。

### 不包含

- 2026-08-18 已合入 `972b677` 的编辑器末尾滚动抖动保护、`bottomOverscroll`、`extraLineFragmentUsedRect` 或高亮恢复几何的任何改动。
- 改动 Markdown 渲染 HTML 结构、CSS、WebView 加载/重载策略、缩放、PDF、Quick Look、内容复制、分栏预览或设置持久化。
- 保存每种模式各自的独立像素滚动百分比；本任务只同步源码锚点。

## 三、实施任务

### Task 0：建立隔离基线与回归样本

**Files:**

- Create: 无。
- Verify: 当前 `main`、merge commit `972b677`、现有测试目标。

**Step 1: 创建干净 worktree**

```bash
git status --short --branch
git fetch origin main --tags
git worktree add -b codex/rendered-raw-source-position \
  ../MarkdownReader-rendered-raw-source-position main
cd ../MarkdownReader-rendered-raw-source-position
git status --short --branch
git log -1 --oneline
```

Expected: 新 worktree 无修改，基线包含 `972b677`；若 `main` 已前进，先审查与本任务相关的差异，不要从旧版本覆盖主线。

**Step 2: 固定 GUI 样本文档与观察点**

在 `/tmp/markdownreader-source-position-fixture.md` 创建一份不纳入仓库的长 Markdown，至少包含：第 1 行 H1、空行后的 H2、普通段落、无序列表、围栏代码块、表格、文末 H2。记下各标题和一个段落匹配词的 1-based 行号；样本只用于 GUI，不修改项目中的 Markdown 文件。

**Step 3: 记录当前失败行为**

运行当前应用，Raw 中将光标置于样本中部标题后切 Rendered；随后在 Rendered 独立滚到文末标题再切回 Raw。记录 Raw 是否仍停在首次 Raw 位置。再在 Rendered 点击第二个大纲标题与查找命中，记录是否落在前一源码块。此记录只用于确认测试目标，不提交截图或修改产品文件。

### Task 1：先为统一的源码行号写失败测试

**Files:**

- Create: `Tests/MarkdownReaderTests/SourcePositionSyncTests.swift`
- Modify: `Package.swift:55-59`

**Step 0: 允许测试直接导入 Kit**

将 `MarkdownReaderTests` 的直接依赖从 `["MarkdownReader"]` 扩为 `["MarkdownReader", "MarkdownReaderKit"]`。这是仅供测试编译的 Package.swift 调整，不改变应用产品的依赖图；随后测试文件可同时使用 `@testable import MarkdownReaderKit` 与（Task 3 起）`@testable import MarkdownReader`。

**Step 1: 写 `SourceLine` 的失败测试**

在 `@testable import MarkdownReaderKit` 下新增：

```swift
func testSourceLinePreservesOneBasedAndZeroBasedBoundary() {
    let first = SourceLine(oneBased: 1)
    let fourth = SourceLine(zeroBasedIndex: 3)

    XCTAssertEqual(first.oneBased, 1)
    XCTAssertEqual(first.zeroBasedIndex, 0)
    XCTAssertEqual(fourth.oneBased, 4)
    XCTAssertEqual(fourth.zeroBasedIndex, 3)
}
```

`SourceLine(oneBased:)` 与 `SourceLine(zeroBasedIndex:)` 对小于有效范围的输入必须明确失败（`precondition`），测试不传非法值。

**Step 2: 写大纲转换的失败测试**

在同一文件加入：

```swift
func testOutlineUsesOneBasedSourceLines() {
    let items = OutlineService.parse("# First\n\n## Second")

    XCTAssertEqual(items.map(\.sourceLine.oneBased), [1, 3])
}
```

**Step 3: 运行并确认 red**

```bash
swift test --filter SourcePositionSyncTests
```

Expected: 编译失败，缺少 `SourceLine` 与 `sourceLine`；不要在测试中手动加 1。

### Task 2：在 Kit 层定义唯一位置值并迁移生产者

**Files:**

- Create: `Sources/MarkdownReaderKit/Models/SourceLine.swift`
- Modify: `Sources/MarkdownReaderKit/Models/OutlineItem.swift`
- Modify: `Sources/MarkdownReaderKit/Services/OutlineService.swift`
- Modify: `Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift`
- Test: `Tests/MarkdownReaderTests/SourcePositionSyncTests.swift`

**Step 1: 添加最小 `SourceLine` 值类型**

```swift
public struct SourceLine: Equatable, Hashable, Sendable {
    public let oneBased: Int

    public init(oneBased: Int) {
        precondition(oneBased >= 1)
        self.oneBased = oneBased
    }

    public init(zeroBasedIndex: Int) {
        precondition(zeroBasedIndex >= 0)
        self.oneBased = zeroBasedIndex + 1
    }

    public var zeroBasedIndex: Int { oneBased - 1 }
    public static let first = SourceLine(oneBased: 1)
}
```

不要为此类型加入排序、算术、自动补正或可选的 `0` 哨兵；未知位置保持 `nil`，避免再次用裸整数掩盖单位。

**Step 2: 将大纲位置改为 `SourceLine`**

将 `OutlineItem.lineNumber: Int` 改为 `sourceLine: SourceLine`。`OutlineService` 的 `enumerated()` 索引是 0-based，构造时必须使用 `SourceLine(zeroBasedIndex: index)`。ATX 与 Setext 两种标题均须覆盖；保留 `level`、`title`、代码围栏过滤和 ID 行为不变。

**Step 3: 将渲染标题位置改为 `SourceLine?`**

`MarkdownHTMLService.HeadingInfo` 改为 `sourceLine: SourceLine?`。当 swift-markdown 提供 `heading.range?.lowerBound.line` 时以 `SourceLine(oneBased:)` 构造；没有范围时保持 `nil`。生成 `<h>` 时仅对非 nil 行输出对应的 `data-line`，否则保留当前无可定位目标的降级语义，不生成虚假的第 0 行目标。

所有非 heading block 的既有 `data-line` 行为不作为本任务重构对象；它们仍供 `MR.getTopVisibleLine()` 找当前源码块。

**Step 4: 运行 Task 1 测试并确认 green**

```bash
swift test --filter SourcePositionSyncTests
```

Expected: `SourceLine` 转换和大纲断言均通过。此阶段测试文件不应引用尚未实现的 ViewModel / Raw API；它们在 Task 3 另行先写失败测试。

**Step 5: Commit**

```bash
git add Sources/MarkdownReaderKit/Models/SourceLine.swift \
  Sources/MarkdownReaderKit/Models/OutlineItem.swift \
  Sources/MarkdownReaderKit/Services/OutlineService.swift \
  Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift \
  Tests/MarkdownReaderTests/SourcePositionSyncTests.swift
git commit -m "refactor: unify markdown source line coordinates"
```

### Task 3：迁移切换状态、查找入口与两端跳转适配器

**Files:**

- Modify: `Sources/MarkdownReader/ViewModels/DocumentViewModel.swift:94-103,315-338`
- Modify: `Sources/MarkdownReader/ViewModels/FindReplaceViewModel.swift:30-40,184-204`
- Modify: `Sources/MarkdownReader/Views/DetailView.swift:61-62,479-485,524-530,560-565,610-668`
- Modify: `Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift:260-280,452-502,545-575`
- Modify: `Sources/MarkdownReader/Views/WebViewMarkdownView.swift:77-97,398-401,490-511`
- Test: `Tests/MarkdownReaderTests/SourcePositionSyncTests.swift`

+**Step 1: 写 Task 3 的失败测试**

在 `SourcePositionSyncTests.swift` 中追加 `@testable import MarkdownReader`，再添加：

```swift
@MainActor
func testFindMatchExposesOneBasedSourceLine() {
    let viewModel = FindReplaceViewModel()
    viewModel.searchText = "needle"
    viewModel.performSearch(in: "first\nneedle")

    XCTAssertEqual(viewModel.currentMatchSourceLine?.oneBased, 2)
}

@MainActor
func testRawToRenderedRequestsCursorSourceLine() {
    let viewModel = DocumentViewModel()
    viewModel.displayMode = .raw
    viewModel.cursorSourceLine = SourceLine(oneBased: 8)

    viewModel.switchDisplayMode(.rendered)

    XCTAssertEqual(viewModel.scrollToSourceLineRequest?.oneBased, 8)
}

@MainActor
func testRenderedToRawRequestsVisibleRenderedSourceLine() {
    let viewModel = DocumentViewModel()
    viewModel.displayMode = .rendered
    viewModel.renderedVisibleSourceLine = SourceLine(oneBased: 21)

    viewModel.switchDisplayMode(.raw)

    XCTAssertEqual(viewModel.scrollToSourceLineRequest?.oneBased, 21)
}
```

再为 `RawSourceLineOffset.characterOffset(in:sourceLine:)` 写 `"a\nbb\nccc"` 第 1、2、3 行返回 `0`、`2`、`5` 的测试；测试 Unicode 字符串时也必须以 UTF-16 长度断言。不要在单元测试中伪造 `NSTextView` 滚动。

Run:

```bash
swift test --filter SourcePositionSyncTests
```

Expected: 编译失败，缺少 `currentMatchSourceLine`、`cursorSourceLine`、`renderedVisibleSourceLine`、`scrollToSourceLineRequest` 和 `RawSourceLineOffset`；该 red 状态必须发生在迁移生产代码前。

**Step 2: 迁移 `DocumentViewModel` 的跨模式状态**

将以下裸 `Int` 属性替换为 `SourceLine`：

```swift
var scrollToSourceLineRequest: SourceLine?
var cursorSourceLine: SourceLine = .first
var renderedVisibleSourceLine: SourceLine = .first
```

将 `requestScrollToLine(_:)` 改为 `requestScroll(to:)`。`switchDisplayMode(_:)` 必须先保存 previous mode，更新 mode/cache 后执行：

```swift
switch (previousMode, mode) {
case (.raw, .rendered): requestScroll(to: cursorSourceLine)
case (.rendered, .raw): requestScroll(to: renderedVisibleSourceLine)
default: break
}
```

保留纯文本限制、每文件 mode 缓存和清除请求 API。不要尝试在这里保存 Raw 的像素滚动位置。

**Step 3: 迁移查找结果**

保留 `SearchResult.lineNumber(for:)` 的内部 0-based 算法和二分查找；把公开计算属性改名为 `currentMatchSourceLine`，并仅在该边界构造：

```swift
return searchResult.map { SourceLine(zeroBasedIndex: $0.lineNumber(for: range.location)) }
```

更新 `DetailView` 两个 Rendered 查找入口，调用 `requestScroll(to:)`。Raw 的查找选择、高亮和替换逻辑不改变。

**Step 4: 迁移 Raw 适配器**

将 `SyntaxHighlightedEditor.scrollToLine` 改为 `scrollToSourceLine: SourceLine?`，回调改为 `onCursorSourceLineChanged: ((SourceLine) -> Void)?`。光标通知从换行计数产生的现有 1-based 值构造 `SourceLine(oneBased:)`。

将 `scrollToLineInTextView` 改为接收 `SourceLine`，通过 `sourceLine.zeroBasedIndex` 计算字符偏移。实现并使用：

```swift
enum RawSourceLineOffset {
    static func characterOffset(in content: String, sourceLine: SourceLine) -> Int? {
        let lines = content.components(separatedBy: "\n")
        let index = sourceLine.zeroBasedIndex
        guard lines.indices.contains(index) else { return nil }
        return lines[..<index].reduce(0) { $0 + $1.utf16.count + 1 }
    }
}
```

用 UTF-16 长度而不是 `String.count`，以匹配 `NSRange` / `NSTextView` 的坐标系。保留现有的 1/3 可视位置、动画和 Task `972b677` 的末尾滚动保护；不要改 `EditorScrollGeometry`。

**Step 5: 迁移 WebView 适配器与大纲活跃态**

`WebViewMarkdownView` 的 `scrollToLine` 和 `onVisibleLineChanged` 改为 `SourceLine`。调用 JavaScript 时只传 `sourceLine.oneBased`；从 `MR.getTopVisibleLine()` / `MR.getVisibleHeading()` 得到正整数后构造 `SourceLine`，非正值/无法解析时不回调。

`DetailView.activeOutlineLineNumber` 改为 `SourceLine?`。大纲点击传 `item.sourceLine`；渲染标题回调仅在 `heading.sourceLine` 非 nil 时赋值，否则置 nil。这样 `OutlineView` 的相等比较直接比较同类型值。

**Step 6: 只在目的视图处理请求清理时机**

保留 Raw 0.5 秒、Rendered 2.5 秒的既有加载保护与 `clearScrollRequest()`，但所有观察点都改为 `scrollToSourceLineRequest`。不得在 `switchDisplayMode(_:)` 内抢先清空请求；新 Rendered 视图必须能够从其初始 input 捕获 Raw → Rendered 的目标，新 Raw 视图也必须能够捕获 Rendered → Raw 的目标。

若实现时发现两个并存视图会让非活动视图消费/清除请求，新增一个内部 `ScrollRequest(id: UUID, sourceLine: SourceLine)`，由目的模式确认收到同一 `id` 后才清除；先为该竞态写失败测试，不能依靠调整延迟数值掩盖。

**Step 7: 运行完整的源码位置测试并确认 green**

```bash
swift test --filter SourcePositionSyncTests
```

Expected: 该测试文件全部通过，至少覆盖：首行/中间行转换、ATX/Setext 大纲、查找第二行、Raw → Rendered、Rendered → Raw、Raw UTF-16 字符偏移和同模式不产生新请求。

**Step 8: Commit**

```bash
git add Sources/MarkdownReader/ViewModels/DocumentViewModel.swift \
  Sources/MarkdownReader/ViewModels/FindReplaceViewModel.swift \
  Sources/MarkdownReader/Views/DetailView.swift \
  Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift \
  Sources/MarkdownReader/Views/WebViewMarkdownView.swift \
  Tests/MarkdownReaderTests/SourcePositionSyncTests.swift
git commit -m "fix: keep rendered and raw source positions aligned"
```

### Task 4：端到端回归、发布构建与人工验收

**Files:**

- Modify: 无（仅在测试发现缺口时回到对应任务，新增最小测试后再改代码）。

**Step 1: 运行自动验证**

```bash
swift test --filter SourcePositionSyncTests
swift test --filter SyntaxHighlightedEditorScrollTests
swift test
swift build
swift build -c release
git diff --check main...HEAD
git status --short
```

Expected: 专项与全量测试均通过，两个构建退出码为 0，`git diff --check` 无输出；记录既有而非本次新增的编译警告，不将警告误报为测试失败。

**Step 2: Raw → Rendered GUI 矩阵**

对临时样本文档的普通段落、列表内段落、围栏代码块之后的标题、表格之后的标题分别：在 Raw 把光标置于该行，切到 Rendered。每次目标源码块必须进入可见区中央附近，不得跳到前一块；反复三次不得因旧请求跳回先前位置。

**Step 3: Rendered → Raw GUI 矩阵**

在 Rendered 将四个同样的目标块滚到顶部可见区，再切到 Raw。Raw 必须显示对应源码行而非其上一次 Raw 停留处；文首、文末和连续两次反向切换也必须正确。允许不同模式下的视觉纵向偏移，不允许来源块不同。

**Step 4: 大纲与查找 GUI 矩阵**

- 在 Raw / Rendered 分别点击同一 ATX 与 Setext 大纲条目，目标标题一致；在 Rendered 滚动时对应大纲条目高亮。
- 在 Rendered 查找第二个和最后一个匹配项，跳转块与源码匹配行一致；Raw 查找的选择/高亮保持原行为。
- 切换字体大小、主题、窗口宽度、显示/隐藏大纲并重复一次中段双向切换，确保布局变化不改变 source anchor。

**Step 5: Commit 验收记录（如项目维护流程要求）**

仅在维护流程明确需要时，更新对应 release/任务记录；本任务不因位置同步改动而单独发版。不要修改 CHANGELOG、版本号、GitHub Release 或远端分支，除非另有明确请求。

## 四、回滚

- 若统一契约导致 Raw 或 Rendered 任一入口无法跳转，先以最后一个 Task 2/Task 3 小提交回退；不要用 `+1/-1` 临时补丁散落在调用方。
- 若仅 Rendered → Raw 方向存在异步请求竞争，保留 `SourceLine` 契约并回退该方向的请求接线；诊断 request 生命周期后再处理，不回退刚合入的 `972b677` 文末滚动保护。
- 若发布后需整体撤回，使用 `git revert <Task-3-commit>`，并在恢复前重新运行 Task 4 自动验证与 GUI 矩阵。

# 内容区复制与五秒图标反馈实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在渲染与编辑模式各增加一个内容区右上角复制按钮；渲染模式复制富文本结果、编辑模式复制原始 Markdown，并让这两个按钮和顶部路径复制按钮在成功后显示对号五秒。

**Architecture:** 渲染模式的复制操作必须由 WebKit 文档内真实点击事件完成：临时选中 `#mr-content` 后走浏览器原生复制路径，确保剪贴板效果等同页面内全选复制。编辑内容与文件路径继续使用 AppKit `NSPasteboard`。原生入口使用一个可测试的独立反馈状态，DOM 入口在 `markdown-reader.js` 中维护同等的可重置计时。

**Tech Stack:** Swift 6、SwiftUI、Observation、AppKit `NSPasteboard`、WebKit `WebPage`、JavaScript DOM Selection、CSS、XCTest、Swift Package Manager

---

## 一、范围与目标行为

现有顶部路径复制按钮会显示 1.5 秒文字 Toast，图标本身不变；渲染页现有的代码块复制按钮只复制代码文本、反馈时间为 2 秒。本任务的三项入口与语义如下：

| 入口 | 复制内容 | 成功反馈 |
|---|---|---|
| 渲染模式内容区右上角 | `#mr-content` 的富文本结果，等同页面内全选后复制 | 图标变 `checkmark`，5 秒后恢复 |
| 编辑模式内容区右上角 | 当前 `documentViewModel.content` 的原始 Markdown | 图标变 `checkmark`，5 秒后恢复 |
| 顶部文件路径后的现有按钮 | 当前文件绝对路径 | 图标变 `checkmark`，5 秒后恢复 |

具体约束：

- 只有复制真实成功后才能显示对号；失败保持复制图标。
- 同一入口连续点击会从最后一次成功重新计算 5 秒，旧计时不得提前取消新反馈。
- 三个入口互不共享成功状态或计时。
- 内容区按钮在查找栏打开时隐藏，避免右上角浮层重叠。
- 切换模式、切换文件或销毁视图后不能遗留旧文档的对号。
- 现有代码块复制的文本语义、2 秒反馈和样式保持不变。

## 二、方案选择

采用“渲染页 DOM 按钮 + 原生 SwiftUI 按钮”的混合方案。

渲染页按钮必须放在 WebKit 文档内，由其 `click` 事件临时选择 `#mr-content` 并调用 `document.execCommand("copy")`。这样 WebKit 会写出与用户在页面中全选复制相同的富文本剪贴板内容，可保留标题、强调、表格、代码样式及渲染后的内容。复制后需要恢复用户点击前的 DOM 选区。

编辑模式和路径按钮不依赖 Web 文档，直接写入 `NSPasteboard.general`。编辑复制的源必须是 `documentViewModel.content`，不得通过 Select All、`NSTextView` 当前选区或查找引用读取内容，以免影响焦点、选择和 per-file undo。

不采用以下方案：

- 从外层 SwiftUI 按钮调用 `page.callJavaScript`：这不是 Web 文档用户手势，WebKit 可能拒绝复制或退化为非富文本路径。
- Swift 层手工生成 HTML/RTF：重复 WebKit 转换，容易遗漏复杂渲染和未来扩展。
- 让 DOM 按钮调用 `navigator.clipboard.writeText` 或 hidden textarea：只会复制纯文本，不满足渲染态富文本要求。

## 三、改动边界与数据流

1. `MarkdownHTMLService.buildFullHTML` 在 `.markdown-preview` 上注入经过 XML 属性转义的内容复制/成功本地化文案。
2. 页面初始化时，`markdown-reader.js` 在 `#mr-content` 外追加一个唯一 `mr-document-copy-btn`。按钮采用 `position: fixed`，因此不改变正文尺寸，不会被复制到正文，也不会随长文档滚动离开视口。
3. 点击渲染按钮时，脚本保存全部已有 Range，选择 `#mr-content`，执行原生 copy，并在 `finally` 恢复所有旧 Range。仅 `copy` 返回成功时显示对号。
4. `DetailView.documentContentView` 为 `.raw` 模式叠加原生浮动复制按钮；写入 `documentViewModel.content` 成功后显示对号。
5. 顶部路径按钮保留既有剪贴板写入，删除标题栏居中 Toast，改为自身图标和 tooltip 的状态切换。
6. `WebViewMarkdownView` 把查找栏显示状态和运行时语言变化同步给 DOM 按钮；查找栏打开时渲染按钮隐藏。

## 四、实施任务

### Task 1：建立原生复制反馈状态及测试

**Files:**

- Create: `Sources/MarkdownReader/Models/CopyFeedbackState.swift`
- Create: `Tests/MarkdownReaderTests/CopyFeedbackStateTests.swift`

**Step 1: Write the failing tests**

添加纯状态测试，至少覆盖首次成功、重复成功、旧 generation 重置、最新 generation 重置与 `invalidate()`：

```swift
func testStaleResetDoesNotClearLaterCopyFeedback() {
    var state = CopyFeedbackState()
    let first = state.begin()
    let second = state.begin()

    state.reset(ifCurrent: first)
    XCTAssertTrue(state.isShowingSuccess)

    state.reset(ifCurrent: second)
    XCTAssertFalse(state.isShowingSuccess)
}
```

**Step 2: Verify the test fails**

Run:

```bash
swift test --filter CopyFeedbackStateTests
```

Expected: 编译失败，提示 `CopyFeedbackState` 尚不存在。

**Step 3: Implement the minimal state**

创建不含计时器、不含剪贴板 I/O 的值类型：

```swift
struct CopyFeedbackState {
    private(set) var isShowingSuccess = false
    private var generation = 0

    mutating func begin() -> Int { /* increment, show success, return generation */ }
    mutating func reset(ifCurrent generation: Int) { /* only reset latest generation */ }
    mutating func invalidate() { /* invalidate pending resets and hide success */ }
}
```

**Step 4: Verify the focused suite passes**

Run:

```bash
swift test --filter CopyFeedbackStateTests
```

Expected: PASS。

**Step 5: Commit**

```bash
git add Sources/MarkdownReader/Models/CopyFeedbackState.swift Tests/MarkdownReaderTests/CopyFeedbackStateTests.swift
git commit -m "test: cover copy feedback state"
```

### Task 2：实现顶部路径与编辑模式的原生复制反馈

**Files:**

- Modify: `Sources/MarkdownReader/Views/DetailView.swift`
- Modify: `Sources/MarkdownReaderKit/Services/LocalizationService.swift`
- Test: `Tests/MarkdownReaderTests/CopyFeedbackStateTests.swift`

**Step 1: Add localization**

在现有 `titleBarCopyPath` / `titleBarPathCopied` 附近增加 `contentCopy` 与 `contentCopied`，在三种字典内补齐：

| Key | English | 简体中文 | 繁體中文 |
|---|---|---|---|
| `contentCopy` | `Copy Content` | `复制内容` | `複製內容` |
| `contentCopied` | `Content Copied` | `内容已复制` | `內容已複製` |

**Step 2: Replace the title-bar Toast**

在 `DetailView`：

- 移除 `showPathCopied` 和标题栏 `.overlay` 中的文字 Toast。
- 为路径按钮独立持有 `CopyFeedbackState` 与可取消的 `Task`。
- `NSPasteboard.setString` 成功后调用 `begin()`，将图标从 `doc.on.doc` 改为 `checkmark`，启动 5 秒 `Task.sleep`，再调用 `reset(ifCurrent:)`。
- 图标放在固定 frame 内，避免路径文本横向跳动；普通/成功态 `.help` 分别使用 `titleBarCopyPath` / `titleBarPathCopied`。
- `onDisappear` 取消 task 并 `invalidate()`。

**Step 3: Add the Edit-mode button**

在 `documentContentView` 新增 `.topTrailing` 原生 overlay，仅当以下条件均为真时显示：

```swift
documentViewModel.hasDocument
    && documentViewModel.displayMode == .raw
    && !appViewModel.isFindBarVisible
```

按钮为紧凑的圆角/胶囊风格，具有主题 surface、border、shadow、hover/focus 状态和固定图标 frame。点击后清空并向 `NSPasteboard.general` 写入 `documentViewModel.content`；仅返回成功时启动它自己的五秒状态与对号。不得调用 Select All，不得改动 `TextViewSearchRef`、`NSTextView` selection 或 undo 栈。

**Step 4: Prevent stale state**

在 raw/rendered 模式变化、文档 URL/身份变化与 `onDisappear` 时，取消编辑按钮的重置 task 并 `invalidate()`。重复点击必须以 generation 保证早先计时不会恢复最新对号。

**Step 5: Verify and commit**

Run:

```bash
swift test --filter CopyFeedbackStateTests
swift build
```

Expected: PASS。

```bash
git add Sources/MarkdownReader/Views/DetailView.swift Sources/MarkdownReaderKit/Services/LocalizationService.swift Tests/MarkdownReaderTests/CopyFeedbackStateTests.swift
git commit -m "feat: add native copy feedback controls"
```

### Task 3：实现渲染模式的富文本复制入口

**Files:**

- Modify: `Sources/MarkdownReader/Views/WebViewMarkdownView.swift`
- Modify: `Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift`
- Modify: `Sources/MarkdownReader/Resources/js/markdown-reader.js`
- Modify: `Sources/MarkdownReader/Resources/css/markdown.css`

**Step 1: Pass localized document-button labels into HTML**

让 `WebViewMarkdownView` 提供普通/成功两种本地化文案，并让 `MarkdownHTMLService.buildFullHTML` 将其以 XML 属性转义后写到 `.markdown-preview` 的 `data-document-copy-title` 和 `data-document-copied-title`。运行时语言变化时，调用一个小型 `MR` 方法更新按钮的 `title` 与 `aria-label`，不要为了更新文案整页重新加载。

**Step 2: Implement rich-content copy in the DOM**

在 `markdown-reader.js` 添加 `MR.copyRenderedContent()`。它必须完成下面的序列，并在 `try`/`finally` 中确保无论 copy 成功、失败或抛错，原选区都能恢复：

```javascript
const content = document.getElementById('mr-content');
if (!content) return false;
const selection = window.getSelection();
const oldRanges = Array.from({ length: selection.rangeCount }, (_, index) => selection.getRangeAt(index).cloneRange());
const range = document.createRange();
try {
  range.selectNodeContents(content);
  selection.removeAllRanges();
  selection.addRange(range);
  return document.execCommand('copy');
} finally {
  selection.removeAllRanges();
  oldRanges.forEach(oldRange => selection.addRange(oldRange));
}
```

不得使用 `navigator.clipboard.writeText`、隐藏 textarea 或 Swift 端手工生成 RTF/HTML。这些做法无法保证“富文本、等同全选复制”的要求。

**Step 3: Add one DOM-owned floating button**

新增 idempotent 的 `MR.addDocumentCopyButton()`，并在 `MR.init()` 调用它。要求：

- 元素追加到 `#mr-content` 外部，例如 `document.body`，采用唯一 id 与 `mr-document-copy-btn` 类；不得随 `MR.replaceContent()` 被删除，也不得复制进正文。
- 点击 listener 直接在页面事件内调用 `MR.copyRenderedContent()`；返回 `false` 时不显示成功状态。
- 成功时使用现有复制 SVG/对号 SVG 风格切换图标，添加成功 class，更新 `title` 与 `aria-label`，并开始 5000 ms 定时。
- 连续点击需要 `clearTimeout` 后再重新计时；五秒结束恢复复制 SVG、普通 class 与普通标签。
- 代码块 `MR.addCopyButtons()` 和其 2000 ms 行为不得改动。

**Step 4: Synchronize find visibility**

向 `MR` 增加仅用于本按钮的 `setDocumentCopyButtonHidden(isHidden)` 与 `setDocumentCopyButtonLabels(normal, copied)`。`WebViewMarkdownView` 在页面初始化后以及 `isFindBarVisible`、语言变化时调用它们。查找栏显示期间，DOM 按钮不可见且不接收点击。

**Step 5: Add narrowly scoped styles**

在 `markdown.css` 新增且仅新增 `.mr-document-copy-btn` 的规则：

- `position: fixed` 位于内容视口右上角，z-index 高于正文；不修改 `.markdown-preview`、正文宽度或 padding。
- 默认可见，紧凑，使用现有 `--bg-muted`、`--border`、`--fg-muted`、`--ink`、`--success` 主题变量。
- 完整提供 hover、active、`:focus-visible`、copied 与 hidden 状态；hidden 状态没有 hit target。
- transition 只作用于 opacity、color、background，不影响正文布局。

**Step 6: Build and commit**

Run:

```bash
swift build
git diff --check
```

Expected: build 成功；`git diff --check` 无输出。提交本任务涉及的四个文件，提交信息为 `feat: copy rendered content with formatting`。

### Task 4：端到端验收与完整回归

**Files:**

- Verify: `Sources/MarkdownReader/Views/DetailView.swift`
- Verify: `Sources/MarkdownReader/Views/WebViewMarkdownView.swift`
- Verify: `Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift`
- Verify: `Sources/MarkdownReader/Resources/js/markdown-reader.js`
- Verify: `Sources/MarkdownReader/Resources/css/markdown.css`

**Step 1: Run all automated checks**

Run:

```bash
swift test
swift build
git diff --check
```

Expected: 所有测试、构建均通过，且 whitespace 检查无输出。

**Step 2: Verify Rendered-mode rich copy**

打开一个包含标题、强调文本、表格、围栏代码块、链接和图片的 Markdown 文件。在渲染模式中：

1. 点击内容区右上角的新按钮，确认立即变对号并在 5 秒后恢复。
2. 粘贴至 TextEdit 富文本模式；再在同一页面手动全选并复制、粘贴到相同目标。
3. 对比两份结果：正文及其格式一致，按钮自身不在复制结果中。
4. 点击前先在正文创建一个选区，点击后确认原选区恢复。
5. 在第 5 秒前再次点击，确认以最后一次点击开始重新计时。

**Step 3: Verify Edit mode and path feedback**

编辑模式点击内容按钮并粘贴到纯文本目标，必须逐字节等于当前原始 Markdown（含标记与换行）。验证对号的 5 秒、快速重复点击、模式切换、文件切换、关闭窗口均不留下旧反馈。点击顶部路径按钮，确认不再有标题栏文字 Toast，图标变对号 5 秒，剪贴板中是当前绝对路径。

**Step 4: Verify visual regressions**

分别检查浅色/深色主题、窄窗口、长文档滚动、键盘 Tab 焦点和查找栏打开状态。复制按钮在普通状态固定于内容视口右上角，不改变渲染内容宽度，不与查找栏重叠，有足够对比度；现有代码块按钮仍只复制代码，且维持原来的 2 秒反馈。

## 五、完成标准

- Rendered mode 通过 WebKit 的选择复制路径复制富文本，实际粘贴结果与页面内手动全选复制一致。
- Edit mode 复制精确的当前原始 Markdown；路径入口复制精确的当前绝对路径。
- 三个入口各自成功后显示对号五秒；同一入口再次成功只重置自己的计时，旧计时不会提前恢复。
- 失败不显示成功；模式、文件或视图生命周期变化不会残留旧状态。
- 查找栏、滚动、选择、undo、主题、本地化、正文布局与既有代码块复制均未回归。
- `swift test`、`swift build`、`git diff --check` 全部成功。

## 六、不包含

- 不增加菜单项、快捷键、右键菜单或全局“复制全部”命令。
- 不改变现有代码块复制的内容、两秒反馈或样式。
- 不修改 Markdown 渲染语义、PDF 导出、Quick Look 扩展、文件保存、更新与发布流程。
- 不自行生成替代 WebKit 原生复制行为的富文本、RTF、HTML 或图片剪贴板载荷。

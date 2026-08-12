# 内容区复制按钮视觉收敛实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让渲染与编辑模式右上角的内容复制按钮使用同一复制图标、同一紧凑尺寸和同一定位，并移除两者的方形背景、边框和阴影，使其与顶部路径后的复制按钮一样轻量且不干扰正文。

**Architecture:** 以 `DetailView` 顶部路径按钮的默认态 `doc.on.doc` 为唯一视觉基准。编辑模式复用该现有 SF Symbol；渲染模式的 DOM SVG 调整为同一“两个重叠文档”的复制图形和相同 14 pt 视觉画布。按钮仍分别留在 SwiftUI 与 WebKit DOM 中，保留其各自已经验证的复制语义与五秒成功状态；本次只移除容器装饰并统一呈现参数。

**Tech Stack:** Swift 6、SwiftUI、WebKit `WebPage`、JavaScript、CSS、XCTest、Swift Package Manager

---

## 背景与问题

已完成的内容复制功能在行为上符合要求：渲染模式复制富文本、编辑模式复制原始 Markdown，成功后都显示五秒对号。当前视觉仍有两处不一致：

| 项目 | 编辑模式 | 渲染模式 |
|---|---|---|
| 默认图标 | SF Symbol `doc.on.doc` | 独立内联 SVG，沿用代码块复制的图形风格 |
| 可视容器 | 16 pt 图标外再添加 6 pt padding、圆角 surface、border、shadow | 6 px padding、圆角 background、border、shadow |
| 位置 | `top: 8` / `trailing: 16` | `top: 12px` / `right: 12px` |

顶部路径复制按钮已经是目标形态：`doc.on.doc`、11 pt 字号、14 pt 宽、无背景/边框/阴影。本任务将两个内容区按钮收敛到这个轻量基线。

## 目标视觉合同

- 两个内容区默认态都表示同一个复制动作：`doc.on.doc`（两张重叠文档）这一种图标，不再将渲染模式的内容复制按钮借用为代码块复制按钮样式。
- 两个内容区图标的可见尺寸均为 **14 × 14 pt/px**；编辑模式使用与顶部路径按钮相同的 11 pt SF Symbol 配置，渲染模式 SVG 固定 `width="14" height="14" viewBox="0 0 16 16"`。
- 两个内容区按钮都固定在内容视口右上角：距右 16、距上 8；不占正文宽度，不随正文滚动，不改变正文 padding 或最大宽度。
- 默认、hover、active、成功态均**没有**方形/圆角背景、边框或阴影。普通交互只可调整前景色；键盘 `:focus-visible` 可保留无填充的焦点描边。
- 成功态仍使用同尺寸 `checkmark`，仅改变前景色为 `themeColors.success` / `--success`，持续 5 秒后恢复默认复制图标。
- 查找栏隐藏、PDF 打印隐藏、本地化 tooltip/ARIA 标签、连续点击重置五秒计时、富文本复制和原始 Markdown 复制的已有行为必须原样保留。

## 不采用的做法

- 不再为内容复制按钮添加 surface、rounded rectangle、border、shadow 或 hover/active 背景。
- 不增加新的 SVG/PDF/PNG asset、资源加载器或跨 Swift/JavaScript 图标框架；本次以现有顶部路径 `doc.on.doc` 的视觉定义为基准，在 DOM 中实现相同图形，避免为一个 14 pt 图标扩大资源与打包边界。
- 不调整现有代码块 `.mr-copy-btn`。它是独立的代码块操作控件，可保持当前悬停背景和两秒反馈。
- 不修改 `CopyFeedbackState`、`NSPasteboard` 写入、`MR.copyRenderedContent()`、选区恢复、计时长度、查找同步或本地化键值。

## 实施任务

### Task 1：冻结现有功能基线与确认视觉验收样本

**Files:**

- Verify: `Tests/MarkdownReaderTests/CopyFeedbackStateTests.swift`
- Verify: `Sources/MarkdownReader/Views/DetailView.swift:196-212, 692-715`
- Verify: `Sources/MarkdownReader/Resources/js/markdown-reader.js:470-569`
- Verify: `Sources/MarkdownReader/Resources/css/markdown.css:372-421`

**Step 1: Run the existing feedback-state regression suite**

Run:

```bash
swift test --filter CopyFeedbackStateTests
```

Expected: PASS。该套件覆盖成功状态、重复复制、旧 generation 不能提前清除新状态，以及 `invalidate()`；本任务不得修改这些语义。

**Step 2: Record the three visual reference points manually**

打开任意 Markdown 文档，在浅色和深色主题分别观察：

1. 顶部路径后的 `doc.on.doc` 按钮，作为唯一的尺寸、轻量感与无背景基准；
2. 编辑模式内容区按钮，记录当前过大的方块容器；
3. 渲染模式内容区按钮，记录当前独立 SVG、位置和方块容器。

本任务不新增脆弱的截图/像素单测。现有测试覆盖状态机，视觉一致性以 Task 3 的真实应用验收为准。

### Task 2：收敛编辑模式按钮到路径按钮基线

**Files:**

- Modify: `Sources/MarkdownReader/Views/DetailView.swift:692-715`
- Verify: `Sources/MarkdownReader/Views/DetailView.swift:196-212`

**Step 1: Keep the existing icon semantics and feedback state**

保留编辑模式标签中基于 `contentCopyState.isShowingSuccess` 的分支：

```swift
Image(systemName: contentCopyState.isShowingSuccess ? "checkmark" : "doc.on.doc")
```

不得改动 `copyRawContent()`、`beginContentCopyFeedback()`、五秒计时、tooltip、本地化或 raw 模式/查找栏显示条件。

**Step 2: Apply the title-bar icon geometry**

将编辑模式默认图标调整为与路径按钮相同的视觉参数：

```swift
.font(.system(size: 11))
.frame(width: 14, height: 14)
.foregroundStyle(contentCopyState.isShowingSuccess ? themeColors.success : themeColors.fgMuted)
```

删除图标 label 上的 `.padding(6)`、`.background(...)`、`.overlay(...)` 与 `.shadow(...)`。不要把任何可见容器样式移动到 `Button` 或外层 overlay。

**Step 3: Keep positioning, remove decorative entrance scaling**

保留 `.padding(.trailing, 16)` 与 `.padding(.top, 8)`，使其成为渲染模式的共同坐标。按钮按模式显隐时只使用 opacity 过渡或不额外过渡；不要再用 scale 使小图标出现时像弹出的方块控件。

**Step 4: Build and inspect the focused diff**

Run:

```bash
swift build
git diff -- Sources/MarkdownReader/Views/DetailView.swift
```

Expected: build 成功；diff 只涉及内容区编辑复制按钮的图标尺寸、颜色、装饰移除与非缩放过渡，不触及路径按钮与复制逻辑。

### Task 3：让渲染模式匹配相同图标与轻量样式

**Files:**

- Modify: `Sources/MarkdownReader/Resources/js/markdown-reader.js:470-534`
- Modify: `Sources/MarkdownReader/Resources/css/markdown.css:372-421`

**Step 1: Replace the rendered-document normal icon definition**

仅修改 `MR._documentCopyIcon`，让它成为 `doc.on.doc` 的 14 × 14、16 × 16 viewBox 单色 SVG 对应图形（两张重叠文档），与编辑模式及路径按钮表达同一个复制 icon。保留 `_documentCopiedIcon` 的 14 × 14 对号、`MR._documentCopyTimer`、DOM id、click listener、成功条件及所有标签逻辑。

不得把代码块 `MR.addCopyButtons()` 的 SVG 定义或两秒行为一起重构；两个复制入口服务的对象不同。

**Step 2: Replace the document-button CSS with icon-only styles**

将 `.mr-document-copy-btn` 改为以下约束：

```css
position: fixed;
top: 8px;
right: 16px;
z-index: 50;
width: 14px;
height: 14px;
padding: 0;
border: 0;
border-radius: 0;
background: transparent;
box-shadow: none;
color: var(--fg-muted);
```

保持 flex 居中与 `cursor: pointer`。`hover` 与 `active` 只能调整 `color`，不得设置 `background`、`border` 或 `box-shadow`。成功 class 只能设置 `color: var(--success)`；去除成功态 border-color。`focus-visible` 允许无填充 outline 来保证键盘可达性。保留 hidden 与 `@media print` 规则。

**Step 3: Preserve nonvisual contracts**

确认以下代码不变：

- `MR.copyRenderedContent()` 的选择、copy、finally 恢复；
- 成功才显示对号、`clearTimeout` 后重新 5000 ms；
- `setDocumentCopyButtonHidden`、`setDocumentCopyButtonLabels`；
- `document.body.appendChild(btn)`，确保控件不被复制进 `#mr-content`。

**Step 4: Build and patch hygiene**

Run:

```bash
swift build
git diff --check
```

Expected: build 成功，且 whitespace 检查无输出。

### Task 4：真实应用验收与提交

**Files:**

- Verify: `Sources/MarkdownReader/Views/DetailView.swift`
- Verify: `Sources/MarkdownReader/Resources/js/markdown-reader.js`
- Verify: `Sources/MarkdownReader/Resources/css/markdown.css`
- Verify: `Tests/MarkdownReaderTests/CopyFeedbackStateTests.swift`

**Step 1: Verify matching appearance in the app**

在同一文档、同一窗口宽度、同一主题下，分别切换渲染/编辑模式。两个按钮必须：

- 都在内容视口 `top: 8 / right: 16` 处；
- 都显示同一种两张文档复制图标，视觉大小为 14；
- 默认态无任何可见方块、胶囊、边框或阴影；
- hover/active 不出现背景；
- 点击成功后都只显示同尺寸绿色对号五秒，再恢复复制图标。

同时和顶部路径后的复制图标并排目测确认：内容图标不比它更大、更重或更像独立浮动按钮。

**Step 2: Verify behavior has not regressed**

- 渲染模式复制后粘贴到富文本目标，结果仍与页面内全选复制一致；按钮不进入被复制内容。
- 编辑模式复制后粘贴为原始 Markdown；未影响编辑器焦点、选区与 undo。
- 快速重复点击分别从最后一次成功重新计时五秒。
- 打开查找栏后内容按钮仍隐藏；关闭后恢复。打印/PDF 导出仍不含渲染模式复制按钮。
- 现有代码块复制按钮仍复制代码文本并保持原有 2 秒反馈。

**Step 3: Run full verification**

Run:

```bash
swift test
swift build
git diff --check
```

Expected: 全部 PASS，且 `git diff --check` 无输出。

**Step 4: Commit the narrowly scoped optimization**

```bash
git add Sources/MarkdownReader/Views/DetailView.swift Sources/MarkdownReader/Resources/js/markdown-reader.js Sources/MarkdownReader/Resources/css/markdown.css
git commit -m "fix: unify content copy button appearance"
```

## 完成标准

- 渲染与编辑内容区使用同一复制 icon、同一 14 pt 视觉尺寸和同一右上角坐标；标题栏路径按钮保持原样并作为视觉基线。
- 两个内容区按钮默认、hover、active 与成功态均没有方形背景、边框或阴影；成功仅以绿色对号反馈。
- 原有复制语义、五秒状态、查找栏避让、PDF 隐藏、无障碍标签、代码块复制与所有非视觉行为没有回归。
- `swift test`、`swift build`、`git diff --check` 均成功。

## 不包含

- 不改动顶部路径按钮的位置、图标、五秒逻辑或 tooltip 文案。
- 不改动代码块复制按钮或其两秒反馈。
- 不增加新图标资源、Asset Catalog、第三方依赖、菜单/快捷键或设置项。
- 不更改 Markdown 渲染、剪贴板富文本载荷、编辑器、PDF 导出、Quick Look、版本与发布流程。

# 分栏编辑与源码锚点滚动跟随 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 Markdown 编辑模式中提供可选的左右分栏编辑/渲染预览、可拖动分隔栏和双向源码锚点滚动跟随，同时复用现有唯一 WebPage，不引入第二个 WebView。

**Architecture:** RawMarkdownView 与现有 WebViewMarkdownView 始终由同一个稳定内容容器持有；通过 rawSingle、splitPreview、fullRendered 三种呈现状态调整两栏宽度、可见性和渲染资格。分栏滚动使用 SourceScrollAnchor（1-based 小数源码位置，全文进度仅作兜底），由独立协调器做 token、内容版本和程序化滚动回声抑制；不能把一次性的 ScrollTransfer 直接扩展为持续同步。

**Tech Stack:** Swift 6.2、SwiftUI、AppKit NSTextView/NSScrollView、macOS 26 WebPage/WebView、MarkdownHTMLService、XCTest、Swift Package Manager。

---

## 一、已确认需求

1. 设置 → 通用 → 默认显示模式中，「渲染｜编辑」分段按钮左侧不得保留空白；显式隐藏空 Picker label 后，以简中、繁中、英文人工确认左缘对齐。
2. 在该分段按钮下方增加「分栏编辑」开关；默认关闭，UserDefaults 没有该 key 时也必须为关闭。
3. 仅 Markdown 文件在进入编辑模式时读取此开关：关闭时维持现有单栏 Raw；开启时显示左侧 Raw 编辑、右侧实时渲染预览。txt 永远维持单栏 Raw。
4. 分栏中间的分隔栏可左右拖动；宽度为窗口级临时状态，默认 1:1，不写入全局设置。
5. 正常渲染和分栏预览复用同一个 WebViewMarkdownView/WebPage，禁止创建第二个 WebView，也不得共享或争抢 exportedPage 绑定。
6. 左栏 Raw 与右栏 Rendered 各自在右上角保留内容复制 icon：左侧复制原始 Markdown，右侧复制富文本渲染内容；沿用现有查找栏打开时隐藏复制 icon 与各自独立成功反馈的语义。
7. 分栏时双向滚动跟随：用户滚动任一侧，另一侧按同一源码位置跟随；不按像素 Y 同步，不移动 Raw 光标/选区，不发生滚动回环。
8. Raw 输入停顿约 200 ms 后刷新右栏；刷新后保持左侧当前源码锚点对应的预览位置。切换为全宽渲染时立即使用最新 documentViewModel.content，不能显示防抖期间的旧预览。

## 二、范围与边界

### 包含

- 设置持久化、三语文案与空 label 布局修复。
- 单 WebView 的三态布局、拖动分隔栏、预览内容防抖、两侧复制入口。
- 基于 SourceScrollAnchor 的分栏双向跟随、程序化滚动去回声、文档版本失效保护。
- 纯逻辑、渲染资格、布局钳制及协调器的 XCTest；完整 GUI 回归矩阵。

### 不包含

- 恢复 v2.3.0 的第二个 WebView、previewExportedPage、旧标题栏分栏开关或旧实现。
- 像素 Y、百分比作为常规同步手段；documentProgress 只保留给源码映射不可用时的兜底。
- 左右滚动条外观同步、同速惯性动画、光标/选区跟随、点击预览后反向编辑。
- 修改 Markdown 解析、主题、Quick Look、PDF 导出、文件监控、per-file undo、编辑器末尾滚动保护或既有单栏模式切换协议。
- 任何发行、tag、Release、DMG/ZIP 或用户既有偏好的迁移清理。

## 三、实现任务

### Task 1：定义可测的分栏状态、布局和滚动同步合同

**Files:**

- Create: Sources/MarkdownReader/Views/SplitEditingCoordinator.swift
- Create: Tests/MarkdownReaderTests/SplitEditingCoordinatorTests.swift
- Modify: Sources/MarkdownReaderKit/Models/SourceScrollAnchor.swift

**Step 1: Write the failing tests**

测试以下纯逻辑，不能依赖 SwiftUI、WebKit 或 AppKit：

- SplitEditingLayout：默认比例 0.5；拖拽结果限制在左右各 minPaneWidth 后的可用范围；窗口变窄时不产生负宽度。
- SplitScrollSyncCoordinator：Raw → Rendered、Rendered → Raw 都产生带新 UUID 的请求；同方向新请求覆盖旧请求。
- 目的端确认同一 token 后，程序化滚动回调不生成反向请求；目的端收到不同 token 的真实用户滚动才可反向驱动。
- 请求携带 contentVersion；内容已变或分栏关闭时，旧请求必须丢弃。
- 相同或小于设定阈值的锚点不发送新请求，避免连续浮点采样抖动。

**Step 2: Run test to verify it fails**

Run: swift test --filter SplitEditingCoordinatorTests

Expected: FAIL，因为 SplitEditingLayout、SplitScrollSyncCoordinator 尚不存在。

**Step 3: Implement the minimal contract**

在新文件定义：

~~~swift
enum RenderPresentation: Equatable {
    case rawSingle
    case splitPreview
    case fullRendered

    var rendersLiveContent: Bool { self != .rawSingle }
}

enum SplitScrollDriver: Equatable { case raw, rendered }

struct SplitScrollSyncRequest: Equatable, Identifiable {
    let id: UUID
    let destination: SplitScrollDriver
    let contentVersion: Int
    let anchor: SourceScrollAnchor
}
~~~

SplitScrollSyncCoordinator 必须明确区分用户滚动、已发出的程序化请求、确认回执和失效状态；不要修改或复用 ScrollTransfer。更新 SourceScrollAnchor 注释，使其明确可由单栏模式切换和分栏同步共用，但仍禁止传给大纲/查找的整数行号接口。

**Step 4: Run test to verify it passes**

Run: swift test --filter SplitEditingCoordinatorTests

Expected: PASS。

### Task 2：添加设置与窗口级分栏宽度状态

**Files:**

- Modify: Sources/MarkdownReader/Models/SettingsModel.swift
- Modify: Sources/MarkdownReader/ViewModels/AppViewModel.swift
- Modify: Sources/MarkdownReader/Views/SettingsView.swift
- Modify: Sources/MarkdownReaderKit/Services/LocalizationService.swift

**Step 1: Add the setting model**

添加 com.markdownreader.defaultSplitEditing 与 defaultSplitEditing: Bool。初始化只在 key 缺失时回退 false，不得覆盖已有值；不向 Quick Look 的共享偏好域扩散。

**Step 2: Repair and extend the settings UI**

将默认显示模式 Picker 改为显式 labelsHidden()，保持 200 宽度；在同一 SettingsSection 内、分段按钮下方新增 Toggle，而非放进同一 HStack。新增简中「分栏编辑」、繁中「分欄編輯」、英文等价文案。

**Step 3: Add window-only layout state**

在 AppViewModel 增加 splitEditingRatio（默认 0.5）及受 SplitEditingLayout 钳制的更新入口。该值不写 UserDefaults，关闭窗口后恢复默认；默认开关是进入 Markdown Raw 模式的布局选择，不是第二套持久化宽度设置。

**Step 4: Build**

Run: swift build

Expected: PASS。

### Task 3：以单一稳定 WebView 重构内容区和分栏拖拽

**Files:**

- Create: Sources/MarkdownReader/Views/SplitPreviewResizeHandle.swift
- Modify: Sources/MarkdownReader/Views/DetailView.swift
- Modify: Sources/MarkdownReader/Views/WebViewMarkdownView.swift
- Modify: Sources/MarkdownReader/Views/WebViewRenderScheduler.swift
- Modify: Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift

**Step 1: Write failing render-presentation tests**

扩展 WebViewRenderSchedulerTests，锁定：

- rawSingle 中纯 content 变化不得请求 WebView 渲染。
- splitPreview 与 fullRendered 中纯 content 变化可以请求渲染。
- 从 splitPreview 进入 fullRendered 必须使用当前文档内容，不能依赖防抖快照。
- 全宽渲染的过渡状态机仅由 fullRendered 驱动；分栏预览完成不结束 Raw → Rendered 过渡。

**Step 2: Implement one WebView layout**

把 DetailView.documentContentView 改为稳定的单一容器：Raw 与 renderedMarkdownView 各只创建一次、父级不因三态而切换。根据 RenderPresentation 分配宽度与 hit-testing：

- rawSingle：Raw 占满，WebView 隐藏且不接收输入更新；
- splitPreview：Raw 左、SplitPreviewResizeHandle 居中、同一 WebView 在右；
- fullRendered：WebView 占满，Raw 保持存活但隐藏。

SplitPreviewResizeHandle 按既有 ResizeHandle/OutlineResizeHandle 的 NSViewRepresentable 鼠标模型实现，调用 AppViewModel 的受限比例更新入口。不得用 SwiftUI DragGesture 替代。

**Step 3: Separate presentation from mode-switch callbacks**

将 WebViewMarkdownView.isRenderedMode 替换或收敛为 RenderPresentation：渲染资格由 rendersLiveContent 判断；onRenderRequested、onRenderGenerationCompleted、模式切换 capture/transfer 只在 fullRendered 参与。分栏预览不写主模式过渡状态，但保留其自身滚动同步接口。

**Step 4: Implement preview update semantics**

DetailView 仅在 splitPreview 时以 200 ms 可取消 task 更新 previewContent。进入分栏时立刻赋当前内容防止右栏空白；切入全宽渲染时直接传 documentViewModel.content。文件切换、分栏关闭、窗口消失时取消旧 task，防止拆毁后的异步写入。

**Step 5: Place copy controls in their panes**

将现有原生 Raw copy overlay 挂到左侧 Raw pane；分栏右栏对同一 WebViewMarkdownView 启用现有 DOM copy button。两个入口继续独立计时，且查找栏可见时沿用现有隐藏约定。

**Step 6: Run focused tests and build**

Run: swift test --filter WebViewRenderSchedulerTests && swift build

Expected: PASS。

### Task 4：接入双向源码锚点滚动跟随

**Files:**

- Modify: Sources/MarkdownReader/Views/DetailView.swift
- Modify: Sources/MarkdownReader/Views/RawMarkdownView.swift
- Modify: Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift
- Modify: Sources/MarkdownReader/Views/WebViewMarkdownView.swift
- Modify: Sources/MarkdownReader/Resources/js/markdown-reader.js（仅在现有 MR.captureSourceScrollAnchor / MR.scrollToSourceScrollAnchor 缺少区分程序化回调的必要钩子时）
- Modify: Tests/MarkdownReaderTests/SplitEditingCoordinatorTests.swift

**Step 1: Keep the source-anchor protocol**

不传像素坐标。Raw 继续用 RawSourceScrollAnchor.capture/apply，Rendered 继续用 MR.captureSourceScrollAnchor / MR.scrollToSourceScrollAnchor；精确映射失败时才使用 documentProgress。应用锚点不得改变 Raw 光标或 selection。

**Step 2: Wire real user-scroll events to the coordinator**

仅 splitPreview 状态下，Raw 与 Rendered 的用户滚动事件分别向协调器提交锚点。协调器产生的请求仅交给另一端：Raw 使用 RawSourceScrollAnchor.apply，Rendered 调用现有 JS 定位函数。应用前核对 request id、destination、当前 contentVersion 与分栏状态。

**Step 3: Suppress feedback loops**

每个程序化定位带 token。目标端回调识别该 token 后只确认，不反向发布；用户在目标端开始真实滚动后才取得主导权。对接近的连续小数锚点限频/阈值过滤，不使用固定延迟掩盖错误。

**Step 4: Preserve position across preview replacement and explicit navigation**

预览 replaceContent 前记录当前分栏主导端锚点，完成后只恢复同一内容版本的锚点。大纲和查找的既有 SourceScrollRequest 仍保留各自 placement 语义；分栏状态下将同一显式请求广播到两栏，不以持续同步覆盖显式跳转。

**Step 5: Run tests**

Run: swift test --filter SplitEditingCoordinatorTests && swift test --filter WebViewRenderSchedulerTests

Expected: PASS。

### Task 5：完整回归与 GUI 验收

**Files:**

- Modify if necessary: Tests/MarkdownReaderTests/SplitEditingCoordinatorTests.swift
- Modify if necessary: Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift

**Step 1: Automated verification**

Run:

~~~bash
swift test
swift build
swift build -c release
git diff --check
~~~

Expected: 四项均通过；swift test 不得有新增失败。

**Step 2: GUI matrix**

在简中、繁中、英文各检查设置页分段控件左缘无空白。再以长 Markdown（标题、表格、长代码块、图片/链接）验证：

1. 默认关闭、Markdown Raw、Markdown Rendered、txt Raw 的现有行为不变。
2. 开启分栏后，左 Raw/右 Rendered 都非空；拖拽到左右极限、再改变窗口大小，面板不重叠或为负宽。
3. 左滚右跟、右滚左跟均落在同一源码块；连续拖动滚动条、快速交替两侧滚动，不来回震荡。
4. 分栏输入、停顿、快速连续输入、文件切换、开关分栏、Raw ↔ Rendered 切换、关闭窗口均不白屏、不崩溃、不显示旧文档。
5. 左右 copy icon 分别在各自右上角；左复制原文，右复制富文本；查找栏显示时图标行为与单栏既有规则一致。
6. 大纲、查找、PDF 导出、外部文件 reload、文档末尾连续输入与既有 per-file undo 无回归。

**Step 3: Scope review**

确认 diff 不包含 Quick Look、PDF 导出协议、Markdown 渲染 HTML 结构、用户文档、tag/Release 或不相关编辑器高亮逻辑。若发现双 WebView、共享 exportedPage、像素同步或用固定 sleep 消除回环，停止并回到 Task 3/4 修正设计。

## 四、验收标准

- 用户可在设置中选择默认分栏编辑，默认值为关闭，现有用户未设置时行为不变。
- 一个窗口始终只有一个主内容 WebView；分栏和正常渲染复用它，PDF 仍只读取既有导出页面引用。
- 分栏左右宽度可拖动，Raw undo、语法高亮、复制、查找和单栏模式不退化。
- 双向跟随以相同源码位置/块为准，允许不同视图的视觉 Y 不一致；无回环、无抢滚、无光标跳动。
- 全部自动化命令与 GUI 矩阵通过后，才可宣称功能完成。

## 五、回滚

将功能拆分为设置/纯协调器、单 WebView 布局、持续同步三个可审查提交。任一阶段出现 WebView 生命周期崩溃、旧内容、空白页、编辑输入延迟、滚动震荡或复制语义错误，即回滚该阶段提交；保留已验证的 SyntaxHighlightedEditor 末尾滚动保护，不通过恢复 v2.3.0 分栏代码解决问题。


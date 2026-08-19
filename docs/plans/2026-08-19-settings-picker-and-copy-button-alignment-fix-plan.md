# 设置分段控件与内容复制按钮对齐修复 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** 消除“默认显示模式”分段控件的左侧空隙，并让 Rendered 与 Raw 模式右上角内容复制按钮的可见图标在同一视觉右缘对齐。

**Architecture:** 两项都是局部呈现层布局修复，不改变设置持久化、显示模式切换、复制内容、复制反馈或 SF Symbol 栅格化。设置页隐藏无语义的空 Picker 标签；Rendered 按钮仍在 WebView 内，仅以 8px 滚动条宽度补偿右侧定位，匹配 Raw 侧外层 SwiftUI overlay 的 11pt 内距。

**Tech Stack:** Swift 6、SwiftUI、AppKit segmented Picker、WebPage/WebKit、CSS、XCTest、Swift Package Manager。

---

## 一、根因与修复边界

### 1. 默认显示模式分段控件左侧空隙

[SettingsView.swift](Sources/MarkdownReader/Views/SettingsView.swift) 的默认显示模式使用 `Picker("", ...)`。空字符串依旧是标签视图；macOS 的 `.segmented` style 在没有 `.labelsHidden()` 时仍可能为标签及控件间距保留布局空间。Quick Look 复制格式的同类 Picker 已使用 `.labelsHidden()`，可作为同页先例。

只在默认显示模式的 Picker 上加 `.labelsHidden()`。保留 200pt 宽度、`$settings.defaultDisplayMode` binding、枚举 tag 和三语文案。

### 2. Rendered / Raw 内容复制按钮右缘不一致

Raw 侧按钮由 `DetailView` 的 `.overlay(alignment: .topTrailing)` 承载，24×24pt 点击区通过 `.padding(.trailing, 11)` 定位。Rendered 侧 `.mr-document-copy-btn` 位于 WebKit 滚动页面内，虽然也使用 `right: 11px`，但页面有固定 8px 的 WebKit 滚动条，导致相对 Detail 物理右缘额外留出约 8px。

仅将 Rendered 侧的 `right` 从 `11px` 改为 `3px`（11 − 8）。保留 `top: 3px`、24×24px 点击区、14×14px CSS mask glyph、颜色、成功态、五秒反馈、查找栏隐藏与打印隐藏规则。

## 二、不变量与不包含

### 不变量

- `SettingsModel.defaultDisplayMode` 的读写、默认值与实际模式切换不变。
- 两种模式的剪贴板内容、成功后对号、五秒复位、无障碍标签与 tooltip 不变。
- `SFSymbolWebImageProvider` 的 11pt 原生图标、14pt 透明画布和缓存版本不变。
- 顶部路径复制、代码块复制、查找栏、大纲与正文 padding 不变。

### 不包含

- 不重构 `SettingsSection`、设置页容器、本地化键或设置模型。
- 不把 Rendered 复制按钮迁移到 SwiftUI overlay；这会扩大 WebView 与复制状态的跨层边界。
- 不修改 `scroll.css` 的滚动条宽度或系统滚动条策略。
- 不做图标重绘、CSS transform、mask-size 调整或图标缓存失效。
- 不新增源码字符串断言、截图像素断言或当前坐标常数断言。当前没有适合此布局的 macOS UI test target；视觉差异必须由真实 GUI 验收。

## 三、实施任务

### Task 1：冻结回归基线（RED）

**Files:**

- Modify: 无。
- Test: `Tests/MarkdownReaderTests/CopyFeedbackStateTests.swift`（仅执行，确认复制状态基线）。
- Verify: `Sources/MarkdownReader/Views/SettingsView.swift:51-61`、`Sources/MarkdownReader/Resources/css/markdown.css:375-394`、`Sources/MarkdownReader/Views/DetailView.swift:764-785`。

**Step 1: 运行既有复制状态测试**

Run:

~~~bash
swift test --filter CopyFeedbackStateTests
~~~

Expected: PASS；视觉修改不得破坏成功态、重置或失效语义。

**Step 2: 在真实应用中记录两个失败现象**

Run:

~~~bash
swift run MarkdownReader
~~~

1. 打开“设置 → 通用”，确认“默认显示模式”的“渲染 / 编辑”分段控件相对区段标题存在左侧缩进。
2. 打开一份足以显示滚动条的长 Markdown，开启“内容一键复制”，在 Raw 与 Rendered 之间切换，确认 Rendered 侧图标相对 Detail 的物理右缘比 Raw 多让出约 8px。

Expected: 两项都稳定复现。这是布局问题的 RED 基线；不可用无 UI 行为的源码断言替代。

### Task 2：隐藏默认显示模式 Picker 的空标签

**Files:**

- Modify: `Sources/MarkdownReader/Views/SettingsView.swift:55-60`
- Test: 无新增自动化测试；运行 Task 1 的 GUI 场景与全量测试。

**Step 1: 写出最小实现**

在 `.pickerStyle(.segmented)` 后加 `.labelsHidden()`：

~~~swift
Picker("", selection: $settings.defaultDisplayMode) {
    Text(L10n.tr(.displayModeRendered, language: language)).tag(DisplayMode.rendered)
    Text(L10n.tr(.displayModeRaw, language: language)).tag(DisplayMode.raw)
}
.pickerStyle(.segmented)
.labelsHidden()
.frame(width: 200)
~~~

不得新增 wrapper、Spacer 或额外 padding。

**Step 2: 编译并确认 GREEN**

Run:

~~~bash
swift build
swift run MarkdownReader
~~~

Expected:

- 构建成功。
- 分段控件左缘与“默认显示模式”标题左缘对齐，200pt 总宽度不变。
- 两个选项均能修改默认显示模式，重启后设置仍保留。
- 中文、繁中、英文下界面语言菜单、Quick Look Picker 和其他 Toggle 没有位移或截断。

### Task 3：补偿 Rendered 按钮的 WebKit 滚动条占位

**Files:**

- Modify: `Sources/MarkdownReader/Resources/css/markdown.css:375-394`
- Test: `Tests/MarkdownReaderTests/CopyFeedbackStateTests.swift`（仅执行）；真实 GUI 验收。

**Step 1: 修改唯一定位常数**

将：

~~~css
right: 11px;
~~~

改为：

~~~css
/* 11px Raw 外层内距 - 8px WebKit scrollbar，落在同一物理右缘。 */
right: 3px;
~~~

不得修改同一规则中的 `top`、尺寸、`z-index`、颜色或 transition；也不得调整 14px mask glyph。

**Step 2: 执行状态回归测试**

Run:

~~~bash
swift test --filter CopyFeedbackStateTests
~~~

Expected: PASS。

**Step 3: 在真实 WebView 中验收 GREEN**

Run:

~~~bash
swift run MarkdownReader
~~~

使用同一长 Markdown 验证：

1. Rendered 与 Raw 的可见 glyph 右缘视觉对齐；Rendered 不再额外让出滚动条宽度。
2. 点击区仍为 24×24，两侧均在右上角，无遮挡正文、标题栏或大纲。
3. 两侧复制成功后均显示成功图标，约五秒后恢复；剪贴板内容正确。
4. 打开查找栏时按钮隐藏且不可点击；关闭后恢复。
5. 浅色/深色、窗口缩放与打印预览下，颜色、点击与“打印时隐藏”均无回归。

### Task 4：全量验证与交付

**Files:**

- Verify only: 本任务涉及的两处源文件、测试和工作区差异。

**Step 1: 执行自动验证**

Run:

~~~bash
swift test
swift build
git diff --check
git diff -- Sources/MarkdownReader/Views/SettingsView.swift Sources/MarkdownReader/Resources/css/markdown.css
~~~

Expected: `swift test` 与 `swift build` 成功，`git diff --check` 无输出；差异仅包含 `.labelsHidden()` 与 `right: 3px` 的 8px 补偿注释。

**Step 2: 交付前 GUI 复核**

逐项复跑 Task 2 与 Task 3 的中文、繁中与英文矩阵。任一语言存在左侧缩进、两模式右缘不一致、复制失败或查找栏遮挡，即视为未完成。

**Step 3: 提交（仅在用户明确要求时）**

先检查工作区，确保未跟踪的其他 `docs/plans/` 文件没有混入；仅暂存本任务源文件与实际新增的测试文件：

~~~bash
git add Sources/MarkdownReader/Views/SettingsView.swift Sources/MarkdownReader/Resources/css/markdown.css
git commit -m "fix: align settings picker and copy buttons"
~~~

## 四、回滚

若默认显示模式的可访问性、焦点或切换异常，只回滚新增的 `.labelsHidden()`。

若某个 WebKit 或系统滚动条配置下 Rendered 按钮仍不对齐，只回滚或重新校准 `.mr-document-copy-btn` 的 `right` 常数。不得回滚已经验证的图标比例修复、复制状态机、滚动条样式或整个 WebView 页面；复核以可见 glyph 的右缘为准，而不是 24×24 点击区边缘。


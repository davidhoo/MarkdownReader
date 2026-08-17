# 渲染模式复制图标比例修复实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 修复渲染模式内容复制按钮的 `doc.on.doc` / `checkmark` 被拉伸为 14 × 14 正方形的问题，使其与编辑模式 11 pt 原生 SF Symbol 的原始比例和视觉重量一致。

**Architecture:** 编辑模式继续由 SwiftUI `Image(systemName:)` 以 11 pt SF Symbol 绘制，并放在 14 pt 可见画布、24 pt 点击区中。渲染模式继续复用现有 SF Symbol → 透明 PNG → CSS mask 数据流；只修改 `SFSymbolWebImageProvider` 的绘制矩形，使配置后的 `NSImage` 以其固有尺寸居中绘制到 14 pt 透明画布，而非被强制缩放到正方形。WebView 页面、CSS mask 尺寸、按钮定位及复制行为都不改。

**Tech Stack:** Swift 6、SwiftUI、AppKit `NSImage` / `NSBitmapImageRep`、WebKit CSS mask、XCTest、Swift Package Manager

---

## 背景与根因

两个模式默认态均使用 `DocumentCopySymbol.copy`（`doc.on.doc`）：

- 编辑模式在 `DetailView` 以 `.font(.system(size: 11))` 绘制原生 SF Symbol，再用 `.frame(width: 14, height: 14)` 提供可见画布；符号自身的宽高比例不变。
- 渲染模式在 `SFSymbolWebImageProvider.rasterize(symbol:scale:)` 中也创建了 `NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)`，但随后将该图像绘制到 `NSRect(x: 0, y: 0, width: 14, height: 14)`。

`doc.on.doc` 的配置后固有尺寸不是正方形。后者的 `draw(in:)` 会为填满该正方形重采样图像，得到的 PNG alpha mask 随后又被 CSS 的 `mask-size: 14px 14px` 显示，因此渲染模式看起来被压扁。现有测试只验证 PNG 画布为 14 × 14、存在 alpha 和缓存行为，没有验证 alpha 图形保留原生比例，未能捕获此回归。

## 修复合同

- 渲染模式默认态 `doc.on.doc` 与成功态 `checkmark` 都必须使用 11 pt、Regular 的 SF Symbol 原始尺寸与比例；两者在 14 pt 透明 PNG 画布中水平、垂直居中。
- PNG 画布仍保持 14 × 14 pt（1× 为 14 × 14 px，2× 为 28 × 28 px），以兼容现有 CSS `.mr-document-copy-glyph { width/height: 14px; mask-size: 14px 14px; }`。
- 保留 `DocumentCopyWebIcons` 的 data URL 合同、CSS custom properties、cache key、缓存失败降级、`@MainActor` 限制和颜色由 `currentColor` 提供的机制。
- 不修改 `WebViewMarkdownView`、`MarkdownHTMLService`、`markdown-reader.js`、`markdown.css` 或 `DetailView`；它们已有的 24 × 24 点击区、可见位置、hover / 成功色、tooltip、5 秒反馈与复制语义不属于本修复。
- 不以手写 SVG、图标资源、CSS `transform` 或非等比 CSS `mask-size` 作为补丁；比例必须在 PNG 源头被保留。

## 实施任务

### Task 1：先锁定“14 pt 画布内的原始比例”回归测试

**Files:**

- Modify: `Tests/MarkdownReaderTests/SFSymbolWebImageProviderTests.swift:16-59`

**Step 1: 增加失败的原始比例测试**

在 `SFSymbolWebImageProviderTests` 添加一个只用于测试的原生参考绘制 helper：

1. 用 `NSImage(systemSymbolName:accessibilityDescription:)` 创建 `DocumentCopySymbol.copy` 与 `.copied`；
2. 对每个图标应用 `NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)`；
3. 把配置后图像以 `configured.size`（不缩放）居中绘制到 14 pt 透明 bitmap；
4. 扫描实际 provider 输出 PNG 与参考 bitmap 的非透明 alpha 边界；断言每个边界的 `x`、`y`、`width`、`height` 都一致。

测试名建议为：

```swift
func testRasterizedSymbolsMatchNativeElevenPointAspectAndCentering()
```

参考 helper 必须独立于生产的 `rasterize` 实现，避免测试与实现错误地共享同一个正方形 `drawRect`。不要比较完整 PNG 或像素哈希，因为 SF Symbol 的抗锯齿和轮廓会随 macOS 更新；本测试只冻结本机原生图像的 alpha 外接边界（比例、大小、居中），即本修复的可观察合同。

保留现有 `testOneXBitmapIs14x14WithAlpha`、`testTwoXBitmapIs28x28WithAlpha` 和缓存测试：它们仍分别覆盖透明画布大小和缓存语义。

**Step 2: 运行并确认测试在现状失败**

Run:

```bash
swift test --filter SFSymbolWebImageProviderTests/testRasterizedSymbolsMatchNativeElevenPointAspectAndCentering
```

Expected: FAIL。当前实现把 provider 图像以 14 × 14 绘制，alpha 边界会与参考的 11 pt 原生图像边界不一致。若测试在修改生产代码前通过，先检查参考 helper 是否错误地也使用了 `NSRect(width: 14, height: 14)` 作为 `draw(in:)` 目标。

**Step 3: Commit the regression test**

```bash
git add Tests/MarkdownReaderTests/SFSymbolWebImageProviderTests.swift
git commit -m "test: cover rendered copy icon aspect ratio"
```

### Task 2：按配置后固有尺寸居中栅格化 SF Symbol

**Files:**

- Modify: `Sources/MarkdownReader/Services/SFSymbolWebImageProvider.swift:23-33, 130-188`

**Step 1: 失效旧 PNG 缓存并修正文档注释**

将 `configurationVersion` 从 `1` 递增到 `2`，因为同一 symbol / scale 的二进制 PNG 输出和视觉合同均已变化；更新相邻注释，明确配置包含“11 pt 原始图像尺寸居中于 14 pt 画布”，而不是把符号缩放成 14 pt 正方形。

**Step 2: 用图像固有尺寸构造居中的 draw rect**

在取得 `configured` 后读取其 `size`，并先验证 width / height 均为有限正数。无效尺寸时记录与现有 rasterizer 一致的错误日志并返回 `nil`，让外层走已存在的 `.unavailable` 失败缓存。

替换当前的固定 draw rect：

```swift
let drawRect = NSRect(x: 0, y: 0, width: points, height: points)
configured.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
```

为：

```swift
let intrinsicSize = configured.size
let drawRect = NSRect(
    x: (points - intrinsicSize.width) / 2,
    y: (points - intrinsicSize.height) / 2,
    width: intrinsicSize.width,
    height: intrinsicSize.height
)
configured.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
```

不增加任何二次缩放或 aspect-fit 逻辑：此处的 `configured.size` 就是与编辑模式 `.font(.system(size: 11))` 对齐的唯一原生尺寸来源。保持 `bitmap.size = NSSize(width: points, height: points)`、离散屏幕倍率、PNG data URL 和 alpha-only 绘制路径不变。

**Step 3: 运行聚焦测试并确认转绿**

Run:

```bash
swift test --filter SFSymbolWebImageProviderTests
```

Expected: PASS。新增测试证明 `doc.on.doc` / `checkmark` 的 alpha 外接边界与 11 pt 原生参考一致；既有测试证明 1× / 2× 画布和缓存合同未变。

**Step 4: Commit the production fix**

```bash
git add Sources/MarkdownReader/Services/SFSymbolWebImageProvider.swift Tests/MarkdownReaderTests/SFSymbolWebImageProviderTests.swift
git commit -m "fix: preserve rendered copy symbol aspect ratio"
```

### Task 3：端到端构建与人工视觉验收

**Files:**

- Verify: `Sources/MarkdownReader/Services/SFSymbolWebImageProvider.swift`
- Verify: `Sources/MarkdownReader/Views/DetailView.swift:691-715`
- Verify: `Sources/MarkdownReader/Resources/css/markdown.css:374-432`

**Step 1: 运行完整自动验证**

Run:

```bash
swift test
swift build
git diff --check
```

Expected: `swift test` 与 `swift build` 均以退出码 0 完成；`git diff --check` 无输出。

**Step 2: 在真实应用中对照两个模式**

打开同一份 Markdown，在浅色、深色主题中各完成一次：

1. 在渲染模式观察右上角默认 `doc.on.doc`，再切至编辑模式对照同一位置的原生图标；两个图标的横纵比例、视觉重量和居中位置应一致，渲染模式不能再显得纵向被压扁。
2. 分别点击两个按钮，确认渲染模式复制富文本、编辑模式复制原始 Markdown，且成功态的 `checkmark` 也保持正常比例并显示绿色 5 秒。
3. 打开查找栏确认按钮仍隐藏；关闭后恢复。打印或 PDF 导出时确认渲染按钮仍不会出现在输出中。
4. 目测确认透明点击区仍为 24 × 24，按钮定位仍为 `top: 3/right: 11` 的外框，且无新增背景、边框或阴影。

## 验收标准

- 渲染与编辑模式的内容复制 icon 均为同一 11 pt 原生 SF Symbol 的未拉伸形状；默认态和成功态都一致。
- 渲染模式仍通过 14 × 14 pt PNG + CSS mask 显示图标，24 × 24 点击区与现有位置、颜色和无障碍提示不变。
- `SFSymbolWebImageProviderTests` 中存在先失败后通过的原生比例回归测试；画布尺寸、data URL、alpha 与缓存测试继续通过。
- `swift test`、`swift build`、`git diff --check` 均成功。

## 回滚

若真实设备上发现某个系统版本的 `configured.size` 异常，回滚本任务的两个提交即可恢复原来的 14 × 14 强制绘制；不会涉及持久化、迁移、网络或用户数据。不要通过修改 CSS `mask-size` 掩盖问题，因为这样会让 WebKit 图标与原生编辑模式再次偏离。

## 不包含

- 不改动编辑模式、标题栏路径复制按钮或代码块复制按钮。
- 不改动渲染复制的富文本选区逻辑、编辑复制的 `NSPasteboard` 行为、五秒成功状态、查找栏避让或本地化文案。
- 不改动 WebView reload / render scheduler、Markdown HTML、Quick Look、PDF 导出、主题、设置、资源打包或发布版本。
- 不引入手写 SVG、图标资源、第三方依赖、CSS 变形或新的 Web-to-native 通信。

# WebKit 内容复制按钮复用 SF Symbols 实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让渲染模式内容区右上角的复制/成功图标使用与原生顶部路径按钮相同的 SF Symbols（doc.on.doc / checkmark），并以每个屏幕倍率仅一次的运行时导出和缓存提供给 WebKit，不改变复制语义或既有轻量按钮样式。

**Architecture:** 原生 SwiftUI 继续用 Image(systemName:) 显示 SF Symbol。新增只在主 App 使用的 @MainActor 提供者，将配置为 11 pt、Regular 的系统符号栅格化为 14 pt 透明 PNG，并按屏幕倍率缓存成 data URL。WebViewMarkdownView 只在整页加载时取得缓存结果，传给 MarkdownHTMLService 写入 HTML 根节点 CSS 变量；WebKit 以 CSS mask 显示，并通过 currentColor 继承主题和成功态颜色。正文增量替换与五秒成功状态只切换 CSS class，绝不重新导出图标或重建页面。

**Tech Stack:** Swift 6、SwiftUI、AppKit NSImage / NSBitmapImageRep、WebKit WebPage、JavaScript、CSS mask、XCTest、Swift Package Manager

---

## 背景与问题

顶部路径复制按钮和编辑模式内容复制按钮均使用原生 SF Symbol：

~~~
Image(systemName: "doc.on.doc")
    .font(.system(size: 11))
    .frame(width: 14, height: 14)
~~~

渲染模式位于 WebKit DOM，无法调用 SwiftUI 的 Image(systemName:)；当前 markdown-reader.js 因而维护了独立的手写 SVG 路径。这是两处复制 icon 外形不一致的根因。

本任务不引入 Lucide、第三方图标库、静态 SVG 副本或 Web icon font。渲染模式将使用 macOS 当前系统产生的 SF Symbol alpha 图形，避免再维护第二套矢量路径。

## 目标合同

### 视觉与行为

- 三个相关入口共用两个 symbol name：默认态 doc.on.doc，成功态 checkmark。
- 顶部路径和编辑模式保留现有 11 pt、14 pt 可见尺寸、编辑模式 24 pt 透明点击区、位置、tooltip 与五秒反馈；仅替换重复的 symbol 字符串为共享常量。
- WebKit 图标不是普通 img，而是透明 PNG 的 alpha mask；颜色仍由现有 --fg-muted、--ink、--success 和 currentColor 控制。
- 渲染模式维持 24 × 24 px 透明触控区、14 × 14 px glyph、top: 3px / right: 11px 的外框，以及无背景、无边框、无阴影的视觉。
- 渲染模式继续复制与全选复制相同的富文本；编辑模式继续复制 Markdown 原文。成功对号只在复制成功后显示 5 秒，连续点击从最后一次成功重新计时。

### 性能与并发

- 缓存键是 { 配置版本, backingScaleFactor }。配置包括两个 symbol、11 pt、Regular weight 和 14 pt 画布；倍率必须归一化为离散像素密度，不能直接以任意 CGFloat 作为 key。
- 对同一缓存键，最多栅格化 doc.on.doc 与 checkmark 各一次。首次 Retina 渲染只需两次小型 PNG 编码；文件切换、完整 reload、raw/rendered 切换、正文更新、点击与五秒复位全部命中缓存。
- 窗口移动到新倍率屏幕时只额外导出这一组；移回已见倍率必须命中已有缓存。
- AppKit 栅格化只在 @MainActor 发生。跨到 MarkdownReaderKit、HTML 和 WebKit 的值仅包含 Sendable String data URL，绝不传递 NSImage、NSBitmapImageRep 或 graphics context。
- 不新增 mr:// 动态 endpoint、磁盘资源或网络请求。replaceContent、theme CSS 更新、copy click 和 timer 都不得调用图标提供者。

### 降级

- doc.on.doc / checkmark 在目标最低系统 macOS 26 均可用。若任一系统图标或 PNG 编码意外失败，提供者记录一次错误并缓存失败结果；WebKit 不创建不可见的文档复制按钮。
- 降级不 crash、不阻断文档加载，也不以手写 SVG 或第三方 icon 静默回退。原生编辑入口和系统全选复制仍可用。
- PDF/打印页本来隐藏渲染复制按钮，继续使用默认的“无 Web 图标”值，不能为了 PDF 初始化 AppKit provider。

## 数据流

~~~text
DocumentCopySymbol (.copy / .copied)
  ├─ DetailView: Image(systemName:) ─────────────► 原生按钮
  └─ SFSymbolWebImageProvider (@MainActor)
       └─ cache[configuration, displayScale]
            └─ 14 pt alpha PNG data URLs
                 └─ WebViewMarkdownView.loadContent()
                      └─ MarkdownHTMLService.buildFullHTML()
                           └─ :root CSS variables
                                └─ markdown-reader.js glyph span
                                     └─ CSS mask + currentColor ─► WebKit 按钮
~~~

## 文件与职责

| 文件 | 改动 | 职责 |
|---|---|---|
| Sources/MarkdownReaderKit/Models/DocumentCopySymbol.swift | 新建 | 唯一维护 copy = "doc.on.doc"、copied = "checkmark"。 |
| Sources/MarkdownReaderKit/Models/DocumentCopyWebIcons.swift | 新建 | Sendable data URL 值对象，负责生成安全的 CSS custom-property 片段，不依赖 AppKit。 |
| Sources/MarkdownReader/Services/SFSymbolWebImageProvider.swift | 新建 | 主线程 SF Symbol → 透明 PNG → data URL，按倍率缓存成功与失败。 |
| Sources/MarkdownReader/Views/DetailView.swift | 修改 | 顶部路径与编辑复制按钮引用共享 symbol 常量，视觉/状态不变。 |
| Sources/MarkdownReader/Views/WebViewMarkdownView.swift | 修改 | 在整页 loadContent 获取缓存图标、传入页面壳；displayScale 变化时经既有 scheduler 请求 reload。 |
| Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift | 修改 | buildFullHTML 在 root style 中注入两个 mask data URL；PDF 调用保持默认 unavailable。 |
| Sources/MarkdownReader/Resources/js/markdown-reader.js | 修改 | 移除文档复制按钮的手写 SVG，改用 aria-hidden mask glyph 并切换默认/成功 class。 |
| Sources/MarkdownReader/Resources/css/markdown.css | 修改 | 定义 -webkit-mask 和标准 mask 样式，保留按钮颜色、定位与 24 px hit target。 |
| Tests/MarkdownReaderTests/DocumentCopyWebIconsTests.swift | 新建 | 覆盖页面壳的 data URL 注入和 unavailable 合同。 |
| Tests/MarkdownReaderTests/SFSymbolWebImageProviderTests.swift | 新建 | 覆盖 PNG data URL、1×/2× 尺寸与同倍率缓存复用。 |

## 实施任务

### Task 1：建立跨层图标数据合同

**Files:**

- Create: Sources/MarkdownReaderKit/Models/DocumentCopySymbol.swift
- Create: Sources/MarkdownReaderKit/Models/DocumentCopyWebIcons.swift
- Modify: Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift:50-102
- Create: Tests/MarkdownReaderTests/DocumentCopyWebIconsTests.swift
- Modify: Tests/MarkdownReaderTests/MarkdownHTMLServiceTests.swift

**Step 1: 先写失败测试**

在新测试中构造固定值：

~~~
let icons = DocumentCopyWebIcons(
    copyMaskDataURL: "data:image/png;base64,Y29weQ==",
    copiedMaskDataURL: "data:image/png;base64,Y2hlY2s="
)
~~~

调用 buildFullHTML(renderResult:...) 并断言：

- root style 同时包含 --mr-document-copy-icon 与 --mr-document-copied-icon；
- 变量完整包含上面的 data URL；
- DocumentCopyWebIcons.unavailable 时两个变量均不输出；
- DocumentCopySymbol.copy.rawValue 等于 doc.on.doc，copied.rawValue 等于 checkmark；
- 现有 buildFullHTML(content:...) PDF 便利入口仍可不传 Web 图标。

**Step 2: 确认测试失败**

Run:

~~~bash
swift test --filter DocumentCopyWebIconsTests
~~~

Expected: FAIL，提示 DocumentCopySymbol / DocumentCopyWebIcons 尚不存在，且页面壳没有该参数。

**Step 3: 实现最小模型与 HTML 注入**

实现公开的 Sendable、Equatable 模型：

~~~
public enum DocumentCopySymbol: String, Sendable {
    case copy = "doc.on.doc"
    case copied = "checkmark"
}
~~~

DocumentCopyWebIcons 只保存两个 data URL，并以显式 availability（或等价布尔值）表达“两个图标均有效”；禁止用空字符串伪装有效资源。它输出的 CSS 只能是：

~~~css
--mr-document-copy-icon: url("data:image/png;base64,...");
--mr-document-copied-icon: url("data:image/png;base64,...");
~~~

在两个 buildFullHTML overload 增加默认参数 documentCopyWebIcons: .unavailable，便利入口必须完整转发。只有 available 时才将变量拼入现有 :root style；不得改变 theme style id、脚本顺序、正文 HTML、title data attribute 或 content padding/max width 变量。

**Step 4: 运行聚焦验证**

Run:

~~~bash
swift test --filter DocumentCopyWebIconsTests
swift test --filter MarkdownHTMLServiceTests
~~~

Expected: PASS；Kit 层不引入 AppKit 或 WebKit 依赖。

**Step 5: Commit**

~~~bash
git add Sources/MarkdownReaderKit/Models/DocumentCopySymbol.swift Sources/MarkdownReaderKit/Models/DocumentCopyWebIcons.swift Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift Tests/MarkdownReaderTests/DocumentCopyWebIconsTests.swift Tests/MarkdownReaderTests/MarkdownHTMLServiceTests.swift
git commit -m "feat: define web document copy icon contract"
~~~

### Task 2：实现 SF Symbol 的一次性栅格化与倍率缓存

**Files:**

- Create: Sources/MarkdownReader/Services/SFSymbolWebImageProvider.swift
- Create: Tests/MarkdownReaderTests/SFSymbolWebImageProviderTests.swift

**Step 1: 写失败测试**

在 @MainActor XCTest 覆盖：

1. 对 1×、2× 请求 documentCopyWebIcons(displayScale:) 后，两个 URL 都以 data:image/png;base64, 开头；
2. Base64 解码后以 NSBitmapImageRep 验证两个图像有 alpha，且逻辑 14 pt 画布分别输出 14 × 14 和 28 × 28 像素；
3. 对同一归一化倍率连续请求两次，注入式 rasterizer 仅执行一个批次（两张符号），两次结果相等；
4. 不同倍率各导出一次，回到已缓存倍率不再执行 rasterizer。

不得比较 PNG 像素哈希，因为系统可在不同 macOS 版本更新 SF Symbol 的精确轮廓。

**Step 2: 确认测试失败**

Run:

~~~bash
swift test --filter SFSymbolWebImageProviderTests
~~~

Expected: FAIL，提示提供者尚不存在。

**Step 3: 实现提供者**

实现 @MainActor 的 SFSymbolWebImageProvider：

- 使用 DocumentCopySymbol.copy / .copied 构造 NSImage(systemSymbolName:accessibilityDescription:)；禁止再写 symbol name 字面量；
- 使用 NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)，在 14 pt 透明画布中居中绘制；
- 按 normalizedDisplayScale 生成像素 bitmap，保留 alpha，PNG 编码后生成 data URL；
- 图片始终是未着色模板 alpha；颜色只能由 WebKit 的 currentColor 决定；
- Dictionary<CacheKey, Result> 缓存成功结果与失败哨兵。CacheKey 必须包含配置版本和离散倍率；以后调整图标、11 pt、weight 或 14 pt 画布时要更新配置版本；
- 通过 internal 的 rasterizer 注入 seam 让缓存次数可以单测。生产使用真实 AppKit rasterizer，测试以计数 closure 返回固定值；不得向产品设置暴露测试 hook；
- 任一固定系统图标或 PNG 编码失败时，使用 Logger 记录一次、缓存 unavailable，并返回 unavailable，不能 crash 或反复尝试。

**Step 4: 运行测试和构建**

Run:

~~~bash
swift test --filter SFSymbolWebImageProviderTests
swift build
~~~

Expected: PASS，且 Swift 6 严格并发下无 Sendable / actor-isolation 警告。

**Step 5: Commit**

~~~bash
git add Sources/MarkdownReader/Services/SFSymbolWebImageProvider.swift Tests/MarkdownReaderTests/SFSymbolWebImageProviderTests.swift
git commit -m "feat: cache sf symbols for web document copy"
~~~

### Task 3：只在整页加载时把缓存结果交给 WebKit

**Files:**

- Modify: Sources/MarkdownReader/Views/WebViewMarkdownView.swift:80-145, 291-321
- Modify: Sources/MarkdownReader/Views/DetailView.swift:196-212, 692-715
- Modify: Tests/MarkdownReaderTests/MarkdownHTMLServiceTests.swift

**Step 1: 让倍率变化走既有渲染调度**

在 WebViewMarkdownView 读取 SwiftUI displayScale environment，并增加 onChange。变化时只能调用已有 requestRender()，不能绕过 latest-wins scheduler 直接 page.load。

**Step 2: 仅在 loadContent 获取图标**

在 loadContent(_:) 中 MarkdownHTMLService.render 之后、buildFullHTML 之前调用：

~~~
let documentCopyWebIcons = SFSymbolWebImageProvider.shared.documentCopyWebIcons(
    displayScale: displayScale
)
~~~

将其只传给 buildFullHTML(renderResult:...)。replaceContent、updateThemeCSS、copy click、5 秒 timeout 和 MarkdownURLSchemeHandler 均不得调用提供者。

**Step 3: 让原生端也引用同一 symbol 常量**

将 DetailView 顶部路径和编辑内容按钮的状态分支改为共享常量，例如：

~~~
Image(systemName: contentCopyState.isShowingSuccess
    ? DocumentCopySymbol.copied.rawValue
    : DocumentCopySymbol.copy.rawValue)
~~~

保留 font(.system(size: 11))、14 pt visual frame、编辑模式 24 pt hit target、padding、tooltip、CopyFeedbackState 和五秒任务逻辑。

**Step 4: 验证不破坏渲染边界**

Run:

~~~bash
swift test --filter WebViewRenderSchedulerTests
swift build
git diff -- Sources/MarkdownReader/Views/WebViewMarkdownView.swift Sources/MarkdownReader/Views/DetailView.swift
~~~

Expected: PASS；PDF 的 buildFullHTML(content:...) 仍用默认 unavailable，不能初始化提供者。

**Step 5: Commit**

~~~bash
git add Sources/MarkdownReader/Views/WebViewMarkdownView.swift Sources/MarkdownReader/Views/DetailView.swift Tests/MarkdownReaderTests/MarkdownHTMLServiceTests.swift
git commit -m "feat: inject cached sf symbols into rendered copy control"
~~~

### Task 4：以 CSS mask 替换渲染模式的手写 SVG

**Files:**

- Modify: Sources/MarkdownReader/Resources/js/markdown-reader.js:470-534
- Modify: Sources/MarkdownReader/Resources/css/markdown.css:372-421

**Step 1: 仅删除 document-copy 的内联 SVG**

删除 MR._documentCopyIcon、MR._documentCopiedIcon 及它们的 innerHTML 赋值。不得修改代码块复制 MR.addCopyButtons()，它有独立 icon、两秒反馈、复制逻辑和 hover 风格。

新增私有 helper，例如 MR.setDocumentCopyButtonIcon(button, isCopied)，让按钮只创建以下子节点：

~~~html
<span class="mr-document-copy-glyph mr-document-copy-glyph-copied" aria-hidden="true"></span>
~~~

helper 只能替换 glyph 子节点；不得改变 button type、id、title、aria-label、mr-document-copy-btn-copied 的颜色 class、计时器或 click listener。

**Step 2: 不创建不可见按钮**

创建 mr-document-copy-btn 前检查根节点的两个 CSS 图标变量是否同时存在。若 unavailable，跳过 append；setDocumentCopyButtonHidden、setDocumentCopyButtonLabels 和复制命令必须安全地处理“按钮不存在”。

**Step 3: 增加 mask 样式**

在现有 .mr-document-copy-btn 透明按钮规则下添加：

~~~css
.mr-document-copy-glyph {
  width: 14px;
  height: 14px;
  background-color: currentColor;
  -webkit-mask-image: var(--mr-document-copy-icon);
  -webkit-mask-repeat: no-repeat;
  -webkit-mask-position: center;
  -webkit-mask-size: 14px 14px;
  mask-image: var(--mr-document-copy-icon);
  mask-repeat: no-repeat;
  mask-position: center;
  mask-size: 14px 14px;
}

.mr-document-copy-glyph-copied {
  -webkit-mask-image: var(--mr-document-copied-icon);
  mask-image: var(--mr-document-copied-icon);
}
~~~

成功态继续由父按钮颜色 class 令 currentColor 变为 --success。不得增加 background、border、box-shadow、CSS filter、SVG asset 或静态 fallback。

**Step 4: 保留复制行为**

确认下列逻辑逐字不变：

- MR.copyRenderedContent() 的 selection、copy、finally 恢复；按钮保持在 #mr-content 外，不会被复制进内容；
- 真实成功后才显示对号，重复成功 clearTimeout 后重新启动 5000 ms；
- 查找栏打开时按钮无 hit target；打印/PDF 隐藏；
- 首载与语言切换后 title / aria-label 正确；
- 编辑 Markdown 复制、代码块复制及其两秒反馈不变。

**Step 5: 验证静态改动**

Run:

~~~bash
swift build
git diff --check
~~~

Expected: 成功且无 whitespace 错误；渲染模式 document-copy 路径不再包含内联 svg、rect、path 或 polyline。

**Step 6: Commit**

~~~bash
git add Sources/MarkdownReader/Resources/js/markdown-reader.js Sources/MarkdownReader/Resources/css/markdown.css
git commit -m "fix: render document copy icons from sf symbols"
~~~

### Task 5：端到端验收与缓存确认

**Files:**

- Verify: Sources/MarkdownReader/Services/SFSymbolWebImageProvider.swift
- Verify: Sources/MarkdownReader/Views/DetailView.swift
- Verify: Sources/MarkdownReader/Views/WebViewMarkdownView.swift
- Verify: Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift
- Verify: Sources/MarkdownReader/Resources/js/markdown-reader.js
- Verify: Sources/MarkdownReader/Resources/css/markdown.css
- Verify: Tests/MarkdownReaderTests/DocumentCopyWebIconsTests.swift
- Verify: Tests/MarkdownReaderTests/SFSymbolWebImageProviderTests.swift
- Verify: Tests/MarkdownReaderTests/CopyFeedbackStateTests.swift

**Step 1: 自动化验证**

Run:

~~~bash
swift test
swift build
git diff --check
~~~

Expected: 全部 PASS，git diff --check 无输出。

**Step 2: 缓存行为验证**

使用 provider 的 test seam 或仅调试期的一次性 diagnostics（提交前移除临时日志），按序验证：

1. 首次打开渲染模式：复制/对号各栅格化一次；
2. 连续编辑、整页 reload、raw/rendered 切换、重复复制：导出次数不增加；
3. 窗口移至不同倍率屏幕：只为新倍率导出两张；移回原屏幕：次数不增加。

不以微秒 wall-clock 阈值作为验收；正确标准是 cache miss/hit 次数，以及 replaceContent/click/timer 中没有 AppKit rasterization。

**Step 3: 人工视觉与交互验收**

在同一主题、文档和窗口对比顶部路径、编辑内容和渲染内容按钮：

- 三者默认态都是同一 SF Symbol 两张文档图形；渲染模式没有遗留手写 SVG 的比例、线宽或圆角差异；
- 两个内容按钮可见 glyph 都是 14 pt/px，且可见坐标均为 top: 8 / right: 16；24 pt/px 透明边缘区域可点击；
- 默认、hover、active、成功态均没有方块背景、边框或阴影，键盘 focus-visible 仍清晰；
- 渲染模式粘贴到富文本目标的结果与页面全选复制一致；编辑模式粘贴为原始 Markdown；成功态均显示绿色对号五秒；
- 查找栏、语言切换、深浅主题、PDF/打印和代码块复制均无回归。

**Step 4: 最终提交**

~~~bash
git add Sources/MarkdownReaderKit/Models/DocumentCopySymbol.swift Sources/MarkdownReaderKit/Models/DocumentCopyWebIcons.swift Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift Sources/MarkdownReader/Services/SFSymbolWebImageProvider.swift Sources/MarkdownReader/Views/DetailView.swift Sources/MarkdownReader/Views/WebViewMarkdownView.swift Sources/MarkdownReader/Resources/js/markdown-reader.js Sources/MarkdownReader/Resources/css/markdown.css Tests/MarkdownReaderTests/DocumentCopyWebIconsTests.swift Tests/MarkdownReaderTests/SFSymbolWebImageProviderTests.swift Tests/MarkdownReaderTests/MarkdownHTMLServiceTests.swift
git commit -m "fix: unify rendered copy icons with sf symbols"
~~~

## 完成标准

- 渲染模式文档复制按钮不再维护或渲染手写 SVG；默认与成功图形分别来自当前 macOS 的 doc.on.doc 与 checkmark SF Symbols。
- WebKit 用透明 PNG CSS mask 上色，保留主题颜色、成功绿色、14 px 图标、24 px 透明触控区及无背景/无边框视觉。
- 每个 { 配置版本, display scale } 只在首次请求时导出两个图标；正文增量更新、点击、计时、主题更新与 mr:// handler 均不会触发导出。
- 原生顶栏与编辑模式使用同一组 symbol name 常量，布局和复制行为不变。
- 富文本复制、Markdown 原文复制、五秒成功态、查找栏避让、PDF 隐藏、语言更新、代码块复制和渲染调度均无回归。
- swift test、swift build、git diff --check 均成功。

## 不包含

- 不引入 Lucide、Font Awesome、Web icon font、第三方依赖、静态 SVG/PDF/PNG asset 或网络图标服务。
- 不修改顶部路径按钮的位置、尺寸、按钮样式、tooltip、五秒反馈或复制路径语义。
- 不修改内容复制剪贴板格式、CopyFeedbackState、selection 恢复、raw 编辑器、菜单、快捷键或代码块复制。
- 不修改 Markdown 解析、Mermaid/KaTeX/Prism、MarkdownURLSchemeHandler、Quick Look、PDF 导出、主题定义、应用图标、版本或发布流程。


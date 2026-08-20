# Changelog

本项目的所有重要变更都会记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 已知遗留（后续处理）

- `ContentView.handleDeletedFileWithUnsavedChanges` 仍用 `NSAlert.runModal()`（应用级 modal，多窗口下阻塞所有窗口）；Save/SaveAs/ExportPDF 面板已改窗口级 sheet，但文件被外部删除的未保存确认 alert 尚未统一，待改为 `beginSheetModal(for: window)`
- `FileTreeViewModel.moveItem` 的 NSOpenPanel 仍用 `runModal()`，多窗口下阻塞，待改窗口级 sheet
- 菜单 nil target 禁用状态、PDF sheet 附着等需真实焦点环境的验证尚未覆盖（SwiftUI Commands 焦点读取无法用普通 XCTest 可靠覆盖），待补最小 UI harness
- 双窗口/多目录/最小化/全屏/关闭最后窗口重开等人工回归矩阵未执行，需 GUI 环境验证

## [2.4.2] - 2026-08-20

### 新增

- **Raw 编辑器可选源码行号**：设置 → 外观 → 字体与排版新增「显示源码行号」开关，默认关闭，不改变现有阅读布局。开启后在 Raw 左侧固定 gutter 显示逻辑源码行号；自动换行的后续 fragment 不重复编号；宽度按文档最大行号位数自适应，滚动时不抖动。行号栏以 Core Animation 覆盖层绘制，通过 text container inset 为文本让出左侧空间，不改写 `contentView.frame`（避免 SwiftUI 托管下内容不绘制）

### 测试

- 全部 275 个测试通过（v2.4.1 为 271 个；新增行号 gutter 宽度与 overlay 布局契约测试）

## [2.4.1] - 2026-08-19

### 修复

- **设置页"默认显示模式"分段控件左侧空隙**：`Picker("", ...)` 的空字符串标签仍占用布局空间，导致分段控件相对区段标题有左侧缩进。加 `.labelsHidden()` 隐藏无语义空标签，200pt 宽度不变，与同页语言菜单 Picker 一致
- **Rendered 内容复制按钮右缘与 Raw 不对齐**：Rendered 侧 `.mr-document-copy-btn` 使用 `right: 11px`，但 WebKit 固定 8px 滚动条导致物理右缘比 Raw 侧多让出约 8px。将 `right` 从 `11px` 改为 `3px`（11 − 8），两侧可见图标落在同一物理右缘

## [2.4.0] - 2026-08-19

### 新增

- **Raw ↔ Rendered 模式切换保持阅读位置**：切换渲染/原文模式时此前的整数行号定位会跳到行首、丢失行内阅读位置，长文档切换后常需重新滚动找回。改为基于小数源码位置的模式切换位置交接系统
  - 新增 `SourceScrollAnchor`（1-based 小数源码位置 + 全文滚动进度兜底，值域钳制不崩溃）与一次性 `ScrollTransfer`（目标模式 + UUID + `contentVersion` 三重校验，过期内容、过期模式或快速 A→B→A 切换产生的回调一律丢弃）
  - 新增 `SourceAnchorResolution` 纯策略：源码范围/DOM/Raw 排版任一可用时用精确小数位置定位，否则降级到全文进度兜底，两者都不可用时回到文档顶部
  - 渲染 HTML 为块级元素输出 `data-source-start`/`data-source-end` 完整源码闭区间；JS 新增 `captureSourceScrollAnchor` / `scrollToSourceScrollAnchor`，视口落于块间 CSS 留白时按相邻源码间隙插值，避免错误回退到文末
  - Raw 侧 `RawSourceScrollAnchor` 采样视口顶部小数位置（监听活跃 `NSScrollView` 的 `boundsDidChange`，100 ms 防抖，程序化跳转动画结束后补报一次），仅活跃编辑器可写回，隐藏常驻 Raw 不得覆盖 Rendered 状态，不动光标、不传像素 Y
  - `DetailView` 统一 Picker、菜单、快捷键进入主动采样 + token 保护管线；`WindowCommandTarget` 新增 `displayModeSwitchHandler` 路由到视图级管线
- **大纲导航统一顶部对齐**：大纲点击此前的落点 Raw 约 1/3 视口、Rendered 居中，视觉重心不一致，点击同一标题有明显跳变。现统一为目标标题距视口顶部约 12pt
  - 新增 `SourceScrollPlacement`（`.reveal` / `.outlineTop`）与带 UUID 身份的 `SourceScrollRequest`，区分大纲导航与查找定位的落点意图；查找等既有跳转仍走 `.reveal`，保持原有 Raw 约 1/3、Rendered 居中体验不变
  - `DocumentViewModel` 新增 `requestOutlineScroll(to:)`，Raw 端提取 `SourceLineNavigationGeometry` 纯几何函数按 placement 计算 origin 并钳制
  - 大纲定位保留平滑动画，Raw 与 Rendered 动画时长统一为 0.25 秒 `easeOut`；Rendered 用当前 `zoomLevel` 将 12pt 转成 CSS 像素后传入 JavaScript，避免缩放时边距随网页缩放变形
  - 每次大纲点击都带新请求身份，连续点击同一标题也重新触发定位；不移动 Raw 光标/选区

### 修复

- **模式切换后旧显式滚动请求覆盖锚点交接的竞态**：大纲导航后从 Rendered 切到 Raw，此前会先正确落位再跳回大纲标题位置（先对后错）
  - `ExplicitScrollRequestExecutionPolicy` 保证同一请求 UUID 在一个视图端最多调度一次，执行已调度闭包前二次验证（当前 Raw 仍活跃且 `scrollToSourceLineRequest?.id` 匹配），模式切换清空请求后所有已排队旧闭包自动失效
  - Rendered 端新增 `RenderedExplicitScrollRequestPolicy` 与 `RenderedLineNavigationBridge`，pending 请求在取消、模式变化或内容替换时丢弃；`isRenderedMode` didSet 清除不兼容 pending
- **渲染模式切换闪现空白或旧渲染内容**：Raw → Rendered 切换期间 WebView 内容替换未完成就让用户看到中间状态
  - 新增 `RenderedModeTransitionState` 纯状态机：Raw → Rendered 切换第一步立即要求 Raw 保持可见挡住 WebView，只有目标渲染世代完成**且** `ScrollTransfer` 回执后 Raw 才退场
  - 新增 `WebViewContentReplacementCompletionPolicy`：只有 `MR.replaceContent` 返回显式 `true` 且世代仍为最新请求时才报告完成（`false`/`nil`/非 Boolean/过期世代一律不完成），避免 DOM 未真正替换时结束过渡层
- **编辑器末尾滚动抖动**：长文档末尾连续回车、新增行或跳转最后一行时，插入点可能被挤出可见区域并与滚动位置相互拉扯。改为在文档底部保留约一行高度的空间，确保插入点始终可见，消除末尾编辑时的滚动跳动
- **JavaScript 最近块兜底分支 TypeError**：`scrollToLine` 最近 `data-line` 兜底分支存在不可重新赋值的 `let` 变量重赋值，已修复

### 变更

- **统一源码行坐标契约**：新增 1-based `SourceLine` 值类型（`oneBased` / `zeroBasedIndex` 双视图，非法输入触发 `precondition`），统一大纲源码行号契约。`OutlineItem.lineNumber` 替换为 `sourceLine: SourceLine`，`OutlineService` 用 `zeroBasedIndex` 构造（ATX + Setext 块均覆盖），禁止裸 `Int` 传递行号，避免 0-based 数组索引与 1-based 行号混用导致的偏差
- **WebView 渲染闸门细化**：新增 `WebViewRenderEligibility` 区分 content / fileURL / contentVersion / displayMode 四类文档输入变更，仅 Rendered 模式才对纯内容编辑请求隐藏常驻 WebView 重渲染（Raw 编辑时隐藏 WebView 保持上次已应用快照，不随每次击键重渲染）

### 测试

- 全部 271 个测试通过（v2.3.2 为 196 个，新增约 75 个）
- 新增 `SourcePositionSyncTests`：覆盖 `SourceScrollAnchor` / `ScrollTransfer` 生命周期与 contentVersion 校验、源码闭区间映射、Raw 视口采样与定位、命令路由、小数锚点交接、显式请求取消与单次调度、真实 AppKit 布局定位
- 新增 `SyntaxHighlightedEditorScrollTests`：覆盖编辑器末尾滚动抖动修复与大纲导航几何计算
- 扩展 `WebViewRenderSchedulerTests`：覆盖渲染模式过渡状态机、隐藏 WebView 内容渲染闸门、显式替换完成回执策略
- 新增 `WindowCommandTargetTests`：覆盖模式切换路由到视图级管线

## [2.3.2] - 2026-08-17

### 修复

- **渲染模式复制图标比例失真**：渲染页右上角的一键复制图标（SF Symbol 光栅化后注入 WebView）此前绘制时被强制塞进 14×14 正方形，符号原始纵横比被拉伸变形。改为以 11 pt 配置后的固有尺寸居中绘制于 14 pt 透明画布，不再强制成正方形，保留 SF Symbol 原始比例，与编辑模式 `.font(.system(size: 11))` 的原生尺寸来源对齐。`configurationVersion` 递增至 2 以失效旧缓存

## [2.3.1] - 2026-08-17

### 修复

- **回退编辑模式分栏预览**：撤回 v2.3.0 引入的 Raw 编辑左右分栏实时预览、默认分栏设置及末尾滚动改动，恢复到 v2.2.10 的稳定编辑与渲染行为。v2.3.1 保持更高版本号，确保已升级到 v2.3.0 的用户可通过应用内更新恢复稳定版本。

## [2.3.0] - 2026-08-17

> 此版本因编辑模式分栏预览相关问题已撤回；请使用 v2.3.1。

### 新增

- **编辑模式左右分栏实时预览**：Raw 编辑模式可在标题栏用「切换分栏预览」按钮开关左右分栏，左栏编辑原文、右栏同步显示渲染结果，不再需要切换到渲染模式才能看到效果。预览在停止输入约 200 ms 后更新，连续快速输入不会触发反复重渲染
  - 设置页「显示」分区新增「编辑时默认分栏」开关：开启后，默认显示模式为 Raw 时新窗口进入编辑即默认分栏；开关关闭或在标题栏手动关闭后遵从当前选择，默认关闭、不覆盖已有用户值
  - `.txt` 纯文本模式不显示分栏按钮；Rendered 模式下分栏按钮不出现

### 修复

- **编辑器末尾滚动抖动**：在长文档末尾连续回车、新增行或跳转到最后一行时，此前插入点可能被挤出可见区域、并与滚动位置相互拉扯。改为在文档底部保留约一行高度的空间，确保插入点始终可见，消除末尾编辑时的滚动跳动

## [2.2.10] - 2026-08-13

### 修复

- **Quick Look 复制格式标签换行**：设置页「Quick Look 复制格式」项的 segmented picker 此前将标签与选择器同行排列，长标签（简中/繁中）在 picker 固定宽度下被截断成多行，挤压控件。改为标签与分段选择器上下分行：标签用 12pt muted 文本并允许垂直换行，picker 隐藏自身标签、固定 260pt 宽度，互不挤占。选择器仅在总开关开启时显示，Quick Look Preview 关闭时仍保留已选格式值的行为不变

## [2.2.9] - 2026-08-13

### 新增

- **内容一键复制总开关与 Quick Look 复制格式**：主阅读、Raw 编辑、Quick Look 三处整篇内容复制此前各自硬编码启用，无法统一关闭。新增设置项「内容一键复制」总开关（默认开启，仅在新 key 缺失时写入 true，绝不覆盖已有用户值），控制三处复制按钮的显隐与可点击；Quick Look 预览额外提供复制格式选择（富文本 / 原始 Markdown 文本），富文本复制渲染结构（标题、强调、表格、代码），原始 Markdown 复制文件 UTF-8 原文逐字保真
  - 主应用与 Quick Look Extension 跨进程共享同一组偏好 key：新增 `SharedPreferenceKey` 集中 applicationID 与 4 个跨进程 key（`languagePref` / `enableQuickLookPreview` / `enableDocumentCopy` / `quickLookDocumentCopyFormat`），`SettingsModel` 改引用共享 key，消除两处 key 字符串重复。Extension 经 `CFPreferencesCopyAppValue` 从主应用 preference 域读取，缺失/无效值回退 Kit 兼容默认（总开关 true、格式 richText、语言 auto 用检测语言）
  - 新增 `DocumentCopyConfiguration`（Kit）：`QuickLookDocumentCopyFormat` 枚举、`SharedPreferenceKey`、`QuickLookDocumentCopySettings`（值类型快照，解析逻辑收敛在 Kit，Provider 仅做 Bool/String 类型桥接）、`DocumentCopyPageConfiguration`（统一 enabled/格式/raw payload/文案/SF Symbol mask 图标的页面合同，`disabled` 静态默认保护 PDF 导出与未迁移入口）
  - `MarkdownHTMLService` 两个页面壳入口（`buildFullHTML` / `buildContentAwareHTML`）改为接收 `DocumentCopyPageConfiguration`，disabled 配置不输出任何复制属性、raw base64 或 mask 变量；enabled 配置输出 `data-document-copy-enabled` / `data-document-copy-format` / title/aria 文案，仅 rawMarkdown 格式且原文非空时输出 base64（ASCII 但仍做 XML 属性转义）
  - JS 侧 `addDocumentCopyButton` 改为仅在 `.markdown-preview[data-document-copy-enabled="true"]` 时创建，保护 PDF/打印与总开关关闭场景；新增 `setDocumentCopyButtonEnabled`（无重载增删按钮：关闭 clear timer + remove，开启幂等创建）、`copyRawMarkdownContent`（临时 textarea + execCommand 复制纯文本，decode/复制失败返回 false 不显示成功反馈）、`decodeUTF8Base64`（atob + TextDecoder('utf-8') 保证中文/emoji 字节保真）
  - 总开关运行时切换走无重载 JS bridge（`MR.setDocumentCopyButtonEnabled`），不触发 requestRender/page.load/MR.replaceContent；语言变化走 `MR.setDocumentCopyButtonLabels` 更新 DOM 标签
  - 设置页新增「内容一键复制」分区与 Quick Look 复制格式分段选择器（总开关开启时显示）；Raw 模式内容区右上角原生复制按钮与渲染页按钮一同遵从总开关
  - 总开关关闭立即取消五秒任务并清除对号，避免关闭再开启后复活旧成功态
  - `L10n` 新增 5 个三语文案（zh-Hans / zh-Hant / en）

### 优化

- **可选运行时按需加载**：主阅读页此前对每份普通 Markdown 无条件写入 `mermaid.min.js`（约 3.2 MB）、`katex.min.js`（约 272 KB）、`katex.min.css`（约 24 KB），即使正文无图表/公式也承担解析与内存成本。新增 `MarkdownHTMLService.MarkdownRuntimeRequirements` 值类型，从单次 `RenderResult.html` 推导需求（`class="language-mermaid"` → Mermaid；`class="language-math"` / `language-latex` / `language-katex` 任一 → KaTeX，自动覆盖 `$...$` / `$$...$$` 预处理产物），`buildFullHTML(renderResult:...)` 按需求条件装配可选资源标签，默认 `.all` 保持与历史完整页面合同一致以保护 Raw PDF 等未迁移调用方；Prism、autoloader、`markdown-reader.js` 始终加载
  - 增量内容替换前对单次解析结果检测需求，与已加载需求比较：需求变化（新出现图表/公式，或反向消失）提升为整页加载（已加载库无法卸载），需求不变沿用既有 latest-wins 增量替换。新增纯策略 `WebViewRuntimePolicy.action(current:next:)`（current 为 nil → loadPage；相同 → replaceContent；不同 → loadPage）
  - `WebViewWarmupService.warmupHTML` 仅保留 `markdown.css`、Prism、autoloader 与 `markdown-reader.js`，不再抢先载入 Mermaid/KaTeX；首次打开含图表/公式的文档按文档自身需求加载可选库

### 修复

- **Quick Look 内联图片读取留在 security-scoped access 内**：`preparePreviewOfFile` 此前在 `DispatchQueue.main.async` 闭包内才调用 `buildContentAwareHTML(inlineImages: true)`，此时 `url`/`dirURL` 的 security-scoped access 已在 `defer` 释放，导致同目录图片 `Data(contentsOf:)` 读取失败、内联 base64 缺失。改为在同步段、安全作用域仍有效时完成 HTML 生成（含图片读取）；仅 SF Symbol 图标栅格化（必须主线程）与 `webView.loadHTMLString` 推迟到 async 闭包，取到图标后通过 `injectDocumentCopyIcons(into:webIcons:)` 把 mask CSS 变量插入已生成 HTML 的首个 `:root {` 开括号后，不重新解析 Markdown、不重读图片

### 测试

- 新增 `QuickLookDocumentCopySettingsTests`：缺失值保持富文本、未知格式回退、有效 rawMarkdown 保留、auto/缺失语言偏好用检测语言
- 新增 `MarkdownHTMLServiceTests` 运行时需求与按需装配用例：普通 Markdown 不加载可选运行时、Mermaid/单美元 math 检测、latex 围栏块、混合检测、`buildFullHTML` 按需省略/默认全量/仅 Mermaid/仅 KaTeX
- 扩展 `DocumentCopyWebIconsTests`：disabled 不输出复制属性/payload/mask 变量、enabled richText 输出属性与 mask 变量与转义文案、rawMarkdown 输出 base64 而非原文、`buildContentAwareHTML` 同合同与默认 disabled
- 扩展 `WebViewRenderSchedulerTests`：需求不变保持增量替换、新增 KaTeX 提升整页、移除 Mermaid 提升整页、current 为 nil 强制整页
- 扩展 `AppStartupCoordinatorTests`：`warmupHTML` 仅基础运行时不含 Mermaid/KaTeX
- 全部 195 个测试通过

## [2.2.8] - 2026-08-12

### 优化

- **WebView 渲染触发收敛为单次动作**：`fileURL`/`content`/`contentVersion` 三个属性变更此前各自直接调用完整或增量渲染，快速连续切换文件、Reload 或外部刷新时会产生多次冗余渲染。新增 `WebViewRenderScheduler`（纯值类型 + latest-wins 世代），三触发器统一经 `requestRender()` 递增世代，由 `.task(id:)` 在一次 `Task.yield()` 后对最终快照执行唯一动作（`loadPage`/`replaceContent`/`none`）。一次文件切换只产生一次完整加载；同文件同版本的纯内容变化仍走 `MR.replaceContent` 增量路径；旧增量 JS 写入在新请求或视图消失时被取消或世代拒绝。配套 `WebViewRenderSchedulerTests` 覆盖决策规则与世代基线

### 新增

- **渲染模式复制图标改用 SF Symbols**：渲染模式内容区复制按钮此前使用手写 SVG 图标，与系统原生 SF Symbol 存在双套维护。新增 `SFSymbolWebImageProvider`（`@MainActor`），将 11pt Regular 符号栅格化为 14pt 透明 PNG，按屏幕倍率缓存为 data URL，在整页加载时注入 `:root` CSS 变量。WebKit 侧以 CSS `mask` + `currentColor` 上色，保留主题颜色、成功绿色、14px 图标、24px 透明触控区及无背景无边框视觉。缓存键为 `{ 配置版本, displayScale }`，同倍率至多栅格化各一次；`replaceContent`、主题更新、点击与五秒复位均命中缓存。新增 `DocumentCopySymbol`/`DocumentCopyWebIcons` 模型定义图标数据合同，配 `DocumentCopyWebIconsTests` 与 `SFSymbolWebImageProviderTests`

## [2.2.7] - 2026-08-12

### 优化

- **完整加载时消除重复 Markdown 渲染**：渲染模式完整加载（`loadContent()`）此前对同一份 Markdown 调用了两次 `MarkdownHTMLService.render`——一次在 `buildFullHTML` 内部装配页面壳，一次仅为写入从未被读取的 `currentHeadings`。后者额外执行 Markdown 预处理、Document 解析与 formatter 遍历，对功能无贡献。新增 `buildFullHTML(renderResult:...)` 重载，`loadContent()` 先渲染一次再复用结果；旧 `buildFullHTML(content:...)` 签名保留兼容，内部也只渲染一次。HTML 模板、属性转义、CSS/JS 顺序、copy-button 合同逐字不变。同时删除从未被读取的 `currentHeadings` 与 `lastLoadedURL` 状态，并补充 `MarkdownHTMLServiceTests` 覆盖新旧入口的输出合同

## [2.2.6] - 2026-08-12

### 修复

- **统一内容区复制按钮外观**：渲染模式与编辑模式的复制按钮此前各自使用不同样式（渲染模式有边框、背景、阴影；编辑模式有圆角背景卡片），与顶部文件路径按钮风格不一致。现统一为无边框、透明背景的纯图标样式，三处入口视觉一致
  - 渲染模式（WebKit）：`.mr-document-copy-btn` 移除 `border`、`background`、`box-shadow`，改为 24×24 透明区域；SVG 图标更新为与 SF Symbol `doc.on.doc` 一致的重叠双文档样式；hover/active 仅改变颜色
  - 编辑模式（SwiftUI）：移除 `RoundedRectangle` 背景与阴影，改用 `fgMuted` 颜色的纯 `Image`，与渲染模式及顶部路径按钮统一

## [2.2.5] - 2026-08-12

### 新增

- **内容区复制与统一五秒对号反馈**：渲染模式与编辑模式内容区右上角各新增复制按钮，成功后图标变对号、5 秒后恢复；顶部文件路径按钮的反馈从居中 Toast 改为同样的对号状态切换。三处入口各自独立计时，连续点击从最后一次成功重新计算，互不串扰
  - 渲染模式复制按钮注入 WebKit 文档内（`mr-document-copy-btn`），由真实 `click` 事件临时选中 `#mr-content` 走浏览器原生复制，保留标题、强调、表格、代码等富文本样式；`position: fixed` 固定不随滚动离开视口，不进入正文选区；查找栏打开时隐藏
  - 编辑模式复制按钮为原生 SwiftUI 浮层，直接写 `documentViewModel.content` 的原始 Markdown 到 `NSPasteboard`，不经 Select All 或当前选区，避免影响焦点与 per-file undo
  - 新增可测试的 `CopyFeedbackState` 纯逻辑（成功才置对号、连续点击重置计时），配 `CopyFeedbackStateTests` 覆盖状态机
  - PDF 导出时隐藏渲染页复制按钮，避免出现在导出产物中
  - `L10n` 新增 `contentCopy` / `contentCopied` 三语文案（zh-Hans / zh-Hant / en）
- **MIT 许可证文件**：补上根目录 `LICENSE`，与项目声明的 MIT 许可证一致

### 修复

- **原生复制路径检查剪贴板写入结果**：`NSPasteboard.setString` 返回值纳入成功判断，写入失败时不亮对号，避免给用户复制成功的错觉

## [2.2.4] - 2026-08-10

### 新增

- **可选 Homebrew Tap 安装渠道**：新增自建 Tap `davidhoo/homebrew-markdownreader`，用户可通过 `brew tap davidhoo/markdownreader && brew install --cask markdownreader` 安装与升级。Release DMG 仍为首要安装方式，Homebrew 为可选替代
  - 4 个 README（zh-Hans / zh-Hant / en / ja）各新增「Homebrew（可选）」小节，提供 tap / install / upgrade 命令
  - 各语言均说明应用未公证，引导用户走 macOS 原生「仍要打开」流程，不提供 `xattr` 或关闭 Gatekeeper 的命令
  - 新增 `docs/homebrew-tap-maintenance.md` 固化每次发布后的人工更新步骤（下载 DMG → 计算 SHA-256 → 更新 Cask → `brew audit` 校验 → 推送 Tap）
  - Cask 声明 `auto_updates true`，承认应用既有更新能力；用户强制由 Homebrew 升级时使用 `--greedy`

## [2.2.3] - 2026-07-31

### 修复

- **欢迎页打开文件夹后 Sidebar 不展开**：从欢迎页点击「打开」并在 OpenPanel 中选择文件夹后，目录能打开、`rootDirectory` 与 `isSidebarVisible` 也正确，但 Sidebar 实际呈现宽度仍为 0，需手动 `Cmd+\` 两次才出现目录树。根因是 SwiftUI 首次布局：`SidebarView` 为规避 AppKit hit-testing 问题始终保留在视图树中并以 0 宽度隐藏，从欢迎页切到目录模式时偶尔保留旧的 0 宽度布局
  - 新增 `AppViewModel.sidebarPresentationIdentity`：以根目录路径作为 Sidebar 的视图身份，仅在欢迎页/根目录上下文变化时重建子树，普通 `Cmd+\` 显隐仍复用同一子树并保留动画
  - `AppViewModel.openDirectory` 进入目录模式时同步设置可见宽度（不启动宽度动画），避免 OpenPanel sheet 结束期间的动画停在起点
  - 新增 `SidebarLayoutProbe`（NSViewRepresentable）作为 AppKit 几何锚点，让回归测试能验证根目录变化确实触发重建
  - 扩展 `OpenDirectorySidebarTests`：覆盖目录上下文身份变化（欢迎页→目录、重复打开同一目录、切换根目录）与真实 `NSHostingView` 布局测试（欢迎页宽度为 0、打开目录后重建且宽度不小于最小值、普通显隐复用同一 AppKit 子树）

## [2.2.2] - 2026-07-31

### 修复

- **冷启动双击 Markdown 时窗口不前置（打不开文件）**：冷启动时 Finder 双击会先创建一个不可见默认窗口，再走 `.openInSession` 复用路径。此前只加载文档不 `activate`，导致进程存活但可见窗口数为 0，用户感知为“双击打不开文件”
  - `WindowCoordinator` 在复用已有窗口打开资源时同步 `activate(windowID:)`，覆盖真实 `WindowSession` 与仅测试占位 session 两种情况
  - `WindowCommandTarget` 将 `@Entry var windowCommandTarget` 改为手写 `FocusedValueKey`，兼容 Command Line Tools 工具链（CLT 缺少 `@Entry` 宏依赖的 SwiftUIMacros 插件）
  - 新增 `OpenRequestRoutingTests` 覆盖冷启动复用窗口的前置激活路径
- **查找栏不支持 Shift+Enter 反向查找**：`FindReplaceBar` 将 `.onSubmit` 替换为 `.onKeyPress(.return, phases: .down)`，Enter 查找下一个、Shift+Enter 查找上一个，补齐查找栏内反向遍历匹配
- **标准一级菜单不跟随应用语言设置**：File / Edit / View / Window / Help 等标准菜单由 SwiftUI/AppKit 创建，不读应用自定义 `L10n`
  - 主 Bundle 开发语言由 `zh-Hans` 改为 `en`，并通过 `CFBundleLocalizations` 显式声明 `en` / `zh-Hans` / `zh-Hant`，使 macOS 在找不到对应语言 Bundle 本地化时正确回退英文而非简中
  - 新增 `MainMenuLocalizationService`：识别三种语言下的标准一级菜单标题，在 `AppDelegate` 启动时与应用内语言偏好变化时同步父 `NSMenuItem.title` 与 `submenu.title`，监听 `NSMenu.didAddItem/didChangeItem` 通知以应对 SwiftUI 重建菜单；自定义 `CommandMenu` 与菜单项继续走 `L10n`，不改动本地化架构
  - 新增 `MenuLocalizationTests` 覆盖三语标题映射、角色识别一致性、`Info.plist` 开发语言与支持语言声明

## [2.2.1] - 2026-07-15

### 修复

- **Cmd+N 后目录内文件切换失效与编辑器残留内容反写**：修复多窗口场景下三处回归根因，统一文件切换事务到 `WindowSession`
  - 根因1：Cmd+N 创建 Untitled 后未释放此前真实文件所有权，导致窗口同时持有旧文件 + Untitled，再次选择该文件被误判幂等无反应。`createNewUntitled` 现记录并释放 `previousRealFileURL` 所有权，保留根目录所有权
  - 根因2：`requestFileSelection` 幂等判断仅检查「本窗口持有」，无法处理残留所有权。改为同时校验持有 + `currentFileURL` + `selectedFileURL` 三者一致，持有但非当前文档时强制重新声明所有权以自愈
  - 根因3：`SyntaxHighlightedEditor.updateNSView` 在文件身份变化时未阻止 first responder 把上一个文件内容反写回 ViewModel。新增 `EditorSyncPolicy` 纯逻辑，将 `contentVersion` 与 `fileDidChange` 一并视为强制覆盖条件
  - 脏 Untitled 保存确认从视图层移至 `openFileInDirectoryWindow`，决策通过前不改 `selectedFileURL`，消除双重加载与弹窗竞态；删除 `ContentView.handleFileSwitchWithUnsavedChanges`，视图层仅响应已确认的选中项变化
  - `DocumentViewModel` 在 `createUntitledFile` / `discardUntitledFile` / `clearSelection` 等程序化清空处递增 `contentVersion`，强制编辑器采用空内容
- 新增 `SyntaxHighlightedEditorSyncTests` 覆盖同步策略；扩展 `DirectoryWindowNavigationTests` 与 `NewFileAndSaveFlowTests` 覆盖 Cmd+N 释放所有权、干净/脏 Untitled 往返切换、保存取消/失败等回归路径
- 修正 CHANGELOG「已知遗留」中已与代码矛盾的条目（`handleFileSwitchWithUnsavedChanges` 已随本次修复删除）

## [2.2.0] - 2026-07-14

### 新增

- **Word 式多窗口**：从单窗口架构升级为多窗口，每个窗口拥有独立的文件、目录、编辑、查找、大纲和 Undo 状态
  - 新增 `WindowSession`：窗口级业务边界，持有独立的 ViewModel 和 UndoStore
  - 新增 `WindowCoordinator`：应用级窗口协调器，管理资源所有权、路由决策和窗口生命周期
  - 新增 `WindowRoutingEngine`：纯逻辑路由引擎（owner → preferred blank → any blank → create）
  - 新增 `ResourceIdentityService`：基于路径标准化的资源身份规范化（符号链接、大小写敏感卷）
  - 同一文件只允许一个所有者窗口；再次打开时激活已有窗口，不创建重复实例
  - 目录窗口点击已被另一窗口持有的文件时，目录窗口选择不变，激活所有者窗口
  - 窗口级菜单命令经 FocusedValues 路由到焦点窗口，不广播
  - 统一所有打开入口（Finder、Open Recent、OpenPanel、命令面板、拖拽、链接点击）经 Coordinator 路由
  - 窗口级 Undo 隔离：每窗口独立 UndoStore，替代全局 UndoManagerProvider
  - 窗口级关闭协调：ApplicationTerminationCoordinator 串行处理脏 Untitled session
  - 应用级服务幂等执行：WebViewWarmupService、AppStartupCoordinator
  - 删除全局 `nonisolated(unsafe)` 可变状态（`_activePerFileUndoManager`、`UndoManagerProvider.shared`、`isPanelShowing`）
  - 删除单窗口守卫、`pendingOpenFilePath` UserDefaults、0.5s 启动延迟

### 修复

- **多窗口回归修复**：修复多窗口改造后窗口级命令路由和目录内导航的系统性回归
  - 命令路由：`MarkdownReaderCommands` 改为结构体级声明 `@FocusedValue`，禁止按钮 closure 内临时创建导致 target 为 nil 静默 no-op；无焦点 target 时菜单禁用
  - 视图层控件：Sidebar/Welcome/TitleBar/右键菜单直接调用注入的本窗口 `WindowCommandTarget`，不再通过 FocusedValue 反查；DetailView/WebViewMarkdownView 不再发布覆盖式 `focusedSceneValue`
  - 目录内导航：目录树/命令面板选择根目录内文件不再进入通用外部路由（避免误建窗口），改为目录窗口专用事务——声明目标所有权、释放旧文件所有权（保留根目录）、切换选中项并加载
  - 新建/保存流程：脏 Untitled 新建走完整「保存/不保存/取消」三分支；Cmd+S 对 Untitled 进入本窗口 Save As；Save/SaveAs/PDF 面板改为窗口级 sheet；新增 Save As 菜单入口
  - 连带问题：移除 Markdown 内链全局广播改为 WebView closure 回传所属 session；全屏通知按所属 NSWindow 过滤；didBecomeKey 更新 MRU/lastActiveWindowID；实现 `File > New Window` 与 `Cmd+Shift+N`；补全 Window 菜单；清理已失去调用方的窗口级 `Notification.Name`
- **打开目录强制展开 Sidebar 并保留有效宽度**：目录模式下目录树是主要操作入口，打开目录后必须保证 Sidebar 可见；从隐藏切到显示时仅在宽度低于阈值时恢复默认宽度，不再重置用户调整过的有效宽度
- 新增回归测试：目录窗口导航事务、新建/保存流程、命令分发隔离、外部去重、内链来源窗口、全屏隔离、MRU、连续创建窗口、打开目录展开 Sidebar（共 25 个测试）

## [2.1.11] - 2026-07-08

### 修复

- **关闭窗口后无法重新打开文件/目录**：修复窗口关闭后，通过「打开最近使用」菜单或 Dock 重新打开文件/目录时，文件加载到 ViewModel 但窗口不可见、内容不显示的问题
  - 根因：关闭窗口时 SwiftUI 仅隐藏而非销毁窗口，ContentView 仍可接收 `.openFile`/`.openDirectory` 通知，但此时主窗口处于隐藏状态，加载结果用户看不到；且窗口关闭后 `selectedFileURL` 可能与旧值相同，仅靠 `onChange(of:)` 不会触发加载
  - 修复：新增 `ensureWindowVisible()`，处理 `.openFile`/`.openDirectory` 通知前先检查并激活隐藏的主窗口（`setIsVisible` + `makeKeyAndOrderFront` + `NSApp.activate`）
  - `openFile` 路径改为显式调用 `loadFile(at:)` 兜底加载，不再仅依赖 `selectedFileURL` 变化触发，`loadFile` 内部幂等判断避免重复加载

## [2.1.10] - 2026-07-08

### 修复

- **窗口关闭后误弹未保存提示**：修复新建（Untitled）文档存在未保存修改时关闭窗口，再次通过「打开最近使用」打开文件会误弹未保存对话框的问题
  - 根因：`discardUntitledFile()` 仅清理缓存，未重置 `isUntitled` / `isDirty` / `currentFileURL` 等内存状态，导致 `isUntitled == true && isDirty == true` 残留，后续打开文件时被误判为有未保存修改
  - 修复：`discardUntitledFile()` 扩展为重置全部文档状态（`content` / `currentFileURL` / `fileName` / `displayMode` / `outlineItems` 等），而非仅清缓存
  - `WindowCloseGuard` 的「不保存」分支复用 `discardUntitledFile()`，统一清理临时文件与内存状态

## [2.1.9] - 2026-07-07

### 修复

- **PlantUML 渲染失败**：修复 plantuml.com 公共服务器（1.2026.7beta6）对所有 deflate-raw 编码请求返回 “This URL does not look like HUFFMAN data” 错误的问题
  - 将渲染服务器从 plantuml.com 切换到 Kroki（kroki.io），兼容 PlantUML 语法且服务端正常
  - 编码方式从 PlantUML 自定义 base64（deflate-raw）改为标准 base64url（deflate，含 zlib header），匹配 Kroki 要求
  - 影响 markdown-reader.js 中 _encodePlantUML、_fetchPlantUMLSVG、renderPlantUML、rerenderPlantUML 四处

## [2.1.8] - 2026-06-25

### 修复

- **重新打开上次位置闪现旧文件内容**：修复先打开 a.md、关闭窗口后删除 a.md、再打开 b.md 时，窗口先闪现 a.md 内容再显示 b.md 的问题
  - 根因：关闭窗口时 SwiftUI 仅隐藏而非销毁窗口，DocumentViewModel 仍持有上次文件内容；热启动（`application(_:open:)` 无可见窗口分支）与 Dock 重新激活（`applicationShouldHandleReopen`）直接激活该隐藏窗口，再异步发送 `.openFile`，导致旧内容在加载新文件前短暂可见
  - 修复：激活隐藏窗口前先同步发送 `.resetToWelcome` 清空残留文档内容，使窗口激活时显示欢迎页而非旧文件，随后加载目标文件
  - 顺带修复热启动分支未清除 `pendingOpenFilePath` / `pendingOpenDirectoryPath` UserDefaults 残留，避免下次冷启动误打开旧文件

## [2.1.7] - 2026-06-16

### 新增

- **关闭窗口菜单项**：添加「关闭窗口」菜单项，快捷键 Cmd+W，支持简中/繁中/英文三语本地化

### 修复

- **外部修改与 reload 内容同步**：修复外部修改与 reload 场景下内容不同步的问题
  - 新增 contentVersion 版本号机制，在 loadFile/reloadFromDisk/外部静默刷新时递增，解决 @Observable 因内容相同跳过更新及 NSTextView firstResponder 回写覆盖程序化更新的问题
  - 重构 loadFile() 缓存恢复逻辑：区分「用户有未保存编辑+磁盘外部修改」冲突场景，保留用户编辑内容并标记 isFileModifiedExternally，避免静默丢弃用户修改
  - loadFile() 同文件外部修改时：若 isDirty 则保留编辑等待 reload 按钮；若非 isDirty 则静默 reloadFromDisk
  - reloadFromDisk() 中清空 undo 栈（外部替换/reload 后旧历史无意义），并更新 snapshot/cache 后再设置 content（防止 didSet 误判脏状态）
  - 外部文件监控简化判断：移除 diskContent != snapshot 守卫，因 loadFile() 恢复缓存会将 snapshot 设为当前磁盘内容导致守卫失效
  - SyntaxHighlightedEditor：contentVersion 变化时跳过 firstResponder 回写保护，强制用 ViewModel 内容覆盖编辑器
  - WebViewMarkdownView：监听 contentVersion 变化，即使 content 值未变也执行完全重新加载

## [2.1.6] - 2026-06-15

### 修复

- **保存面板重复弹出**：移除 WindowGroup 自动添加的默认 Save/Save As 菜单项，这些默认菜单项绑定 Cmd+S 会触发系统 NSSavePanel，与自定义的 `.saveFile` 通知机制冲突导致保存面板重复弹出
- **另存为状态重置时序**：保存完成后才重置 `isSavePanelShowing` 标志，避免另存为尚未完成时标志已为 false 导致重入；用户取消保存面板时立即重置标志

## [2.1.5] - 2026-06-15

### 新增

- **GitHub 风格 emoji shortcode 支持**：新增 EmojiService，在 Markdown 渲染时将 `:emoji:` 短代码自动替换为 Unicode emoji 字符
  - 包含 240+ emoji shortcode 映射，覆盖笑脸与情感、手势与人物、动物与自然、天气与天体、食物与饮料、运动与活动、旅行与地点、物品与符号等分类
  - 支持 `:smile:` `:rocket:` `:+1:` `:-1:` 等常见 GitHub emoji 语法
  - 正则使用 lookahead/lookbehind 避免误匹配时间格式（如 `10:30`）
  - 在 MarkdownHTMLService 预处理阶段、代码区域保护之后执行替换，确保代码块内不误替换

## [2.1.4] - 2026-06-15

### 修复

- **保存后内容回退**：修复保存操作后编辑器内容被旧值覆盖的问题。当 NSTextView 为第一响应者时，以编辑器内容为准同步回 SwiftUI binding，防止 `isDirty` 变化触发重渲染覆盖编辑器
- **保存后文件监控误触发刷新**：修复保存后 FSEventStream 延迟回调可能误判为外部修改的问题。当磁盘内容与内存一致时仅同步快照，避免不必要的文件刷新
- **清理误提交文件**：删除误提交的 Untitled.md 测试文件

## [2.1.3] - 2026-06-15

### 修复

- **保存操作重入问题**：修复快捷键 Cmd+S 可能重复触发保存操作的问题，新增保存中状态检查
- **另存为面板重复弹窗**：修复新建文件保存时可能重复弹出另存为面板的问题，新增面板显示状态保护
- **另存为文件类型限制**：另存为面板允许保存为非 `.md` 扩展名的文件

## [2.1.2] - 2026-06-12

### 修复

- **行内 `$$` 公式渲染为 display 模式**：修复行内 `$$...$$` 数学公式被错误渲染为块级 display 模式的问题
  - `preprocessBlockMath` 正则改为仅匹配独占一行的 `$$...$$`（真正的块级公式）
  - 新增 `preprocessInlineDoubleMath` 处理行内 `$$...$$`，通过 `data-display="true"` 标记渲染为 display 模式行内公式
  - JS 渲染器读取 `data-display` 属性决定 KaTeX `displayMode` 参数

### 变更

- **官网首页**：功能区新增命令面板卡片
- **官网帮助页**：帮助页和 i18n 添加命令面板内容
- **官网帮助页 HTML**：修复功能区 HTML 闭合标签错误

## [2.1.0] - 2026-06-12

### 新增

- **命令面板**：新增 Cmd+P 命令面板，支持按文件名快速搜索并打开目录树中的 Markdown 文件
  - 命令面板视图（CommandPaletteView）与视图模型（CommandPaletteViewModel），支持文件搜索、键盘导航（↑↓）、Enter 打开
  - 搜索结果实时过滤，支持模糊匹配文件名和相对路径
  - 目录变化时自动刷新文件缓存
  - 半透明遮罩 + 标题栏下方居中浮层设计
  - 菜单栏新增「命令面板…」菜单项，快捷键 Cmd+P
- **右键「在访达中打开」**：文件树中目录和文件的右键菜单新增「在访达中打开」选项（Reveal in Finder / 在访达中打开 / 在 Finder 中打開）
  - 目录：使用 `NSWorkspace.shared.selectFile(_:inFileViewerRootedAtPath:)` 在 Finder 中显示目录
  - 文件：使用 `NSWorkspace.shared.activateFileViewerSelecting(_:)` 在 Finder 中选中文件
- **本地 Markdown 链接点击打开**：渲染视图中点击本地 Markdown 文件链接时，自动在应用内打开目标文件
  - 支持 `mr://` 和 `file://` 两种 URL scheme 的本地 Markdown 链接
  - 目录模式下，目标文件在根目录内时仅切换文件树选中项，不退回单文件模式
  - 目标文件在根目录外时，切换为单文件模式打开
- **官网多语言支持**：GitHub Pages 官网新增英文、日文、繁体中文三个语言版本
  - 新增 `pages/_data/i18n/` 目录下的四语翻译文件（zh-CN / en / ja / zh-TW）
  - 新增 `pages/en/`、`pages/ja/`、`pages/zh-TW/` 多语言页面（首页、帮助页、404 页）
  - 布局和样式优化，支持 RTL 语言切换
- **README 多语言版本**：新增英文（README.en.md）、日文（README.ja.md）、繁体中文（README.zh-TW.md）README 文件

### 修复

- **本地 Markdown 链接导航**：通过文档加载流程（DocumentViewModel.loadFile）打开本地 Markdown 链接文件，确保状态一致性

## [2.0.9] - 2026-06-11

### 新增

- **帮助菜单**：替换系统默认帮助搜索，新增「Markdown Reader 帮助」菜单项（Cmd+?），点击打开在线帮助页面
- **帮助页面**：新增 GitHub Pages 帮助页面（`pages/help.html`），展示快捷键、功能说明等使用指南
- **帮助菜单本地化**：LocalizationService 新增 `helpMenuLabel`、`helpMarkdownReader` 键，覆盖简中/繁中/英文三语

### 变更

- **README 快捷键文档**：补充快捷键说明章节
- **项目文档同步**：修正架构文档中的渲染引擎描述、项目结构、依赖和版本号

## [2.0.8] - 2026-06-10

### 新增

- **自定义关于面板**：新增 AboutWindowController + AboutView，展示应用图标、版本号、15 项功能特性列表、技术栈和网站链接，替换系统默认关于面板
- **关于面板本地化**：LocalizationService 新增 19 个 about* 本地化键，覆盖简中/繁中/英文三语

### 变更

- **README 开源致谢**：新增「致谢」章节，列出 cmark-gfm、swift-markdown、KaTeX、Mermaid、Prism.js、PlantUML 等核心开源库，感谢 linux.do 社区的反馈与支持

## [2.0.7] - 2026-06-10

### 新增

- **渲染视图缩放**：在「视图」菜单添加放大（Cmd++）、缩小（Cmd+-）、实际大小（Cmd+0）三个菜单项，缩放范围 0.3–3.0，页面加载后自动恢复缩放级别
- **标题栏双击最大化**：双击标题栏区域切换窗口最大化/还原，单击仍保持拖动行为

## [2.0.6] - 2026-06-09

### 修复

- **冷启动文件打开时序竞争**：`AppDelegate.applicationDidFinishLaunching` 主动发送 `.openFile`/`.openDirectory` 通知打开文件，不再依赖 `ContentView.task` 通过 UserDefaults 读取；`ContentView.task` 仅作为极早期后备（在 AppDelegate 延迟前已挂载时），UserDefaults 作为协调点避免重复打开
- **冷启动恢复位置误覆盖**：仅当 UserDefaults 中无待处理文件/目录路径时才发送 `.restoreLastLocation` 通知，防止恢复位置覆盖用户双击打开的文件

## [2.0.5] - 2026-06-09

### 修复

- **冷启动双击 md 文件偶发显示欢迎页**：ContentView.task 中冷启动时显式调用 `loadFile`，不再依赖 SelectionChangeModifier 的异步触发；同时显式加载目录，避免时序竞争
- **冷启动恢复位置误覆盖**：`restoreLastLocation()` 新增守护检查，若冷启动已通过 UserDefaults 打开了文件/目录，不再发送 `.restoreLastLocation` 通知覆盖
- **AppDelegate 冷启动待处理 URL 检测增强**：同时检查 UserDefaults 中的 `pendingOpenFilePath` / `pendingOpenDirectoryPath`，防止 `application(_:open:)` 延迟调用时误发恢复位置通知
- **切换文件时旧错误状态未清除**：`DocumentViewModel.loadFile` 开头先清除 `fileError`，修复从不支持格式文件切换到 md 文件时 `hasDocument` 始终为 false、DetailView 继续显示 ErrorView 的问题

## [2.0.4] - 2026-06-09

### 变更

- **标题栏按钮布局优化**：操作按钮（刷新、保存、导出、大纲）整合为 HStack 对齐组，底部对齐并与大纲图标下对齐，横向间距统一为 8pt，移除独立的 `.padding` 修饰符，视觉更紧凑一致

## [2.0.3] - 2026-06-09

### 新增

- **代码块一键复制**：渲染视图中的代码块右上角悬停显示复制按钮，点击即可复制代码内容
  - 优先使用 `navigator.clipboard` API，降级使用 `document.execCommand('copy')`
  - 复制成功后按钮变为对勾图标，2 秒后自动恢复
  - 样式使用主题 CSS 变量，自动适配深色/浅色主题

## [2.0.2] - 2026-06-09

### 新增

- **PDF 导出**：新增 `PDFExportService`，支持将渲染视图导出为 PDF 文件，自动等待图片、Mermaid、PlantUML 渲染完成后再导出，菜单快捷键 `Cmd+Option+E`
- **拖拽打开文件**：重写拖拽系统，绕过 SwiftUI `.onDrop`，直接使用 AppKit `NSDraggingDestination`，在窗口 themeFrame 上安装 `FileDropOverlayView`，支持拖拽 .md/.markdown/.mdown/.mkd/.txt 文件到窗口打开
- **多扩展名支持**：全面支持 .md / .markdown / .mdown / .mkd 扩展名
  - `FileService` 新增 `markdownExtensions` / `treeDisplayExtensions` 靆合及 `isMarkdownFile()` / `detectMarkdownContent()` 方法
  - `OpenPanelHelper` 文件选择面板和另存为面板支持所有 Markdown 扩展名
  - `SettingsModel` 默认打开程序检查和设置同时覆盖 .md/.markdown/.mdown/.mkd 四种扩展名
  - `Info.plist` 新增 `CFBundleTypeExtensions` 和 `mdown`/`mkd` 扩展名声明
- **纯文本模式**：`.txt` 文件加载时通过内容特征检测判断是否为 Markdown，非 Markdown 的 .txt 以纯文本模式加载（仅编辑模式，禁止切换渲染）
- **窗口拖动区域**：新增 `WindowDragArea` / `WindowDragNSView`，支持自定义标题栏区域的窗口拖动
- **不支持文件类型提示**：拖入不支持的文件类型时弹出提示弹窗，告知用户具体扩展名
- **本地化新增**：`exportPDF`、`exportPDFFailed`、`unsupportedFileTypeAlert` 等键值

### 变更

- **DMG/ZIP 命名简化**：DMG 和 ZIP 文件名不再包含版本号后缀，统一为 `MarkdownReader.dmg` / `MarkdownReader.zip`
- **DMG 卷名简化**：卷名从 `Markdown Reader $VERSION` 简化为 `Markdown Reader`
- **删除 QLMarkdown 子模块**：移除未使用的 QLMarkdown submodule 引用
- **架构文档更新**：新增 `architecture.pdf`

### 修复

- **语法高亮斜体跨行匹配**：斜体正则不再使用 `.dotMatchesLineSeparators`，遵守 CommonMark 段落边界规范
- **下划线斜体误匹配**：`_text_` 模式增加左侧/右侧非字母数字边界检查，避免 `tag_name`、`APP_PATH` 等标识符中的下划线被误解析为斜体
- **语法高亮部分覆盖跳过**：`highlightDeletion` / `highlightInsertion` / `highlightItalic` 新增 `isPartiallyCovered` 检查，跳过跨越代码块边界的匹配

## [2.0.1] - 2026-06-08

### 变更

- **文档更新**：README、CLAUDE.md、架构文档、需求文档同步 v2.0 渲染引擎迁移变更
- **官网更新**：GitHub Pages 更新至 v2.0.0，新增 Quick Look、Mermaid & PlantUML、数学公式、命令行工具等功能展示
- **MPE 预设主题补充**：网站主题预览从 23 套更新为 33 套（新增 5 深色 + 5 浅色 MPE 主题）
- **下载页更新**：系统要求更新为 macOS 26+ (Tahoe)，架构标注更新为 Apple Silicon 原生支持

## [2.0.0] - 2026-06-08

### 新增

- **WKWebView 渲染引擎**：渲染模式从 Textual 迁移至 cmark-gfm + WKWebView，支持完整的 GFM 扩展语法（表格、任务列表、脚注、删除线等）
- **Mermaid 图表渲染**：渲染视图支持 Mermaid 流程图、时序图、甘特图等图表类型，支持主题颜色同步和语法错误检测
- **KaTeX 数学公式**：渲染视图支持 LaTeX 行内公式（`$...$`）和块级公式（`$$...$$`），使用 KaTeX 本地渲染
- **Prism.js 代码高亮**：渲染视图使用 Prism.js 实现 30+ 语言的语法高亮，替代 Textual 内置高亮
- **MPE 预设主题**：新增 10 套 Markdown Preview Enhanced 风格预设主题（5 深色 + 5 浅色）
- **PlantUML 图表渲染**：渲染视图支持 PlantUML 语法，自动渲染为 SVG 图表（需要网络）
- **Quick Look 预览扩展**：Finder 中选中 .md 文件按空格即可预览渲染效果，无需打开应用
- **命令行工具 mdr**：支持在终端安装/卸载 `mdr` 命令，直接从命令行打开 Markdown 文件
- **渲染内容最大宽度跟随窗口**：新增设置选项，渲染内容宽度可跟随窗口自适应
- **Raw→Rendered 光标同步**：切换渲染/原文模式时自动同步光标位置
- **GitHub Pages 项目主页**：新增项目官网，展示功能特性、主题预览和下载入口

### 变更

- **渲染引擎迁移**：从 Textual (StructuredText) 迁移到 cmark-gfm + WKWebView
- **最低部署目标**：从 macOS 15.0 提升到 macOS 26
- **Bundle ID**：保持 `com.markdownreader.app`（单线发布，回归统一标识）
- **JS/CSS 资源本地化**：Mermaid、KaTeX、Prism.js 及字体文件全部本地打包，无需网络
- **移除 x86_64 支持**：回归 arm64 单架构构建

## [1.0.10] - 2026-06-06

### 变更

- **CI 发布流程重构**：将单一 `release` job 拆分为 `create-release`（仅创建 draft release，等待本地构建上传）和 `ci-build`（可选后备，需手动启用 `use_ci_build`）
- **新增本地发布脚本**：`release-local.sh`，本地构建 → 创建 DMG/ZIP → 上传到 GitHub Release，绕过 CI 环境差异导致的运行时问题
- **CI 签名改为精确签名**：不再使用已弃用的 `codesign --deep`，改为分别签名 `Resources/*.bundle` 和主 app

### 修复

- **CI 构建目录修正**：构建产物路径从 `.build/release/` 改为 `.build/arm64-apple-macosx/release/`，匹配 `--arch arm64` 构建输出
- **CI 签名方式修复**：与 v1.0.9 本地构建签名方式一致，避免递归签名破坏 SwiftUI 颜色目录

## [1.0.9] - 2026-06-06

### 修复

- **Appearance 变化时 NSTextView 文字不可见**：深色/浅色主题切换后原文模式文字颜色可能变为与背景相同，导致内容不可见。修复方式：
  - `applicationDidFinishLaunching` 中提前设置 `NSApp.appearance`，避免 SwiftUI 视图创建后 AppKit 覆盖 textColor
  - `SyntaxHighlightedEditor` 新增 appearance 变化检测，切换时自动重应用文字颜色和语法高亮
  - 显式设置 `textView.backgroundColor = .clear`，防止 AppKit 在 appearance 变化时重置为不透明背景
  - `Color.nsColor` 转换改用 sRGB 色彩空间创建固定颜色，消除 SwiftUI 颜色目录动态解析问题
- **自动更新签名修复**：`codesign --deep`（已弃用）改为精确签名，先签名 `Resources/*.bundle` 再签名主 app，避免递归签名破坏 SwiftUI 颜色目录签名导致 NSColor(SwiftUI.Color) 运行时解析失败
- **CI 构建指定架构**：`swift build -c release` 改为 `swift build -c release --arch arm64`，确保 CI 构建产物架构正确

## [1.0.8] - 2026-06-05

### 修复

- **Bundle.module 资源路径修补**：SPM 生成的 `resource_bundle_accessor.swift` 使用 `Bundle.main.bundleURL` 查找资源 bundle，但 macOS .app 的资源位于 `Contents/Resources/`，导致运行时找不到 Textual 和 swiftui-math 的资源 bundle 而崩溃。修补为 `Bundle.main.resourceURL` 使路径正确解析
- **CI 构建修补**：GitHub Actions release 工作流新增 Bundle.module 路径修补步骤，确保 CI 构建的 .app 也能正确加载依赖资源

## [1.0.7] - 2026-06-05

### 变更

- **查找替换栏布局重构**：改为三列布局（chevron / input / buttons），移除固定宽度约束，输入框自适应宽度
- **原文模式文字颜色**：SyntaxHighlightedEditor 主题切换时同步更新文字颜色（`textView.textColor`）

### 修复

- **语法高亮主题刷新**：切换主题后重新应用语法高亮颜色，修复之前主题切换后代码高亮不更新的问题
- **CI 依赖资源 bundle**：构建 .app 时复制依赖资源 bundle（Textual prism-bundle.js 等），修复代码块语法高亮在分发版中不工作的问题
- **自动更新签名断裂**：`cp -R` 替换应用后重新 ad-hoc 签名，修复 macOS 可能限制 AppKit 功能的问题

## [1.0.6] - 2026-06-05

### 新增

- **查找替换功能**：
  - VSCode 风格浮动查找面板，锚定文档区域右上角，Cmd+F 打开，Esc 关闭
  - 支持大小写敏感（Aa）、全词匹配（W*）、正则搜索（.*）
  - 实时匹配计数和当前位置显示（如 3/15），无匹配时红色提示
  - ▲▼ 按钮和 Cmd+G / Cmd+Shift+G 导航匹配项
  - Raw 模式下 NSTextStorage 背景色高亮所有匹配项，当前匹配高亮加深
  - Rendered 模式下通过行号跳转定位匹配位置
  - 替换当前匹配和全部替换（仅 Raw 模式），文字按钮替代图标更直观
  - ▶/▼ 展开收起替换行
  - 新增 FindReplaceViewModel、FindReplaceBar、TextViewSearchRef 三个组件
  - 新增 12 个查找替换相关本地化键值（简中/繁中/英文）
- **图片渲染**：
  - 渲染视图支持显示本地和远程图片（PNG、JPG、GIF、WebP、SVG）
  - 新增 ImageAttachmentLoader 处理图片加载，支持本地文件和 HTTP/HTTPS URL
  - SVG 图片通过 WKWebView 渲染为位图后显示
  - 链接图片（可点击跳转的图片）通过 URL fragment 编码链接地址实现
  - 图片自动适配宽度，保持纵横比
- **上标下标渲染**：
  - 新增 SupSubMarkupParser，支持 `<sup>`/`<sub>` HTML 标签渲染
  - 新增 MarkdownContentPreprocessor 预处理 Markdown 内容中的上标下标标记
- **代码块语法高亮主题**：
  - ThemeColors 新增 `highlighterTheme` 属性，从主题色派生 Textual 语法高亮配色
  - 23 套预设主题各有匹配的代码高亮色彩，关键字、字符串、注释等 20+ token 类型
  - 深色/浅色主题自动适配代码前景色和背景色

### 修复

- **Dock 点击双窗口 bug**：
  - `applicationShouldHandleReopen` 返回 false 阻止 SwiftUI 自动创建新窗口
  - 根据 reopenLastLocation 设置发送 restoreLastLocation 或 resetToWelcome 通知
- **冷启动恢复位置**：
  - 冷启动时若无待处理文件且 reopenLastLocation 开启，发送 restoreLastLocation 通知恢复上次位置
  - 新增 `restoreLastLocation()` 方法恢复上次打开的目录或文件
- **单文件模式稳定性**：
  - 切换单文件模式时保留 selectedFileURL，避免瞬时 nil 翻转触发 SelectionChangeModifier
  - 单文件模式下不再因 selectedFileURL 变 nil 而取消文档，文档生命周期独立于文件树
  - 文件树展开时选中文件清除逻辑增加路径前缀检查，不误清不在根目录树中的选中

## [1.0.5] - 2026-06-04

### 修复

- **自动更新安装可靠性**：
  - 先关闭更新弹窗再执行安装，避免 SwiftUI sheet 干扰进程退出
  - 使用 `exit(0)` 替代 `NSApplication.terminate()`，防止 `windowShouldClose` 拦截导致应用无法退出、守夜人脚本永远等待
  - 守夜人脚本 stdout/stderr 重定向到日志文件（`$TMPDIR/MarkdownReader-update-<UUID>.log`），避免父进程退出时管道关闭导致子进程收到 SIGPIPE
- **滚动定位可靠性**：
  - `CaptureNSView` 新增 `viewDidMoveToSuperview()` 捕获时机和 `viewDidMoveToWindow()` 延迟重试，确保 NSScrollView 捕获成功
  - `ScrollHelperNSView.scrollToLine` 新增两层重试机制（最多 20 次，间隔 0.1 秒）：NSScrollView 未捕获时重试、文档布局未完成时重试
  - 渲染模式滚动请求超时从 0.5 秒延长至 2.5 秒，等待 StructuredText 完成布局

### 变更

- **Dock 点击行为**：所有窗口关闭后点击 Dock 图标，根据「启动时重新打开上次位置」设置决定恢复上次位置或显示欢迎页，修复点击 Dock 时出现双窗口的 bug
- **冷启动恢复位置**：点击应用图标启动时，若「启动时重新打开上次位置」开启则恢复上次位置，否则显示欢迎页
- **移除 `.handlesExternalEvents(matching:)`**：冷启动时 ContentView.task 通过 UserDefaults 读取文件路径，无需 SwiftUI 为外部事件创建额外窗口，避免双窗口问题
- **README 更新**：DMG 安装包大小描述从「不到 6MB」更新为「不到 10MB」

## [1.0.4] - 2026-06-04

### 新增

- **标题栏复制路径按钮**：DetailView 标题栏新增一键复制文件路径按钮
- **右键菜单复制路径**：文件树中目录和文件的右键菜单均新增「复制路径」选项
- **自定义细滚动条**：新增 `ThinOverlayScroller` 类，渲染 6px 圆角滑块，覆盖非 NSTextView 的 NSScrollView（如文件树列表）
- **OpenPanelHelper 重入保护**：新增 `isPanelShowing` 标志位，防止 WindowGroup 多实例并发触发重复弹窗
- **OverlayScrollerHelper 三级搜索策略**：重写滚动条查找逻辑，支持 superview 链 → 兄弟视图 → 祖先区域三级搜索，解决深层级视图中滚动条样式不生效的问题
- **Package.resolved 纳入版本控制**：锁定依赖版本确保构建可复现

### 变更

- **直接调用 OpenPanelHelper**：SidebarView、DetailView、WelcomeView 改为直接调用 `OpenPanelHelper.show()`，移除 `.openPanel` 通知方式，避免 WindowGroup 多实例重复弹窗
- **DocumentViewModel 幂等加载**：`loadFile(at:)` 新增幂等保护，已加载同一文件且内容非空时跳过重复加载
- **热启动延迟移除**：AppDelegate 中 `DispatchQueue.main.asyncAfter(0.3)` 改为 `DispatchQueue.main.async`，消除不必要的 300ms 延迟
- **移除冗余 synchronize()**：AppDelegate 中 `UserDefaults.standard.synchronize()` 调用移除，UserDefaults 自动定期同步
- **ContentView 清理**：移除 4 处冗余的 `loadFile(at:)` 调用，统一由 `SelectionChangeModifier` 响应 `selectedFileURL` 变化触发加载
- **目录关闭优化**：切换到单文件模式时跳过 `clearDirectory()`，文件树即将被隐藏无需清空
- **WelcomeView 清理**：移除内联 `openPanel()` 方法和 `UniformTypeIdentifiers` 导入，统一使用 `OpenPanelHelper.show()`
- **应用图标更新**：更新全部 10 个 AppIcon 尺寸图片

## [1.0.3] - 2026-06-04

### 新增

- **自动更新功能**：基于 GitHub Releases 实现应用内自动更新检查与安装
  - 启动时自动检查更新（延迟 2 秒，避免影响启动速度）
  - 菜单栏「检查更新…」手动触发更新检查
  - 更新弹窗显示版本号、Release Notes、下载进度
  - 支持自动安装并重启（Sparkle 式体验）和手动安装两种模式
  - 支持「跳过此版本」和「稍后提醒」
  - 新增 UpdateService、UpdateViewModel、UpdateView 三个组件
  - SettingsModel 新增 skippedVersion、lastUpdateCheckTime 设置项
- **复制路径本地化**：新增 titleBarCopyPath、contextMenuCopyPath 本地化键值（简中/繁中/英文）
- **自动更新本地化**：新增 18 个更新相关本地化键值（简中/繁中/英文）

### 变更

- **CI 发布流程**：GitHub Actions release 工作流新增 ZIP 打包，Release 同时上传 DMG 和 ZIP
- **发布说明目录**：发布说明文件从项目根目录移至 `docs/releases/` 目录，CI 路径同步更新

## [1.0.2] - 2026-06-04

### 修复

- **双击 .md 文件无法打开应用**：重写 AppDelegate，改用 `application(_:open:)` 替代 `application(_:openFiles:)`，修复 macOS 15+ 上 SwiftUI WindowGroup 窗口不可见的问题
- **冷启动/热启动文件打开**：新增 UserDefaults 回退机制解决文件打开时序问题；新增 `activateFirstHiddenWindow()` 处理冷启动、热启动和 Dock 点击场景
- **Dock 点击激活**：新增 `applicationShouldHandleReopen` 实现 Dock 点击时激活窗口
- **文件打开幂等保护**：ContentView 中对 openFile/openDirectory 通知添加幂等保护，防止重复触发
- **恢复上次位置**：新增 `restoreLastLocation` 通知机制，确保双击文件启动时跳过恢复上次位置
- **应用图标**：更新全部 AppIcon 尺寸（16–512pt），新增图标生成脚本
- **DMG 打包**：package.sh 优先使用 create-dmg，支持 DMG 卷图标；移除 DMG 的 ad-hoc 签名（避免 Gatekeeper 误拦截）
- **文件关联**：LSHandlerRank 从 Alternate 改为 Default，新增 UTImportedTypeDeclarations 确保 .md 文件正确关联

## [1.0.1] - 2026-06-03

### 新增

- **AppDelegate 文件打开处理**：新增 AppDelegate 处理冷启动/热启动时的文件打开事件，通过 `lastHandledURL` 去重防止 `.onOpenURL` 和 AppDelegate 同时触发导致重复打开
- **文件外部修改检测**：集成 FileSystemWatcher，实时监控当前文件所在目录的变更；未修改文件自动静默刷新，已修改文件显示刷新按钮
- **重新加载功能**：标题栏刷新按钮（文件被外部修改时显示）、侧边栏右键菜单「重新加载」选项，支持从磁盘重新加载文件（丢弃当前未保存修改）
- **重新加载确认弹窗**：有未保存修改时弹出确认对话框，支持「以后不再提醒」选项
- **skipFileModifiedAlert 设置**：允许用户关闭外部修改确认弹窗，直接静默重新加载
- **本地化**：新增 `fileModifiedExternallyTitle/Message/Reload/DontRemind`、`titleBarReload`、`contextMenuReload` 共 7 个本地化键值（简中/繁中/英文）

### 变更

- 双击文件启动应用时，跳过恢复上次打开位置，优先打开用户点击的文件
- 禁用 macOS 窗口标签页功能（隐藏「显示标签页栏」菜单项）
- 保存文件后清除外部修改标记，避免误显示刷新按钮

## [1.0.0] - 2026-06-03

首个正式版本。Markdown Reader 是一款 macOS 原生 Markdown 阅读器，采用 SwiftUI + Textual 构建，提供三栏布局：左侧目录树导航 + 中间 Markdown 渲染 + 右侧大纲导航。

### 新增

- **Markdown 渲染引擎**：基于 [Textual](https://github.com/gonzalezreal/textual) 库实现 Markdown 渲染，支持 GFM 扩展（表格、任务列表、删除线等），代码块语法高亮
- **渲染 / 原文模式**：一键切换渲染视图与原始 Markdown 文本，渲染视图支持原生文本选择
- **文件编辑保存**：支持直接编辑 Markdown 文件，Cmd+S 保存，切换文件时自动保留未保存修改（per-file 内容缓存）
- **Per-file Undo 管理**：每个文件独立维护撤销/重做栈，切换文件时完整保留编辑历史
- **新建文件**：右键菜单或快捷键在当前目录下新建 Markdown 文件
- **文件系统监控**：FileSystemWatcher 实时监听文件变更，外部修改自动刷新内容
- **文件树右键菜单**：目录支持新建文档、新建子目录、重命名、移动到、删除；文件支持重命名、移动到、删除
- **未保存修改保护**：关闭未保存文件时弹出确认对话框，可选保存/放弃/取消
- **空目录显示**：文件树递归展示空目录节点
- **自定义双栏布局**：HStack + DragGesture 两列布局，支持拖拽阈值自动隐藏侧边栏、圆角 Detail 区域
- **Buddy 风格界面**：隐藏标题栏 + 自定义窗口控制按钮（TrafficLightButtons），实现 macOS 原生应用体验
- **大纲导航面板**：OutlineView/OutlineService/OutlineItem，自动解析 Markdown 标题结构（ATX + Setext 风格），层级缩进显示，支持 1-6 级标题，点击快速跳转
- **大纲导航滚动同步**：编辑区滚动时自动高亮当前大纲标题
- **主题色彩系统**：23 套预设主题（15 深色 + 8 浅色：Dracula、Catppuccin、Nord、Tokyo Night、Gruvbox、One Dark Pro 等），支持自定义颜色覆盖（surface / ink / accent / success / danger 五色），对比度滑块精细调节
- **外观模式**：支持浅色 / 深色 / 跟随系统三种外观模式
- **多语言本地化**：LocalizationService/L10n 方案，支持简体中文、繁体中文、英文三语，80+ 本地化键值覆盖全部 UI 文字，自动检测系统语言
- **设置系统**：SettingsModel 基于 @Observable + UserDefaults，支持默认显示模式、启动恢复、隐藏文件过滤、外观模式、字体字号、内容边距等配置
- **设置视图**：左侧边栏 + 右侧内容布局，包含主题模式卡片、配色方案网格、自定义颜色条、对比度滑块、字体排版五个区段
- **默认 Markdown 打开程序**：可通过设置将应用注册为 .md/.markdown 文件的默认打开程序
- **最近打开记录**：记录最近打开的文件和目录
- **Git 状态面板**：底部状态栏显示分支、变更计数，可展开变更文件列表及 commit+push 输入区（仅在 Git 仓库中显示）
- **文件树过滤**：支持隐藏文件、非 Markdown 文件过滤
- **键盘导航**：↑↓ 移动文件树，Enter 打开/展开，Cmd+, 设置、Cmd+O 打开、Cmd+\ 切换侧边栏、Cmd+Shift+E/R 切换渲染/原始模式
- **窗口状态恢复**：启动时恢复上次打开的位置
- **应用图标**：全套 macOS AppIcon 尺寸
- **构建与发布**：build-app.sh 支持代码签名与 DMG 打包，package.sh 一键构建打包，GitHub Actions 自动化发布流程

### 变更

- 渲染库从 MarkdownUI 迁移至 Textual（官方继任者）
- 最低部署目标从 macOS 13.0 升级至 macOS 15.0
- 状态管理从 ObservableObject 迁移至 @Observable，启用 Swift 6 严格并发
- 布局方案从 NavigationSplitView 改为自定义 HStack 两列布局
- 窗口样式改用 `.windowStyle(.hiddenTitleBar)`，新增自定义标题栏替代系统 NSToolbar
- ResizeHandle 从 SwiftUI DragGesture 重构为 NSViewRepresentable + NSView 鼠标事件，修复 macOS 拖拽不可靠问题
- RawMarkdownView 替代 SourceMarkdownView，改进原始 Markdown 展示
- 恢复系统原生滚动条，移除自定义主题滚动条

### 移除

- 移除 cmark-gfm 依赖
- 移除 NavigationSplitView 布局方案
- 移除系统 NSToolbar 标题栏
- 移除 Git 模块独立视图（整合至底部状态栏）

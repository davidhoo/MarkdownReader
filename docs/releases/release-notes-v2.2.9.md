# Markdown Reader v2.2.9

为内容一键复制加入统一总开关与 Quick Look 复制格式选择，主阅读页可选运行时改为按需加载，并修复 Quick Look 内联图片读取离开安全作用域的回归。

## ✨ 新增

### 内容一键复制总开关 + Quick Look 复制格式
主阅读、Raw 编辑、Quick Look 三处整篇内容复制此前各自硬编码启用，无法统一关闭。本版新增设置项「内容一键复制」总开关（默认开启，绝不覆盖已有用户值），统一控制三处复制按钮；Quick Look 预览额外提供复制格式选择：

- **富文本**：复制 `#mr-content` 的渲染结构（标题、强调、表格、代码等）
- **原始 Markdown 文本**：复制文件 UTF-8 原文，逐字保真

- 主应用与 Quick Look Extension 跨进程共享同一组偏好 key（`SharedPreferenceKey` 集中管理 applicationID 与 4 个跨进程 key，消除重复字符串）。Extension 经 `CFPreferencesCopyAppValue` 从主应用 preference 域读取，缺失/无效值回退兼容默认
- 总开关运行时切换走无重载 JS bridge（`MR.setDocumentCopyButtonEnabled`），不整页重载；语言变化走 `MR.setDocumentCopyButtonLabels` 更新 DOM 标签
- Raw 模式内容区右上角原生复制按钮与渲染页按钮一同遵从总开关；总开关关闭立即取消五秒对号计时并清除残留状态
- 设置页新增「内容一键复制」分区与 Quick Look 复制格式分段选择器

## ⚡ 优化

### 可选运行时按需加载
主阅读页此前对每份普通 Markdown 都无条件写入 `mermaid.min.js`（约 3.2 MB）、`katex.min.js`（约 272 KB）、`katex.min.css`（约 24 KB），即使正文没有图表/公式也承担解析与内存成本。

- 新增 `MarkdownRuntimeRequirements`：从单次渲染结果推导需求（`language-mermaid` → Mermaid；`language-math` / `latex` / `katex` → KaTeX，自动覆盖 `$...$` / `$$...$$` 预处理产物），页面壳按需条件装配可选资源标签
- 增量内容替换前先检测需求：需求变化（新出现或反向消失图表/公式）提升为整页加载（已加载库无法卸载），需求不变沿用既有增量替换
- `WebViewWarmupService` 预热仅保留 Prism、autoloader 与 `markdown-reader.js`，不再抢先载入 Mermaid/KaTeX；首次打开含图表/公式的文档按文档自身需求加载
- Prism、autoloader、`markdown-reader.js` 始终加载，代码高亮与 PlantUML（Kroki 路径）不受影响

## 🐛 修复

### Quick Look 内联图片读取离开安全作用域
`preparePreviewOfFile` 此前在 `DispatchQueue.main.async` 闭包内才生成 HTML，此时文件及所在目录的 security-scoped access 已在 `defer` 释放，导致同目录图片 `Data(contentsOf:)` 读取失败、内联 base64 缺失、图片显示为空白。

- 改为在同步段、安全作用域仍有效时完成 HTML 生成（含图片读取）
- 仅 SF Symbol 图标栅格化（必须主线程）与 `webView.loadHTMLString` 推迟到 async 闭包，取到图标后把 mask CSS 变量插入已生成 HTML 的 `:root`，不重新解析 Markdown、不重读图片

## ✅ 测试

- 新增 `QuickLookDocumentCopySettingsTests`：缺失值保持富文本、未知格式回退、有效 rawMarkdown 保留、auto/缺失语言偏好用检测语言
- 新增运行时需求与按需装配用例：普通 Markdown 不加载可选运行时、Mermaid/单美元 math/latex 围栏块/混合检测、`buildFullHTML` 按需省略/默认全量/仅 Mermaid/仅 KaTeX
- 扩展 `WebViewRenderSchedulerTests`：需求不变保持增量替换、新增 KaTeX 提升整页、移除 Mermaid 提升整页、current 为 nil 强制整页
- 扩展 `AppStartupCoordinatorTests`：`warmupHTML` 仅基础运行时不含 Mermaid/KaTeX
- 全部 195 个测试通过

## 🖥️ 系统要求

- macOS 26 (Tahoe) 或更高版本
- Apple Silicon 原生支持

---

感谢使用 Markdown Reader！如有问题或建议，欢迎在 GitHub Issues 反馈。

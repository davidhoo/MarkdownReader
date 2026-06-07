# Changelog

本项目的所有重要变更都会记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.1.0] - 2026-06-07

v1.x 维护线首个稳定版，从 v1.0.10 切出独立维护分支 `release/1.x`。

### 变更

- 从 `release/1.x` 分支独立维护，与 main 分支（v2.x 开发）隔离

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

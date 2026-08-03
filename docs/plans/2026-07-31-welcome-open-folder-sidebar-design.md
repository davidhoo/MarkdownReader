# 欢迎页打开文件夹自动展开 Sidebar 设计

## 问题

从欢迎页点击“打开”并在 OpenPanel 中选择文件夹后，文件夹能够打开，但当前窗口的 Sidebar 没有自动展开。通过“文件 → 打开最近使用”打开目录时行为正常。

现有 `OpenDirectorySidebarTests` 只覆盖 `AppViewModel.openDirectory` 和 `WindowSession.openDirectory` 的直接调用，没有覆盖欢迎页实际使用的完整链路：

`WelcomeView → WindowCommandTarget → WindowSession.openFromPanel → WindowCoordinator → WindowSession.openDirectory`

补充复现后确认：目录已经成功打开，`rootDirectory` 和 `isSidebarVisible` 也都正确；
第一次 `Cmd+\` 会关闭 Sidebar 并显示顶部切换按钮，第二次再打开才出现目录树。
这说明问题位于 SwiftUI 首次布局，而不是打开路由或状态模型。

## 目标行为

- 欢迎页选择文件夹后，在发起操作的当前空白窗口中打开目录。
- 目录打开时 Sidebar 必须可见，并保留有效的用户自定义宽度。
- 用户取消 OpenPanel 时不改变 Sidebar 状态。
- 打开单文件、打开最近使用以及其他目录入口的既有行为保持不变。

## 方案比较

### 方案 A：在欢迎页按钮回调中提前展开 Sidebar

实现简单，但用户取消 OpenPanel 时也会看到空 Sidebar，并且把目录模式规则泄漏到视图入口。

### 方案 B：在 Coordinator 中对 `.openPanel` 特判

可以只处理这个入口，但会让路由层承担视图状态职责，也会造成不同打开来源的行为分叉。

### 方案 C：根目录上下文变化时重建 Sidebar 子树

`SidebarView` 为规避 AppKit hit-testing 问题始终保留在视图树中，并用 0 宽度隐藏。
从欢迎页切到目录模式时，SwiftUI 偶尔保留旧的 0 宽度布局。用根目录路径作为
Sidebar 的视图身份，只在欢迎页/根目录上下文变化时重建子树；自动进入目录模式
同步设置可见宽度，避免 OpenPanel sheet 结束期间的动画停在起点。普通 `Cmd+\` 显隐仍复用原视图并保留动画。

采用方案 C。

## 数据流

1. 欢迎页通过当前窗口的 `WindowCommandTarget` 打开面板。
2. 用户选择资源后，`WindowSession` 以当前窗口 ID 为 preferred window 提交请求。
3. Coordinator 将目录路由回当前空白 session。
4. `AppViewModel.openDirectory` 更新根目录并同步设置 Sidebar 可见，不启动宽度动画。
5. 根目录身份变化使 SwiftUI 重建 Sidebar 子树，清除欢迎页遗留的 0 宽度布局。
6. 目录树异步加载完成，当前窗口保持展开的 Sidebar。

## 测试

新增目录上下文身份测试和真实 `NSHostingView` 布局测试，断言：

- 欢迎页进入目录时 Sidebar 身份变化；
- 重复打开同一目录时身份稳定；
- 切换根目录时身份再次变化。
- 欢迎页的 Sidebar 实际宽度为 0，打开目录后重建且宽度不小于最小值；
- 普通 `Cmd+\` 隐藏/显示复用同一 AppKit 子树。

先运行测试确认它能复现失败，再做单点修复；随后运行相关测试、全量测试和构建。

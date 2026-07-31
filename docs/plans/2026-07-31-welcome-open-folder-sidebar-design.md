# 欢迎页打开文件夹自动展开 Sidebar 设计

## 问题

从欢迎页点击“打开”并在 OpenPanel 中选择文件夹后，文件夹能够打开，但当前窗口的 Sidebar 没有自动展开。通过“文件 → 打开最近使用”打开目录时行为正常。

现有 `OpenDirectorySidebarTests` 只覆盖 `AppViewModel.openDirectory` 和 `WindowSession.openDirectory` 的直接调用，没有覆盖欢迎页实际使用的完整链路：

`WelcomeView → WindowCommandTarget → WindowSession.openFromPanel → WindowCoordinator → WindowSession.openDirectory`

因此入口路由上的回归无法被现有测试发现。

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

### 方案 C：在窗口会话的目录打开边界统一保证 Sidebar 可见

所有成功进入目录模式的入口共享相同不变量；欢迎页只负责发起打开请求，Coordinator 只负责路由。配合完整入口回归测试，可以防止同类问题再次出现。

采用方案 C。

## 数据流

1. 欢迎页通过当前窗口的 `WindowCommandTarget` 打开面板。
2. 用户选择资源后，`WindowSession` 以当前窗口 ID 为 preferred window 提交请求。
3. Coordinator 将目录路由回当前空白 session。
4. `WindowSession.openDirectory` 在加载目录树前同步建立目录模式并确保 Sidebar 可见。
5. 目录树异步加载完成，当前窗口保持展开的 Sidebar。

## 测试

新增入口级回归测试，模拟 `.openPanel` 请求复用当前空白 session，并等待 Coordinator 发起的主线程任务完成。断言：

- 请求由当前 session 接收；
- `rootDirectory` 更新为所选目录；
- `isSidebarVisible` 为 `true`；
- 目录树完成加载。

先运行测试确认它能复现失败，再做单点修复；随后运行相关测试、全量测试和构建。

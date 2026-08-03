# Markdown Reader v2.2.3

修复从欢迎页打开文件夹后 Sidebar 不展开的问题。

## 🐛 修复

### 欢迎页打开文件夹后 Sidebar 不展开
从欢迎页点击「打开」并在 OpenPanel 中选择文件夹后，目录能打开、`rootDirectory` 与 `isSidebarVisible` 状态也正确，但 Sidebar 实际呈现宽度仍为 0，需手动 `Cmd+\` 两次才出现目录树。

- 根因：`SidebarView` 为规避 AppKit hit-testing 问题始终保留在视图树中并以 0 宽度隐藏；从欢迎页切到目录模式时 SwiftUI 偶尔保留旧的 0 宽度布局，而非路由或状态模型问题
- 修复：以根目录路径作为 Sidebar 的视图身份（`sidebarPresentationIdentity`），仅在欢迎页/根目录上下文变化时重建子树；普通 `Cmd+\` 显隐仍复用同一子树并保留动画
- `AppViewModel.openDirectory` 进入目录模式时同步设置可见宽度（不启动宽度动画），避免 OpenPanel sheet 结束期间的动画停在起点
- 新增 `SidebarLayoutProbe`（NSViewRepresentable）作为 AppKit 几何锚点，供回归测试验证重建

## ✅ 测试

- 扩展 `OpenDirectorySidebarTests`：目录上下文身份变化（欢迎页→目录、重复打开同一目录、切换根目录）与真实 `NSHostingView` 布局测试（欢迎页宽度为 0、打开目录后重建且宽度不小于最小值、普通显隐复用同一 AppKit 子树）
- 全部 137 个测试通过

## 🖥️ 系统要求

- macOS 26 (Tahoe) 或更高版本
- Apple Silicon 原生支持

---

感谢使用 Markdown Reader！如有问题或建议，欢迎在 GitHub Issues 反馈。

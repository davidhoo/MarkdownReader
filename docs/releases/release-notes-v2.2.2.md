# Markdown Reader v2.2.2

修复冷启动双击 Markdown 打不开文件、查找栏无法反向查找、标准菜单不跟随应用语言设置三个问题。

## 🐛 修复

### 冷启动双击 Markdown 时窗口不前置（打不开文件）
冷启动时 Finder 双击会先创建一个不可见默认窗口，再走 `.openInSession` 复用路径。此前只加载文档不激活窗口，导致进程存活但可见窗口数为 0，用户感知为“双击打不开文件”。

- 修复：`WindowCoordinator` 在复用已有窗口打开资源时同步 `activate(windowID:)`，覆盖真实 `WindowSession` 与仅测试占位 session 两种情况
- `WindowCommandTarget` 将 `@Entry var windowCommandTarget` 改为手写 `FocusedValueKey`，兼容 Command Line Tools 工具链（CLT 缺少 `@Entry` 宏依赖的 SwiftUIMacros 插件）
- 新增 `OpenRequestRoutingTests` 覆盖冷启动复用窗口的前置激活路径

### 查找栏不支持 Shift+Enter 反向查找
- 修复：`FindReplaceBar` 将 `.onSubmit` 替换为 `.onKeyPress(.return, phases: .down)`，Enter 查找下一个、Shift+Enter 查找上一个，补齐查找栏内反向遍历匹配

### 标准一级菜单不跟随应用语言设置
File / Edit / View / Window / Help 等标准菜单由 SwiftUI/AppKit 创建，不读应用自定义 `L10n`，此前固定显示简体中文。

- 修复：主 Bundle 开发语言由 `zh-Hans` 改为 `en`，并通过 `CFBundleLocalizations` 显式声明 `en` / `zh-Hans` / `zh-Hant`，使 macOS 在找不到对应语言 Bundle 本地化时正确回退英文而非简中
- 新增 `MainMenuLocalizationService`：识别三种语言下的标准一级菜单标题，在 `AppDelegate` 启动时与应用内语言偏好变化时同步父 `NSMenuItem.title` 与 `submenu.title`，监听 `NSMenu.didAddItem/didChangeItem` 通知以应对 SwiftUI 重建菜单
- 自定义 `CommandMenu` 与菜单项继续走 `L10n`，不改动本地化架构
- 新增 `MenuLocalizationTests` 覆盖三语标题映射、角色识别一致性、`Info.plist` 开发语言与支持语言声明

## ✅ 测试

- 新增 `OpenRequestRoutingTests` 覆盖冷启动复用窗口激活路径
- 新增 `MenuLocalizationTests` 覆盖标准菜单本地化映射与静态回归
- 全部 135 个测试通过

## 🖥️ 系统要求

- macOS 26 (Tahoe) 或更高版本
- Apple Silicon 原生支持

---

感谢使用 Markdown Reader！如有问题或建议，欢迎在 GitHub Issues 反馈。

# 标准菜单本地化修复设计

## 背景

MarkdownReader 使用自定义 `L10n` 字典处理应用界面和自定义菜单项，但
File、Edit、View、Window、Help 等一级标准菜单由 SwiftUI/AppKit 创建。
主应用 `Info.plist` 将 `CFBundleDevelopmentRegion` 固定为 `zh-Hans`，
且没有声明其他 Bundle 本地化，导致系统找不到英文 Bundle 本地化时回退到简体中文。

## 设计

修复分为两层：

1. 将主 Bundle 的开发语言改为英文，并通过 `CFBundleLocalizations` 声明
   `en`、`zh-Hans`、`zh-Hant`，让 macOS 正确识别应用支持的语言。
2. 增加一个主菜单本地化同步器，在 SwiftUI 创建主菜单后，以及应用内语言偏好变化后，
   将标准一级菜单标题更新为当前 `Language`。自定义 `CommandMenu` 和菜单项继续使用
   现有 `L10n`，不迁移本地化架构。

同步器只修改已知的标准一级菜单标题，不改变菜单结构、命令路由、快捷键或子菜单内容。
它同时更新父 `NSMenuItem.title` 与 AppKit 实际显示的 `submenu.title`。同步器由
`AppDelegate` 在应用启动后启用，并监听 AppKit 菜单新增/变更通知；当 SwiftUI 重建
Commands 时会自动重新应用当前语言。菜单角色可从任一受支持语言的标准标题识别，
因此后续语言切换不依赖某一种初始语言。

## 验证

- 单元测试覆盖英文、简体中文、繁体中文的标准标题映射。
- 单元测试覆盖菜单角色识别在三种语言标题下的一致性。
- 静态回归测试检查 `scripts/Info.plist` 的开发语言和支持语言声明。
- 运行完整 `swift test` 和 `swift build`。
- 生成正式 `.app` 后检查最终 `Contents/Info.plist`。

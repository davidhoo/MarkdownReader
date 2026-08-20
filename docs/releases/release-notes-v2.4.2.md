# Markdown Reader v2.4.2

Raw 编辑器可选源码行号。

## ✨ 新增

### Raw 编辑器可选源码行号
设置 → 外观 → 字体与排版新增「显示源码行号」开关，默认关闭，不改变现有阅读布局。开启后，Raw 模式左侧固定 gutter 显示逻辑源码行号；自动换行的后续 fragment 不重复编号；宽度按文档最大行号位数自适应，滚动时 gutter 宽度保持稳定。行号栏以 Core Animation 覆盖层绘制，通过 text container inset 为文本让出左侧空间，不改写 `NSScrollView.contentView.frame`，避免 SwiftUI 托管下内容不绘制。

## ✅ 测试

- `swift build` / `swift build -c release` 编译通过
- 全部 275 个单元测试通过
- `git diff --check` 无空白错误

## 🖥️ 系统要求

- macOS 26 (Tahoe) 或更高版本
- Apple Silicon 原生支持

---

感谢使用 Markdown Reader！如有问题或建议，欢迎在 GitHub Issues 反馈。

# Markdown Reader v2.2.10

修复设置页 Quick Look 复制格式选择器标签换行的问题。

## 🐛 修复

### Quick Look 复制格式标签换行
设置页「Quick Look 复制格式」项的 segmented picker 此前将标签与选择器同行排列，简中/繁中长标签在 picker 固定宽度下被截断成多行，挤压控件。

- 改为标签与分段选择器上下分行：标签用 12pt muted 文本并允许垂直换行，picker 隐藏自身标签、固定 260pt 宽度，互不挤占
- 选择器仅在「内容一键复制」总开关开启时显示；Quick Look Preview 关闭时仍保留已选格式值，行为不变

## ✅ 测试

- `swift build` 编译通过
- 全部 195 个单元测试保持通过

## 🖥️ 系统要求

- macOS 26 (Tahoe) 或更高版本
- Apple Silicon 原生支持

---

感谢使用 Markdown Reader！如有问题或建议，欢迎在 GitHub Issues 反馈。

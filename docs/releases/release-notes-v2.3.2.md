# Markdown Reader v2.3.2

修复版本：修复渲染模式下「一键复制」图标的比例失真问题。

## 🐛 修复

### 渲染模式复制图标比例失真
渲染页右上角的一键复制图标由 SF Symbol 光栅化后注入 WebView。此前绘制时被强制塞进 14×14 正方形，导致符号的原始纵横比被拉伸变形。

- 改为以 11 pt 配置后的固有尺寸居中绘制于 14 pt 透明画布，不再缩放成正方形
- 保留 SF Symbol 的原始比例，与编辑模式 `.font(.system(size: 11))` 的原生尺寸来源对齐
- `configurationVersion` 递增至 2 以失效旧缓存，确保用户拿到修正后的图标

## ✅ 测试

- `swift build` 与 `swift build -c release` 编译通过
- 全部 196 个单元测试保持通过（新增渲染复制图标比例覆盖测试）

## 🖥️ 系统要求

- macOS 26 (Tahoe) 或更高版本
- Apple Silicon 原生支持

---

感谢使用 Markdown Reader！如有问题或建议，欢迎在 GitHub Issues 反馈。

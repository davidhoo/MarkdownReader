# Markdown Reader v2.4.10

阅读页的 Mermaid 图现在可以换引擎：默认仍是熟悉的 Mermaid.js，也可以改用 Pele，颜色会跟应用主题走。

## ✨ 新增

- 设置 → 通用新增「图表引擎」，默认 Mermaid.js，可选 Pele（1.6.0）
- 两种引擎都读同一段 ` ```mermaid ` 代码块；Pele 同步画成 SVG，颜色跟随主题，节点布局与 Mermaid.js 不同
- 切换引擎后阅读页整页重载以换脚本；Quick Look 读取同一偏好，扩展包同时保留两份脚本
- Pele 不启用图内缩放，正文选择与复制路径不变

## ✅ 测试

- `swift test` 全部 359 个测试通过
- 覆盖引擎脚本选择、无图时不加载、引擎变化强制整页加载与源码模式预热

## 🍺 Homebrew

```bash
brew update && brew upgrade --cask --greedy markdownreader
```

## 🖥️ 系统要求

- macOS 26 (Tahoe) 或更高版本
- Apple Silicon 原生支持

---

感谢使用 Markdown Reader！如有问题或建议，欢迎在 GitHub Issues 反馈。

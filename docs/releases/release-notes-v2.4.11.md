# Markdown Reader v2.4.11

Pele 图表的底色现在贴着当前主题的阅读表面，不再多叠一层偏重的卡片灰。

## 🐛 修复

- Pele 图底色改为跟随主题 `--surface`，节点与分组只轻轻抬起
- 新增 `--diagram-bg` / `--diagram-node` / `--diagram-cluster` 语义色供 Pele CSS 变量读取
- Pele 容器边框改用 `--border-subtle`，与阅读页层次一致

## ✅ 测试

- `swift test` 全部 360 个测试通过
- 新增 `ThemeColorsDiagramTests`：图底色等于表面色、不等于 elevated 卡片色，node/cluster 色阶分离

## 🍺 Homebrew

```bash
brew update && brew upgrade --cask --greedy markdownreader
```

## 🖥️ 系统要求

- macOS 26 (Tahoe) 或更高版本
- Apple Silicon 原生支持

---

感谢使用 Markdown Reader！如有问题或建议，欢迎在 GitHub Issues 反馈。

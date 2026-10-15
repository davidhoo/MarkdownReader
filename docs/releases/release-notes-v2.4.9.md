# Markdown Reader v2.4.9

单独打开一个 Markdown 文件时，现在可以在侧边栏看到它所在目录里的其他 Markdown 文件，方便在相关文档之间切换。

## ✨ 新增

- 设置 → 通用 → 文件树新增「打开单文档时，在侧边栏打开当前目录」（默认关闭）
- 开启后，单独打开文件会在侧边栏展示所在目录及子目录，并高亮当前文件，侧边栏自动展开
- 这个目录树只列 Markdown 文件，图片、`.json` 等其他文件不会出现；「显示隐藏文件」和右键菜单照常可用
- 开关即时生效，已打开的单文档窗口会立刻响应

感谢 @sunvim 贡献此功能（[#20](https://github.com/davidhoo/MarkdownReader/pull/20)）。

## 🐞 修复

- 单文件模式切到目录模式、在侧边栏目录树里切换文件、另存为到新路径后，窗口标题会正确更新，不再停在旧文件名

## ✅ 测试

- `swift test` 全部 354 个测试通过
- 新增 28 个回归用例，覆盖设置默认值与持久化、三语言文案、单文件与目录模式互不干扰、只列 Markdown 的过滤规则、侧边栏真实渲染

## 🍺 Homebrew

```bash
brew update && brew upgrade --cask --greedy markdownreader
```

## 🖥️ 系统要求

- macOS 26 (Tahoe) 或更高版本
- Apple Silicon 原生支持

---

感谢使用 Markdown Reader！如有问题或建议，欢迎在 GitHub Issues 反馈。

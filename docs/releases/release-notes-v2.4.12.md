# Markdown Reader v2.4.12

自定义标题栏改用 macOS 系统原生红绿灯，自动适配 macOS 27 Liquid Glass 外观与原生交互状态，并同步修复构建打包脚本的 Xcode 工具链与签名兼容问题。

## 🐛 修复

- **系统原生红绿灯适配**：标题栏不再隐藏系统按钮改用手绘圆形，改为由 `WindowChromeConfigurator` 居中对齐原生关闭/最小化/缩放按钮并动态计算标题栏留白（全屏自动收起），完整继承原生尺寸、配色、焦点与悬停状态
- **打包脚本兼容修复**：`build-app.sh` 自动探测本机 Xcode 作为 `DEVELOPER_DIR`（解决 `actool` 缺失报错），并在未传 `--sign` 时对 `strip -x` 后的主程序与 Quick Look 扩展补充 ad-hoc 重签名

感谢 @haorui-lab 贡献此修复（[#21](https://github.com/davidhoo/MarkdownReader/pull/21)）。

## 📝 文档

- 同步更新四语言 README（简中 / 繁中 / English / 日本語）与项目官网特性介绍、帮助页及 Homebrew 安装指引

## ✅ 测试

- `swift test` 全部 362 个单元测试通过（新增 `WindowChromeTests` 覆盖原生红绿灯居中、窗口缩放与每窗口全屏留白）
- `scripts/tests/homebrew-cask-sync-test.sh` 40 项全部通过

## 🍺 Homebrew

```bash
brew update && brew upgrade --cask --greedy markdownreader
```

## 🖥️ 系统要求

- macOS 26 (Tahoe) 或更高版本
- Apple Silicon 原生支持

---

感谢使用 Markdown Reader！如有问题或建议，欢迎在 GitHub Issues 反馈。

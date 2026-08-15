# Homebrew Tap 维护流程

本文件固化自建 Tap `davidhoo/homebrew-markdownreader` 的人工更新步骤。每次正式发布 MarkdownReader 新版本后，按本流程更新 Tap，让用户能通过 Homebrew 升级。

## 前提

- Tap 仓库：`davidhoo/homebrew-markdownreader`，默认分支 `main`，含 `Casks/markdownreader.rb` 与 `README.md`。
- Cask 始终指向 GitHub Release 的 `MarkdownReader.dmg`，使用真实 `sha256`，禁止 `:no_check`。
- 不增加 `preflight`/`postflight`/`zap`/`binary`，不执行 `xattr`、`spctl`、`sudo` 或任何自动移除隔离属性的操作。
- Cask 声明 `auto_updates true`（承认应用既有更新能力），用户强制由 Homebrew 升级时使用 `--greedy`。

## 每次发布后的维护步骤

1. 继续按现有流程发布 tag 与 GitHub Release：

   ```bash
   ./release-local.sh X.Y.Z
   ```

2. 确认 Release 已公开，且 `MarkdownReader.dmg` 下载可用：

   ```bash
   gh release view vX.Y.Z --repo davidhoo/MarkdownReader
   ```

3. 下载该 DMG 并计算 SHA-256：

   ```bash
   cd /tmp
   gh release download vX.Y.Z --repo davidhoo/MarkdownReader --pattern "MarkdownReader.dmg" --clobber
   shasum -a 256 MarkdownReader.dmg
   ```

4. 在 `homebrew-markdownreader` 仓库中，**仅**更新 `Casks/markdownreader.rb` 的 `version` 与 `sha256` 两个字段。不要改动 `url`、`livecheck`、`depends_on`、`caveats` 等其他内容，除非确有变更需求。

5. 本地校验：

   ```bash
   brew audit --cask --strict davidhoo/markdownreader/markdownreader
   brew style --cask davidhoo/markdownreader/markdownreader
   ```

   两条命令都应无错误通过。`--strict` 会检查 SHA-256 与 URL 的一致性、caveats 格式、依赖声明等。

6. 提交并推送 Tap：

   ```bash
   git add Casks/markdownreader.rb
   git commit -m "markdownreader X.Y.Z"
   git push origin main
   ```

   推送后，用户执行以下命令即可获取该版本：

   ```bash
   brew update && brew upgrade --cask --greedy markdownreader
   ```

## 验收要点

- `brew info --cask markdownreader` 显示正确版本、DMG URL、架构（arm64）与系统要求（macOS Tahoe）。
- Cask SHA-256 与对应 GitHub Release 的 DMG 完全一致。
- `brew audit --cask --strict` 与 `brew style --cask` 通过。
- 在未安装 MarkdownReader 的环境执行 tap、install 后，`MarkdownReader.app` 被安装到 `/Applications`。
- 发布后续版本并更新 Tap 后，`brew update && brew upgrade --cask --greedy markdownreader` 能识别并升级。
- `brew uninstall --cask markdownreader` 只卸载 App，不删除用户设置、文档或其他数据。

## 不做的事

- 不购买 Apple Developer Program；不做 Developer ID 签名、hardened runtime、公证或 stapling。
- 不提交 `Homebrew/homebrew-cask` 官方仓库。
- 不修改 `release-local.sh`、`build-app.sh`、`.github/workflows/release.yml`。
- 不修改 `UpdateService.swift`、`UpdateViewModel.swift` 或应用内更新策略。
- 不承诺所有 macOS 安全策略、MDM 管理环境或未来系统版本都允许人工放行未公证应用。

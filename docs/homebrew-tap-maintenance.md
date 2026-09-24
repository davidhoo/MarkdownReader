# Homebrew Tap 维护流程

本文件说明自建 Tap `davidhoo/homebrew-markdownreader` 如何跟随正式发布更新。

**硬性要求：每次正式发布新版本后，必须同步更新 `homebrew-markdownreader`。**  
漏掉这一步，Homebrew 用户会一直停在旧版。常规路径是跑 `./release-local.sh X.Y.Z`——脚本在 GitHub Release 公开后会自动同步 Cask；不要只发 GitHub Release 就收工。

## 前提

- Tap 仓库：`davidhoo/homebrew-markdownreader`，默认分支 `main`，含 `Casks/markdownreader.rb` 与 `README.md`。
- 发布所用 `gh` 账号对 Tap 仓库具有 `repo` 写权限（与创建 GitHub Release 的权限要求一致）。
- Cask 始终指向 GitHub Release 的 `MarkdownReader.dmg`，使用真实 `sha256`，禁止 `:no_check`。
- 不增加 `preflight`/`postflight`/`zap`/`binary`，不执行 `xattr`、`spctl`、`sudo` 或任何自动移除隔离属性的操作。
- Cask 声明 `auto_updates true`（承认应用既有更新能力），用户强制由 Homebrew 升级时使用 `--greedy`。

## 每次发布（必做）

1. 按现有流程打 tag 并发布：

   ```bash
   ./release-local.sh X.Y.Z
   ```

   脚本在 Release 公开后会：
   - 计算本地 `MarkdownReader.dmg` 的 SHA-256
   - 更新 Tap 中 `Casks/markdownreader.rb` 的 `version` 与 `sha256`
   - 回读远端 Cask 校验
   - **Tap 同步成功前不会打印发布成功横幅**（`set -e` 下同步失败会使整个 release 命令失败）

2. 用户获取该版本：

   ```bash
   brew update && brew upgrade --cask --greedy markdownreader
   ```

若 GitHub Release 已公开，但 Tap 同步因权限、网络、Cask 形状或校验失败而退出：Release 仍然有效，但本次命令不算端到端成功。修好问题后再次运行同一个 `./release-local.sh X.Y.Z`（会 `--clobber` 上传并重新同步 Tap）。

手工只改 Cask 的 version/SHA **不是**常规流程；仅在自动同步不可用时作应急手段，并随后修通 `release-local.sh`。

## 应急手工更新（仅自动同步失败时）

1. 确认 Release 已公开且 DMG 可下：

   ```bash
   gh release view vX.Y.Z --repo davidhoo/MarkdownReader
   ```

2. 下载 DMG 并算 SHA-256：

   ```bash
   cd /tmp
   gh release download vX.Y.Z --repo davidhoo/MarkdownReader --pattern "MarkdownReader.dmg" --clobber
   shasum -a 256 MarkdownReader.dmg
   ```

3. 在 `homebrew-markdownreader` 中**仅**更新 `Casks/markdownreader.rb` 的 `version` 与 `sha256`。

4. 校验并推送：

   ```bash
   brew audit --cask --strict davidhoo/markdownreader/markdownreader
   brew style --cask davidhoo/markdownreader/markdownreader
   git add Casks/markdownreader.rb
   git commit -m "markdownreader X.Y.Z"
   git push origin main
   ```

## 验收要点

- `brew info --cask markdownreader` 显示正确版本、DMG URL、架构（arm64）与系统要求（macOS Tahoe）。
- Cask SHA-256 与对应 GitHub Release 的 DMG 完全一致。
- `brew audit --cask --strict` 与 `brew style --cask` 通过。
- 在未安装 MarkdownReader 的环境执行 tap、install 后，`MarkdownReader.app` 被安装到 `/Applications`。
- 发布后续版本后，`brew update && brew upgrade --cask --greedy markdownreader` 能识别并升级。
- `brew uninstall --cask markdownreader` 只卸载 App，不删除用户设置、文档或其他数据。

## 不做的事

- 不购买 Apple Developer Program；不做 Developer ID 签名、hardened runtime、公证或 stapling。
- 不提交 `Homebrew/homebrew-cask` 官方仓库。
- 不把 Homebrew 当成主分发渠道；DMG 直装与应用内更新仍保留。
- 不修改 `UpdateService.swift`、`UpdateViewModel.swift` 或应用内更新策略。
- 不承诺所有 macOS 安全策略、MDM 管理环境或未来系统版本都允许人工放行未公证应用。
- **不跳过 Homebrew Tap 同步就宣称发布完成。**

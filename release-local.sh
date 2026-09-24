#!/bin/bash
# 本地构建 + 发布到 GitHub Release
# 用法: ./release-local.sh [版本号]
#   不指定版本号时自动从 git tag 获取
#
# 流程: 本地构建 → 创建 DMG/ZIP → 上传到 GitHub Release
# 绕过 CI 构建，避免 CI 环境差异导致的运行时问题
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MarkdownReader"

# 确定版本号
if [[ $# -gt 0 ]]; then
    VERSION="$1"
else
    VERSION=$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null | sed 's/^v//')
    if [[ -z "$VERSION" ]]; then
        echo "❌ 未找到 git tag，请指定版本号: ./release-local.sh 1.0.9"
        exit 1
    fi
fi
TAG="v${VERSION}"
echo "📌 发布版本: $TAG"

# 验证 CHANGELOG
if ! grep -q "\\[$VERSION\\]" CHANGELOG.md 2>/dev/null && ! grep -q "\\[$TAG\\]" CHANGELOG.md 2>/dev/null; then
    echo "❌ CHANGELOG.md 未包含版本 $VERSION，请先更新"
    exit 1
fi
echo "✅ CHANGELOG.md 已包含版本 $VERSION"

# 1. 本地构建 + 签名（显式传入版本，避免打 tag 前仍写入旧 git tag）
echo ""
echo "🔨 本地构建 ${APP_NAME}..."
./build-app.sh --release --sign --version "$VERSION"

# 2. 创建 DMG
echo ""
echo "📦 创建 DMG..."
DMG_NAME="${APP_NAME}.dmg"
rm -f "$DMG_NAME"

VOLICON="${APP_NAME}.app/Contents/Resources/AppIcon.icns"
if command -v create-dmg &>/dev/null; then
    CREATE_DMG_ARGS=(
        --volname "Markdown Reader"
        --window-pos 200 120
        --window-size 600 400
        --icon-size 100
        --icon "${APP_NAME}.app" 175 190
        --app-drop-link 425 190
    )
    if [ -f "$VOLICON" ]; then
        CREATE_DMG_ARGS+=(--volicon "$VOLICON")
    fi
    create-dmg "${CREATE_DMG_ARGS[@]}" "$DMG_NAME" "${APP_NAME}.app"
else
    STAGING=$(mktemp -d)
    trap "rm -rf '$STAGING'" EXIT
    cp -R "${APP_NAME}.app" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "Markdown Reader" -srcfolder "$STAGING" -ov -format UDZO "$DMG_NAME"
    rm -rf "$STAGING"
    trap - EXIT
fi

# 设置 DMG 图标
xattr -cr "$DMG_NAME" 2>/dev/null || true
if [ -f "$VOLICON" ]; then
    SETICON_BIN="$(dirname "$0")/scripts/.seticon-bin"
    if [ ! -f "$SETICON_BIN" ]; then
        swiftc "$(dirname "$0")/scripts/seticon.swift" -o "$SETICON_BIN"
    fi
    "$SETICON_BIN" "$VOLICON" "$DMG_NAME"
fi

# 3. 创建 ZIP
echo ""
echo "📦 创建 ZIP..."
ZIP_NAME="${APP_NAME}.zip"
rm -f "$ZIP_NAME"
zip -r "$ZIP_NAME" "${APP_NAME}.app"

# 4. 验证
echo ""
echo "🔍 验证构建结果..."
codesign --verify --deep --strict "${APP_NAME}.app" 2>&1
echo "✅ 签名验证通过"
echo "🧪 运行渲染资源门禁验证..."
VERIFY_BIN="$(dirname "$0")/scripts/.verify-render-resources-bin"
if [ ! -f "$VERIFY_BIN" ] || [ "$(dirname "$0")/scripts/verify-render-resources.swift" -nt "$VERIFY_BIN" ] || [ "$(dirname "$0")/Sources/MarkdownReaderKit/Services/MarkdownResourceLocator.swift" -nt "$VERIFY_BIN" ]; then
    swiftc -parse-as-library \
        "$(dirname "$0")/Sources/MarkdownReaderKit/Services/MarkdownResourceLocator.swift" \
        "$(dirname "$0")/scripts/verify-render-resources.swift" \
        -o "$VERIFY_BIN"
fi
"$VERIFY_BIN" "${APP_NAME}.app"
echo "✅ 渲染资源门禁验证通过"

# 5. 创建 GitHub Release
echo ""
echo "🚀 创建 GitHub Release $TAG..."

# 构建 release notes
cat > /tmp/release-body.md << 'BODY'
## 安装说明

1. 下载 `.dmg` 文件，双击打开
2. 将 **Markdown Reader** 拖入 **Applications** 文件夹
3. 首次打开时，macOS 可能提示「无法验证开发者」：
   - 打开 **系统设置 > 隐私与安全性**
   - 找到被阻止的 app，点击 **仍要打开**
   - 或在终端运行：`xattr -cr /Applications/MarkdownReader.app`
4. 也可以直接右键点击 app → 选择 **打开**

---

BODY

# Append changelog
if [ -f "docs/releases/release-notes-${TAG}.md" ]; then
    cat "docs/releases/release-notes-${TAG}.md" >> /tmp/release-body.md
elif [ -f "CHANGELOG.md" ]; then
    awk -v ver="$VERSION" '
      /^## \[/ && section { exit }
      /^## \[/ && $0 ~ "\\[" ver "\\]" { section = 1 }
      section { print }
    ' CHANGELOG.md >> /tmp/release-body.md
fi

# 检查 release 是否已存在
if gh release view "$TAG" &>/dev/null; then
    echo "📝 Release $TAG 已存在，上传产物并更新 notes..."
    gh release upload "$TAG" "$DMG_NAME" "$ZIP_NAME" --clobber
    # --draft=false 确保已存在的草稿 release 在更新后被发布
    gh release edit "$TAG" --draft=false --notes-file /tmp/release-body.md
else
    gh release create "$TAG" \
        --title "$TAG" \
        --notes-file /tmp/release-body.md \
        "$DMG_NAME" \
        "$ZIP_NAME"
fi

# 6. GitHub Release 公开后必须同步 Homebrew Tap（硬性步骤，失败则整体失败）
echo ""
echo "🍺 同步 Homebrew Cask（davidhoo/homebrew-markdownreader）..."
DMG_SHA256="$(shasum -a 256 "$DMG_NAME" | awk '{print $1}')"
# shellcheck source=scripts/homebrew-cask-sync.sh
source "$(cd "$(dirname "$0")" && pwd)/scripts/homebrew-cask-sync.sh"
homebrew_cask_sync "$VERSION" "$DMG_SHA256"
echo "✅ Homebrew Cask 已同步到 v${VERSION}（sha256=${DMG_SHA256}）"

echo ""
echo "🎉 发布完成！"
echo "   DMG: $DMG_NAME ($(du -h "$DMG_NAME" | cut -f1))"
echo "   ZIP: $ZIP_NAME ($(du -h "$ZIP_NAME" | cut -f1))"
echo "   Release: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/$TAG"
echo "   Homebrew: brew update && brew upgrade --cask --greedy markdownreader"

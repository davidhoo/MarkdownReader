#!/bin/bash
# 构建 MarkdownReader.app (Apple Silicon / arm64 only)
# 用法: ./build-app.sh [-r|--release] [-s|--sign [IDENTITY]] [-d|--distribution]
#   --sign       签名 .app（非分发模式自动使用 ad-hoc 签名，可分享给他人）
#   --sign ID    分发模式下使用指定签名身份（如 "Developer ID Application: xxx"）
#   -d           分发模式：启用 hardened runtime + timestamp（需 Developer ID 证书 + 公证）

set -euo pipefail

APP_NAME="MarkdownReader"

# 动态读取版本号（优先级：git tag > CHANGELOG.md > 兜底）
if VERSION=$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null | sed 's/^v//'); then
    echo "📌 版本号来自 git tag: $VERSION"
elif VERSION=$(grep -m1 -o '\[[0-9][0-9.]*\]' CHANGELOG.md 2>/dev/null | tr -d '[]'); then
    echo "📌 版本号来自 CHANGELOG.md: $VERSION"
else
    VERSION="0.0.0-dev"
    echo "⚠️  未找到 git tag 或 CHANGELOG.md，使用兜底版本: $VERSION"
fi
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="debug"
SIGN_IDENTITY=""
DISTRIBUTION=false
ARCH="arm64"

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--release) CONFIG="release" ;;
        -d|--distribution) DISTRIBUTION=true ;;
        -s|--sign)
            if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
                SIGN_IDENTITY="$2"
                shift
            else
                SIGN_IDENTITY="auto"
            fi
            ;;
        *) echo "未知选项: $1"; exit 1 ;;
    esac
    shift
done

echo "🔨 构建 ${APP_NAME} (${CONFIG}, ${ARCH})..."

swift build -c "$CONFIG" --arch arm64

BUILD_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"
OBJECT_DIR="${PROJECT_DIR}/.build/${ARCH}-apple-macosx/${CONFIG}"

# 修补 SPM 生成的 resource_bundle_accessor.swift
# SPM 使用 Bundle.main.bundleURL 查找 bundle，但 macOS .app 的资源在 Contents/Resources/
# 需要替换为 Bundle.main.resourceURL，使 Bundle.module 能在正确路径找到资源 bundle
PATCHED=0
while IFS= read -r accessor; do
    if grep -q 'Bundle\.main\.bundleURL\.appendingPathComponent' "$accessor"; then
        sed -i '' 's/Bundle\.main\.bundleURL\.appendingPathComponent/(Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent/g' "$accessor"
        PATCHED=$((PATCHED + 1))
        echo "📝 修补 Bundle.module 路径: $accessor"
    fi
done < <(find "${OBJECT_DIR}" -name "resource_bundle_accessor.swift" -type f 2>/dev/null)

if [[ "$PATCHED" -gt 0 ]]; then
    echo "🔨 重新编译（应用 Bundle.module 修补）..."
    swift build -c "$CONFIG" --arch arm64
fi

APP_BUNDLE="${PROJECT_DIR}/${APP_NAME}.app"

# 清理旧的
rm -rf "$APP_BUNDLE"

# 创建 .app 目录结构
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 复制可执行文件
cp "${BUILD_DIR}/${APP_NAME}" "$APP_BUNDLE/Contents/MacOS/"

# Strip 主二进制（去除本地符号表，保留外部符号以便动态链接）
# 符号信息仍可通过 dSYM 获取，不影响崩溃符号化
echo "🔪 Strip 主二进制..."
strip -x "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"

# 复制资源 bundle（Swift Package Manager 编译的资源）
if [ -d "${BUILD_DIR}/${APP_NAME}_MarkdownReader.bundle" ]; then
    cp -R "${BUILD_DIR}/${APP_NAME}_MarkdownReader.bundle" "$APP_BUNDLE/Contents/Resources/"

    # 移除 SPM bundle 中的 AppIcon（已通过 actool 编译到 Assets.car 中提供，无需重复）
    SPM_BUNDLE="${APP_BUNDLE}/Contents/Resources/${APP_NAME}_MarkdownReader.bundle"
    if [ -d "${SPM_BUNDLE}/Assets.xcassets/AppIcon.appiconset" ]; then
        rm -rf "${SPM_BUNDLE}/Assets.xcassets/AppIcon.appiconset"
        # 如果 Assets.xcassets 目录已空（只剩 Contents.json），也一并移除
        remaining=$(find "${SPM_BUNDLE}/Assets.xcassets" -mindepth 1 -not -name "Contents.json" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$remaining" -eq 0 ]; then
            rm -rf "${SPM_BUNDLE}/Assets.xcassets"
        fi
        echo "🗑️  移除 SPM bundle 中冗余 AppIcon（已通过 Assets.car 提供）"
    fi
fi

# 复制依赖包的资源 bundle（Textual 的 prism-bundle.js 等）
for bundle in "${BUILD_DIR}"/*.bundle; do
    bundle_name=$(basename "$bundle")
    if [[ "$bundle_name" != "${APP_NAME}_MarkdownReader.bundle" ]]; then
        cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
        echo "📦 复制依赖资源: $bundle_name"
    fi
done

# 使用 actool 编译 Assets.xcassets（确保图标正确显示）
# macOS 系统需要编译后的 Assets.car 来识别应用图标，SPM bundle 中的原始 PNG 不够
ASSETS_SRC="${PROJECT_DIR}/Sources/${APP_NAME}/Assets.xcassets"
if [ -d "$ASSETS_SRC" ]; then
    echo "📦 编译 Assets.xcassets..."
    actool \
        --compile "$APP_BUNDLE/Contents/Resources" \
        --platform macosx \
        --minimum-deployment-target 26 \
        --app-icon AppIcon \
        --output-format human-readable-text \
        --output-partial-info-plist /tmp/markdownreader_partial.plist \
        "$ASSETS_SRC" 2>/dev/null || echo "⚠️  actool 编译失败，图标可能不显示（不影响功能）"
fi

# 从模板生成 Info.plist（与 CI 流程共用同一模板）
PLIST_TEMPLATE="${PROJECT_DIR}/scripts/Info.plist"
if [ -f "$PLIST_TEMPLATE" ]; then
    sed "s/__VERSION__/$VERSION/g" "$PLIST_TEMPLATE" > "$APP_BUNDLE/Contents/Info.plist"
    echo "📝 Info.plist 从模板生成 (版本: $VERSION)"
else
    echo "❌ 未找到 Info.plist 模板: $PLIST_TEMPLATE"
    exit 1
fi

# 创建 PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# 解析签名身份（需要在 Extension 签名之前完成）
if [[ -n "$SIGN_IDENTITY" ]]; then
    if $DISTRIBUTION; then
        # 分发模式：需要真实的 Developer ID 证书
        if [[ "$SIGN_IDENTITY" == "auto" ]]; then
            SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -n 's/.*"\(.*\)"/\1/p' || true)
            if [[ -z "$SIGN_IDENTITY" ]]; then
                echo "❌ 分发模式需要 Developer ID Application 证书，未找到"
                exit 1
            fi
            echo "🔑 自动检测到签名身份: $SIGN_IDENTITY"
        fi
    else
        # 开发模式：如果指定了签名身份则使用，否则 ad-hoc
        if [[ "$SIGN_IDENTITY" == "auto" ]]; then
            # 优先查找 Apple Development / Developer ID Application 证书
            RESOLVED_IDENTITY=$(security find-identity -v -p codesigning | grep -E "Apple Development|Developer ID Application" | head -1 | sed -n 's/.*"\(.*\)"/\1/p' || true)
            if [[ -n "$RESOLVED_IDENTITY" ]]; then
                SIGN_IDENTITY="$RESOLVED_IDENTITY"
                echo "🔑 开发模式: 使用检测到的签名身份: $SIGN_IDENTITY"
            else
                SIGN_IDENTITY="-"
                echo "🔑 开发/分享模式: 未找到证书，使用 ad-hoc 签名"
            fi
        else
            echo "🔑 开发模式: 使用指定签名身份"
        fi
    fi
fi

# MARK: - Quick Look Extension

QL_EXT_NAME="MarkdownReaderQL"
QL_APPEX="${APP_BUNDLE}/Contents/PlugIns/${QL_EXT_NAME}.appex"
QL_BINARY="${QL_APPEX}/Contents/MacOS/${QL_EXT_NAME}"

mkdir -p "${QL_APPEX}/Contents/MacOS"
mkdir -p "${QL_APPEX}/Contents/Resources"

# 链接 Extension 可执行文件
# SPM regular target 不产生可执行文件，需要手动链接。
# 关键：App Extension 的入口点必须是 _NSExtensionMain（而非 _main），
# 所以使用 -e _NSExtensionMain -u _NSExtensionMain 让链接器直接以
# AppKit 的 NSExtensionMain 作为入口点（与 XMind 等第三方 QL Extension 一致）。
# 不使用 C wrapper（main → NSExtensionMain），因为那样会产生 _main 符号，
# 而 macOS Quick Look 系统期望入口点直接是 _NSExtensionMain。
CLANG=$(xcrun -f clang)
SDK=$(xcrun --show-sdk-path)

QL_OBJECTS="${OBJECT_DIR}/${QL_EXT_NAME}.build"
KIT_OBJECTS="${OBJECT_DIR}/MarkdownReaderKit.build"

# 收集所有依赖的 .o 文件（cmark_gfm, cmark_gfm_extensions, CAtomic, Markdown）
DEP_OBJS=()
for dep_dir in "${OBJECT_DIR}/cmark_gfm.build" \
               "${OBJECT_DIR}/cmark_gfm_extensions.build" \
               "${OBJECT_DIR}/CAtomic.build" \
               "${OBJECT_DIR}/Markdown.build"; do
    if [ -d "$dep_dir" ]; then
        for obj in "$dep_dir"/*.o; do
            [ -f "$obj" ] && DEP_OBJS+=("$obj")
        done
    fi
done

if [ -d "$QL_OBJECTS" ] && [ -d "$KIT_OBJECTS" ]; then
    echo "🔧 链接 Quick Look Extension (entry: NSExtensionMain)..."
    SWIFT_LIB_DIR="$(xcrun -f swiftc 2>/dev/null | xargs dirname)/../lib/swift/macosx"
    "$CLANG" -arch arm64 \
        -e _NSExtensionMain \
        -u _NSExtensionMain \
        -isysroot "$SDK" \
        -framework AppKit -framework QuickLookUI -framework WebKit \
        -framework Foundation -framework CoreFoundation \
        -framework SwiftUI -framework UniformTypeIdentifiers \
        -o "$QL_BINARY" \
        "${QL_OBJECTS}/"*.o \
        "${KIT_OBJECTS}/"*.o \
        "${DEP_OBJS[@]}" \
        -rpath @executable_path/../Frameworks \
        -rpath /usr/lib/swift \
        -L "${BUILD_DIR}" \
        -L "$SWIFT_LIB_DIR" \
        -lswiftCompatibility56 -lswiftCompatibilityConcurrency \
        -lm -lSystem \
        2>&1

    if [ -f "$QL_BINARY" ]; then
        # Strip Extension 二进制（去除本地符号表）
        echo "🔪 Strip Extension 二进制..."
        strip -x "$QL_BINARY"
        echo "   ✅ Extension 可执行文件已生成"
        # 验证入口点（_NSExtensionMain 是外部符号，U = undefined，来自 AppKit）
        # 验证入口点 — _NSExtensionMain 在链接后为 U（undefined external），
        # 运行时从 AppKit 解析；nm 输出可能包含多余空白，需去除
        if nm "$QL_BINARY" | tr -d ' ' | grep -q "_NSExtensionMain"; then
            echo "   ✅ 入口点 _NSExtensionMain 已确认"
        else
            echo "   ⚠️  nm 未检测到 _NSExtensionMain（可能被 strip，但不影响运行）"
        fi
        # 确认没有 _main 符号（App Extension 入口点应为 _NSExtensionMain，不是 _main）
        if nm "$QL_BINARY" | grep -q " _main$"; then
            echo "   ⚠️  存在 _main 符号，Extension 可能无法被 QL 正确加载"
        fi
    else
        echo "   ❌ Extension 链接失败"
    fi
else
    echo "⚠️  未找到 Extension 目标文件: $QL_OBJECTS"
fi

# 复制主应用的资源 bundle 到 Extension（Extension 运行在独立进程中，无法直接访问主 app 的资源）
if [ -d "${BUILD_DIR}/${APP_NAME}_MarkdownReader.bundle" ]; then
    cp -R "${BUILD_DIR}/${APP_NAME}_MarkdownReader.bundle" "${QL_APPEX}/Contents/Resources/"

    # QL Extension 不需要 AppIcon（Extension 不显示自己的图标）
    QL_BUNDLE="${QL_APPEX}/Contents/Resources/${APP_NAME}_MarkdownReader.bundle"
    if [ -d "${QL_BUNDLE}/Assets.xcassets/AppIcon.appiconset" ]; then
        rm -rf "${QL_BUNDLE}/Assets.xcassets/AppIcon.appiconset"
        remaining=$(find "${QL_BUNDLE}/Assets.xcassets" -mindepth 1 -not -name "Contents.json" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$remaining" -eq 0 ]; then
            rm -rf "${QL_BUNDLE}/Assets.xcassets"
        fi
        echo "🗑️  移除 QL Extension bundle 中冗余 AppIcon"
    fi

    # QL Extension 不需要 mermaid（Quick Look 预览不渲染复杂图表，省 3.1 MB）
    if [ -f "${QL_BUNDLE}/Resources/js/mermaid.min.js" ]; then
        rm -f "${QL_BUNDLE}/Resources/js/mermaid.min.js"
        echo "🗑️  移除 QL Extension bundle 中 mermaid.min.js（省 ~3.1 MB）"
    fi
fi

# 复制依赖包的资源 bundle 到 Extension
for bundle in "${BUILD_DIR}"/*.bundle; do
    bundle_name=$(basename "$bundle")
    if [[ "$bundle_name" != "${APP_NAME}_MarkdownReader.bundle" ]]; then
        cp -R "$bundle" "${QL_APPEX}/Contents/Resources/"
    fi
done

# 生成 Extension Info.plist
QL_PLIST_TEMPLATE="${PROJECT_DIR}/scripts/Info-QL.plist"
if [ -f "$QL_PLIST_TEMPLATE" ]; then
    sed "s/__VERSION__/$VERSION/g" "$QL_PLIST_TEMPLATE" > "${QL_APPEX}/Contents/Info.plist"
    echo "📝 Quick Look Extension Info.plist 从模板生成 (版本: $VERSION)"
else
    echo "❌ 未找到 Quick Look Extension Info.plist 模板: $QL_PLIST_TEMPLATE"
    exit 1
fi

# Extension PkgInfo
echo -n "XPC????" > "${QL_APPEX}/Contents/PkgInfo"

# 签名 Extension（必须在签名主 app 之前单独签名）
# macOS 要求 App Extension 必须有沙盒 entitlement
QL_ENTITLEMENTS="${PROJECT_DIR}/scripts/MarkdownReaderQL.entitlements"
if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "🔏 签名 Quick Look Extension..."
    if $DISTRIBUTION; then
        codesign --force --options runtime --timestamp --entitlements "$QL_ENTITLEMENTS" --sign "$SIGN_IDENTITY" "${QL_APPEX}"
    else
        codesign --force --entitlements "$QL_ENTITLEMENTS" --sign "$SIGN_IDENTITY" "${QL_APPEX}"
    fi
    echo "   Quick Look Extension 已签名"
fi

# 签名
if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "🔏 签名 ${APP_NAME}.app..."

    if $DISTRIBUTION; then
        # 分发签名：使用 Developer ID 证书 + hardened runtime + timestamp
        # 需要配合 notarytool 公证后才能在其他 Mac 上正常启动
        # 注意：不使用 --deep，因为 --deep 会覆盖 Extension 的 entitlements
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
        echo "   模式: 分发 (hardened runtime + timestamp)"
    else
        # 开发/分享签名
        # 注意：不使用 --deep，因为 --deep 会覆盖 Extension 的 entitlements
        codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
        if [[ "$SIGN_IDENTITY" == "-" ]]; then
            echo "   模式: 开发/分享 (ad-hoc 签名)"
        else
            echo "   模式: 开发 (签名身份: $SIGN_IDENTITY)"
        fi
    fi

    echo "🔍 验证签名..."
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1

    echo ""
    echo "✅ ${APP_NAME}.app 已签名: ${APP_BUNDLE}"
    if $DISTRIBUTION; then
        echo "   签名身份: ${SIGN_IDENTITY}"
    else
        echo "   签名身份: ad-hoc (-)"
    fi
    if ! $DISTRIBUTION; then
        echo ""
        echo "   📋 分享给他人时，对方需要："
        echo "      右键点击 app → 打开 → 确认打开"
        echo "      或终端执行: xattr -cr /path/to/${APP_NAME}.app"
    fi
else
    echo ""
    echo "✅ ${APP_NAME}.app 已生成: ${APP_BUNDLE}"
    echo "   ⚠️  未签名 — 分发时接收方需右键打开绕过 Gatekeeper"
fi

echo "   运行: open ${APP_BUNDLE}"

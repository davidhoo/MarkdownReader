import SwiftUI

// MARK: - 主题颜色令牌

/// 从 ThemeDefinition 派生的颜色令牌，参照 buddy-macos 的 deriveTokens()
/// 用于通过 SwiftUI Environment 传递到所有视图
public struct ThemeColors: Equatable, Sendable {
    // 核心色
    public let surface: Color
    public let ink: Color
    public let accent: Color
    public let success: Color
    public let danger: Color

    // 派生背景色
    public let bgElevated: Color
    public let bgSubtle: Color
    public let bgMuted: Color

    // 派生文字色
    public let fgSecondary: Color
    public let fgMuted: Color

    // 派生强调色
    public let accentHover: Color
    public let accentSoft: Color

    // 派生边框色
    public let border: Color
    public let borderSubtle: Color

    // 排版变量（CSS 原始值，nil = 使用 markdown.css 默认值）
    public let bodyFontFamily: String?
    public let headingFontFamily: String?
    public let codeFontFamily: String?
    public let bodyFontSize: String?
    public let lineHeight: String?
    public let letterSpacing: String?
    public let borderRadius: String?

    // MARK: - CSS Custom Properties

    public var cssCustomProperties: String {
        let surfaceNS = NSColor(surface).usingColorSpace(.sRGB) ?? NSColor.black
        let inkNS = NSColor(ink).usingColorSpace(.sRGB) ?? NSColor.white
        let isDark = surfaceNS.perceivedBrightness < inkNS.perceivedBrightness
        // 图表底色贴着阅读表面。节点和分组只轻轻抬起，避免再叠一层偏重的卡片灰。
        let diagramNode = cssHex(surface.mixed(with: ink, fraction: isDark ? 0.06 : 0.04))
        let diagramCluster = cssHex(surface.mixed(with: ink, fraction: isDark ? 0.035 : 0.02))
        var css = """
        :root {
          --surface: \(cssHex(surface));
          --ink: \(cssHex(ink));
          --accent: \(cssHex(accent));
          --success: \(cssHex(success));
          --danger: \(cssHex(danger));
          --bg-elevated: \(cssHex(bgElevated));
          --bg-subtle: \(cssHex(bgSubtle));
          --bg-muted: \(cssHex(bgMuted));
          --fg-secondary: \(cssRGBA(fgSecondary));
          --fg-muted: \(cssRGBA(fgMuted));
          --accent-hover: \(cssHex(accentHover));
          --accent-soft: \(cssRGBA(accentSoft));
          --border: \(cssRGBA(border));
          --border-subtle: \(cssRGBA(borderSubtle));
          --diagram-bg: \(cssHex(surface));
          --diagram-node: \(diagramNode);
          --diagram-cluster: \(diagramCluster);
        """
        if let bodyFontFamily { css += "\n  --font-body: \(bodyFontFamily);" }
        if let headingFontFamily { css += "\n  --font-heading: \(headingFontFamily);" }
        if let codeFontFamily { css += "\n  --font-code: \(codeFontFamily);" }
        if let bodyFontSize { css += "\n  --font-size-base: \(bodyFontSize);" }
        if let lineHeight { css += "\n  --line-height: \(lineHeight);" }
        if let letterSpacing { css += "\n  --letter-spacing: \(letterSpacing);" }
        if let borderRadius { css += "\n  --border-radius: \(borderRadius);" }
        css += "\n}\n"
        return css
    }

    private func cssHex(_ color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        let r = Int(nsColor.redComponent * 255)
        let g = Int(nsColor.greenComponent * 255)
        let b = Int(nsColor.blueComponent * 255)
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    private func cssRGBA(_ color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        let r = Int(nsColor.redComponent * 255)
        let g = Int(nsColor.greenComponent * 255)
        let b = Int(nsColor.blueComponent * 255)
        let a = nsColor.alphaComponent
        return "rgba(\(r), \(g), \(b), \(String(format: "%.2f", a)))"
    }

    // MARK: - 代码块语法高亮主题（WebView 版）

    public var codeHighlightCSS: String {
        let surfaceNS = NSColor(surface).usingColorSpace(.sRGB) ?? NSColor.black
        let inkNS = NSColor(ink).usingColorSpace(.sRGB) ?? NSColor.white
        let accentNS = NSColor(accent).usingColorSpace(.sRGB) ?? NSColor.blue
        let successNS = NSColor(success).usingColorSpace(.sRGB) ?? NSColor.green
        let dangerNS = NSColor(danger).usingColorSpace(.sRGB) ?? NSColor.red

        let isDark = surfaceNS.perceivedBrightness < inkNS.perceivedBrightness

        let codeFg = isDark ? cssHex(ink.opacity(0.85)) : cssHex(ink.opacity(0.88))
        let codeBg = isDark
            ? cssHex(surface.mixed(with: ink, fraction: 0.06))
            : cssHex(surface.mixed(with: ink, fraction: 0.04))
        let keyword = cssHex(accent)
        let string = isDark ? cssHex(success.lighter(by: 0.15)) : cssHex(Color(nsColor: successNS.blended(with: 0.15, of: inkNS) ?? successNS))
        let number = cssHex(Color(nsColor: accentNS.blended(with: 0.25, of: dangerNS) ?? accentNS))
        let comment = cssRGBA(fgMuted)
        let functionName = cssHex(Color(nsColor: accentNS.blended(with: 0.4, of: inkNS) ?? accentNS))
        let variable = cssHex(Color(nsColor: inkNS.blended(with: 0.15, of: successNS) ?? inkNS))
        let className = cssHex(success)
        let tag = cssHex(Color(nsColor: accentNS.blended(with: 0.4, of: successNS) ?? accentNS))
        let attr = cssHex(Color(nsColor: accentNS.blended(with: 0.3, of: dangerNS) ?? accentNS))
        let deleted = cssHex(danger)
        let inserted = cssHex(success)

        return """
        pre { color: \(codeFg); background: \(codeBg); }
        .token.keyword { color: \(keyword); font-weight: 600; }
        .token.string, .token.regex { color: \(string); }
        .token.number { color: \(number); }
        .token.comment, .token.block-comment, .token.doc-comment { color: \(comment); font-style: italic; }
        .token.function, .token.function-name { color: \(functionName); }
        .token.variable, .token.constant, .token.property { color: \(variable); }
        .token.class-name { color: \(className); }
        .token.tag { color: \(tag); }
        .token.attr-value, .token.attribute { color: \(attr); }
        .token.deleted { color: \(deleted); }
        .token.inserted { color: \(inserted); }
        .token.boolean { color: \(keyword); font-weight: 600; }
        .token.builtin { color: \(cssHex(Color(nsColor: accentNS.blended(with: 0.3, of: inkNS) ?? accentNS))); }
        .token.operator, .token.punctuation { color: \(codeFg); }
        """
    }

    /// 从 ThemeDefinition 和对比度派生颜色
    public static func from(_ theme: ThemeDefinition) -> ThemeColors {
        let c = Double(theme.contrast) / 100.0
        let isDark = theme.type == .dark

        let surface = Color(hex: theme.surface) ?? .black
        let ink = Color(hex: theme.ink) ?? .white
        let accent = Color(hex: theme.accent) ?? .blue
        let success = Color(hex: theme.success) ?? .green
        let danger = Color(hex: theme.danger) ?? .red

        return ThemeColors(
            surface: surface,
            ink: ink,
            accent: accent,
            success: success,
            danger: danger,
            bgElevated: isDark
                ? surface.mixed(with: ink, fraction: 0.08 + c * 0.08)
                : surface.mixed(with: ink, fraction: 0.16 + c * 0.12),
            bgSubtle: isDark
                ? surface.mixed(with: ink, fraction: 0.02 + c * 0.02)
                : surface.mixed(with: ink, fraction: 0.08 + c * 0.08),
            bgMuted: isDark
                ? surface.mixed(with: ink, fraction: 0.04 + c * 0.03)
                : surface.mixed(with: ink, fraction: 0.12 + c * 0.10),
            fgSecondary: ink.opacity(0.65 + c * 0.10),
            fgMuted: isDark
                ? ink.opacity(0.42 + c * 0.13)
                : ink.opacity(0.45 + c * 0.10),
            accentHover: isDark
                ? accent.lighter(by: 0.12)
                : accent.darker(by: 0.08),
            accentSoft: isDark
                ? Color.black.mixed(with: accent, fraction: 0.20 + c * 0.08)
                : surface.mixed(with: accent, fraction: 0.11 + c * 0.04),
            border: ink.opacity(0.06 + c * 0.04),
            borderSubtle: ink.opacity(0.04 + c * 0.02),
            bodyFontFamily: theme.bodyFontFamily,
            headingFontFamily: theme.headingFontFamily,
            codeFontFamily: theme.codeFontFamily,
            bodyFontSize: theme.bodyFontSize,
            lineHeight: theme.lineHeight,
            letterSpacing: theme.letterSpacing,
            borderRadius: theme.borderRadius
        )
    }
}

// MARK: - SwiftUI Environment 支持

private struct ThemeColorsKey: EnvironmentKey {
    static let defaultValue = ThemeColors.from(
        ThemeDefinition(id: "buddy-dark", name: "Default Dark", type: .dark,
                        surface: "#18181a", ink: "#e8e8e3", accent: "#339cff",
                        success: "#40c977", danger: "#fa423e", contrast: 60)
    )
}

extension EnvironmentValues {
    public var themeColors: ThemeColors {
        get { self[ThemeColorsKey.self] }
        set { self[ThemeColorsKey.self] = newValue }
    }
}

extension View {
    public func applyThemeColors(_ colors: ThemeColors) -> some View {
        environment(\.themeColors, colors)
    }
}

// MARK: - Color 混合辅助

extension Color {
    /// 将两个颜色按比例混合
    public func mixed(with other: Color, fraction: Double) -> Color {
        let selfNS = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.black
        let otherNS = NSColor(other).usingColorSpace(.sRGB) ?? NSColor.white
        let r = selfNS.redComponent * (1 - fraction) + otherNS.redComponent * fraction
        let g = selfNS.greenComponent * (1 - fraction) + otherNS.greenComponent * fraction
        let b = selfNS.blueComponent * (1 - fraction) + otherNS.blueComponent * fraction
        return Color(red: r, green: g, blue: b)
    }

    /// 变亮
    public func lighter(by amount: Double) -> Color {
        mixed(with: .white, fraction: amount)
    }

    /// 变暗
    public func darker(by amount: Double) -> Color {
        mixed(with: .black, fraction: amount)
    }
}

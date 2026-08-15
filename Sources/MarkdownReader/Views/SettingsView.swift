import SwiftUI
import MarkdownReaderKit

// MARK: - 设置视图组件

/// 设置视图的内容组件，由 ContentView 在设置模式下使用
/// 包含通用设置和外观设置两个子视图
/// 参照 buddy-macos SettingsContent 的布局

// MARK: - 通用设置视图

struct GeneralSettingsView: View {
    @Bindable var settings: SettingsModel
    let language: Language
    @Environment(\.themeColors) private var themeColors
    @State private var showSetDefaultFailed = false
    @State private var isSettingDefault = false
    @State private var isTogglingCommandLine = false
    @State private var showCommandLineFailed = false
    @State private var commandLineErrorMessage = ""
    private let commandLineService = CommandLineService()

    private var detectedLanguageName: String {
        LanguageService.detectLanguage().localizedName(language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 界面语言
            SettingsSection(
                title: L10n.tr(.settingsGeneralLanguageTitle, language: language),
                description: L10n.tr(.settingsGeneralLanguageDesc, language: language)
            ) {
                Picker("", selection: $settings.languagePref) {
                    ForEach(LanguagePref.allCases) { pref in
                        if pref == .auto {
                            Text("\(L10n.tr(.languageAuto, language: language)) (\(detectedLanguageName))")
                                .tag(pref)
                        } else {
                            Text(L10n.tr(LanguagePref.languageKey(for: pref), language: language))
                                .tag(pref)
                        }
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200, alignment: .leading)
            }

            SettingsDivider()

            // 默认显示模式
            SettingsSection(
                title: L10n.tr(.settingsGeneralDisplayMode, language: language)
            ) {
                HStack(spacing: 12) {
                    Picker("", selection: $settings.defaultDisplayMode) {
                        Text(L10n.tr(.displayModeRendered, language: language)).tag(DisplayMode.rendered)
                        Text(L10n.tr(.displayModeRaw, language: language)).tag(DisplayMode.raw)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)

                    // 常驻显示：进入编辑模式时是否默认开启分栏预览
                    Toggle(L10n.tr(.settingsGeneralDefaultSplitPreview, language: language), isOn: $settings.defaultSplitPreview)
                }
            }

            SettingsDivider()

            // 渲染宽度
            SettingsSection(
                title: L10n.tr(.settingsGeneralRenderedWidthTitle, language: language),
                description: L10n.tr(.settingsGeneralRenderedWidthDesc, language: language)
            ) {
                Toggle(L10n.tr(.settingsGeneralMaxWidthFollowsWindow, language: language), isOn: $settings.maxContentWidthFollowsWindow)
            }

            SettingsDivider()

            // 启动行为
            SettingsSection(
                title: L10n.tr(.settingsGeneralStartupTitle, language: language)
            ) {
                Toggle(L10n.tr(.settingsGeneralReopenLastLocation, language: language), isOn: $settings.reopenLastLocation)
            }

            SettingsDivider()

            // 文件树过滤
            SettingsSection(
                title: L10n.tr(.settingsGeneralFileTreeTitle, language: language)
            ) {
                Toggle(L10n.tr(.settingsGeneralShowHiddenFiles, language: language), isOn: $settings.showHiddenFiles)
                Toggle(L10n.tr(.settingsGeneralShowNonMarkdownFiles, language: language), isOn: $settings.showNonMarkdownFiles)
            }

            SettingsDivider()

            // 默认打开程序
            SettingsSection(
                title: L10n.tr(.settingsGeneralDefaultOpenerTitle, language: language),
                description: L10n.tr(.settingsGeneralDefaultOpenerDesc, language: language)
            ) {
                if settings.isDefaultMdOpener {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.green)
                        Text(L10n.tr(.settingsGeneralIsDefault, language: language))
                            .font(.system(size: 12))
                    }
                } else {
                    Button {
                        isSettingDefault = true
                        settings.setAsDefaultMdOpener { success in
                            isSettingDefault = false
                            if !success {
                                showSetDefaultFailed = true
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isSettingDefault {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "doc.text")
                            }
                            Text(L10n.tr(.settingsGeneralSetAsDefault, language: language))
                        }
                    }
                    .disabled(isSettingDefault)
                    .alert(
                        L10n.tr(.settingsGeneralDefaultOpenerTitle, language: language),
                        isPresented: $showSetDefaultFailed
                    ) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(L10n.tr(.settingsGeneralSetDefaultFailed, language: language))
                    }
                }
            }

            SettingsDivider()

            // 内容一键复制
            SettingsSection(
                title: L10n.tr(.settingsGeneralContentCopyTitle, language: language),
                description: nil
            ) {
                Toggle(
                    L10n.tr(.settingsGeneralContentCopyEnabled, language: language),
                    isOn: $settings.enableDocumentCopy
                )
            }

            SettingsDivider()

            // Quick Look 预览
            SettingsSection(
                title: L10n.tr(.settingsGeneralQuickLookTitle, language: language),
                description: L10n.tr(.settingsGeneralQuickLookDesc, language: language)
            ) {
                Toggle(
                    L10n.tr(.settingsGeneralQuickLookEnabled, language: language),
                    isOn: $settings.enableQuickLookPreview
                )

                // 总开关打开时，在启用 Toggle 下方显示 Quick Look 复制格式选择器；
                // Quick Look Preview 自身关闭时，格式选择仍显示并保留已选值。
                // 标签与 segmented picker 分行：避免长标签被固定宽度 picker 截断成多行。
                if settings.enableDocumentCopy {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.tr(.settingsGeneralQuickLookCopyFormat, language: language))
                            .font(.system(size: 12))
                            .foregroundStyle(themeColors.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Picker(
                            "",
                            selection: $settings.quickLookDocumentCopyFormat
                        ) {
                            Text(L10n.tr(.quickLookCopyFormatRichText, language: language))
                                .tag(QuickLookDocumentCopyFormat.richText)
                            Text(L10n.tr(.quickLookCopyFormatRawMarkdown, language: language))
                                .tag(QuickLookDocumentCopyFormat.rawMarkdown)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)
                    }
                }
            }

            SettingsDivider()

            // 命令行工具
            SettingsSection(
                title: L10n.tr(.settingsGeneralCommandLineTitle, language: language),
                description: L10n.tr(.settingsGeneralCommandLineDesc, language: language)
            ) {
                HStack(spacing: 8) {
                    Toggle(
                        settings.enableCommandLine
                            ? L10n.tr(.settingsGeneralCommandLineInstalled, language: language)
                            : L10n.tr(.settingsGeneralCommandLineTitle, language: language),
                        isOn: Binding(
                            get: { settings.enableCommandLine },
                            set: { newValue in toggleCommandLine(newValue) }
                        )
                    )
                    .disabled(isTogglingCommandLine)

                    if isTogglingCommandLine {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .alert(
                    L10n.tr(.settingsGeneralCommandLineTitle, language: language),
                    isPresented: $showCommandLineFailed
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(commandLineErrorMessage)
                }
            }
        }
        .padding(24)
        .onAppear {
            settings.refreshDefaultOpenerStatus()
            settings.enableCommandLine = commandLineService.isInstalled
        }
    }

    private func toggleCommandLine(_ enable: Bool) {
        isTogglingCommandLine = true
        if enable {
            commandLineService.install { [weak settings] success in
                isTogglingCommandLine = false
                if success {
                    settings?.enableCommandLine = true
                } else {
                    settings?.enableCommandLine = false
                    commandLineErrorMessage = L10n.tr(.settingsGeneralCommandLineInstallFailed, language: language)
                    showCommandLineFailed = true
                }
            }
        } else {
            commandLineService.uninstall { [weak settings] success in
                isTogglingCommandLine = false
                if success {
                    settings?.enableCommandLine = false
                } else {
                    settings?.enableCommandLine = true
                    commandLineErrorMessage = L10n.tr(.settingsGeneralCommandLineUninstallFailed, language: language)
                    showCommandLineFailed = true
                }
            }
        }
    }
}

// MARK: - 外观设置视图

/// 参照 buddy-macos AppearanceSettings，包含主题模式、配色方案、自定义颜色、对比度
struct AppearanceSettingsView: View {
    @Bindable var settings: SettingsModel
    let language: Language
    @Environment(\.themeColors) private var themeColors

    /// 当前可用配色方案列表（根据解析后的主题类型动态变化）
    private var availableSchemes: [ThemeDefinition] {
        PresetThemes.themesByType(settings.resolvedThemeType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 主题模式
            themeModeSection

            SettingsDivider()

            // 配色方案
            colorSchemeSection

            SettingsDivider()

            // 自定义颜色
            customColorsSection

            SettingsDivider()

            // 对比度
            contrastSection

            SettingsDivider()

            // 字体排版
            typographySection
        }
        .padding(24)
    }

    // MARK: - 主题模式

    private var themeModeSection: some View {
        SettingsSection(
            title: L10n.tr(.settingsAppearanceThemeTitle, language: language),
            description: L10n.tr(.settingsAppearanceThemeDesc, language: language)
        ) {
            HStack(spacing: 12) {
                ThemeModeCard(
                    mode: .light,
                    icon: "sun.max",
                    title: L10n.tr(.settingsAppearanceModeLight, language: language),
                    description: L10n.tr(.settingsAppearanceModeLightDesc, language: language),
                    isSelected: settings.appearanceMode == .light,
                    language: language
                ) { settings.appearanceMode = .light }

                ThemeModeCard(
                    mode: .dark,
                    icon: "moon",
                    title: L10n.tr(.settingsAppearanceModeDark, language: language),
                    description: L10n.tr(.settingsAppearanceModeDarkDesc, language: language),
                    isSelected: settings.appearanceMode == .dark,
                    language: language
                ) { settings.appearanceMode = .dark }

                ThemeModeCard(
                    mode: .system,
                    icon: "desktopcomputer",
                    title: L10n.tr(.settingsAppearanceModeSystem, language: language),
                    description: L10n.tr(.settingsAppearanceModeSystemDesc, language: language),
                    isSelected: settings.appearanceMode == .system,
                    language: language
                ) { settings.appearanceMode = .system }
            }
        }
        .onChange(of: settings.appearanceMode) { _, newValue in
            applyAppearance(newValue)
        }
    }

    // MARK: - 配色方案

    private var colorSchemeSection: some View {
        SettingsSection(
            title: L10n.tr(.settingsAppearanceSchemeTitle, language: language),
            description: L10n.tr(.settingsAppearanceSchemeDesc, language: language)
        ) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                ForEach(availableSchemes) { theme in
                    ColorSchemeCard(
                        theme: theme,
                        isSelected: settings.currentBaseTheme.id == theme.id,
                        language: language
                    ) {
                        selectScheme(theme)
                    }
                }
            }
        }
    }

    // MARK: - 自定义颜色

    private var customColorsSection: some View {
        SettingsSection(
            title: L10n.tr(.settingsAppearanceCustomTitle, language: language),
            description: L10n.tr(.settingsAppearanceCustomDesc, language: language)
        ) {
            VStack(spacing: 8) {
                ColorBarRow(
                    label: L10n.tr(.settingsAppearanceCustomSurface, language: language),
                    hexValue: settings.resolvedTheme.surface,
                    isCustom: settings.themeCustomOverrides.surface != nil,
                    onColorChange: { hex in settings.themeCustomOverrides.surface = hex },
                    onReset: { settings.themeCustomOverrides.surface = nil }
                )
                ColorBarRow(
                    label: L10n.tr(.settingsAppearanceCustomInk, language: language),
                    hexValue: settings.resolvedTheme.ink,
                    isCustom: settings.themeCustomOverrides.ink != nil,
                    onColorChange: { hex in settings.themeCustomOverrides.ink = hex },
                    onReset: { settings.themeCustomOverrides.ink = nil }
                )
                ColorBarRow(
                    label: L10n.tr(.settingsAppearanceCustomAccent, language: language),
                    hexValue: settings.resolvedTheme.accent,
                    isCustom: settings.themeCustomOverrides.accent != nil,
                    onColorChange: { hex in settings.themeCustomOverrides.accent = hex },
                    onReset: { settings.themeCustomOverrides.accent = nil }
                )
                ColorBarRow(
                    label: L10n.tr(.settingsAppearanceCustomSuccess, language: language),
                    hexValue: settings.resolvedTheme.success,
                    isCustom: settings.themeCustomOverrides.success != nil,
                    onColorChange: { hex in settings.themeCustomOverrides.success = hex },
                    onReset: { settings.themeCustomOverrides.success = nil }
                )
                ColorBarRow(
                    label: L10n.tr(.settingsAppearanceCustomDanger, language: language),
                    hexValue: settings.resolvedTheme.danger,
                    isCustom: settings.themeCustomOverrides.danger != nil,
                    onColorChange: { hex in settings.themeCustomOverrides.danger = hex },
                    onReset: { settings.themeCustomOverrides.danger = nil }
                )
            }
        }
    }

    // MARK: - 对比度

    private var contrastSection: some View {
        let currentContrast = settings.resolvedTheme.contrast
        return SettingsSection(
            title: L10n.tr(.settingsAppearanceContrastTitle, language: language),
            description: L10n.tr(.settingsAppearanceContrastDesc, language: language)
        ) {
            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { Double(currentContrast) },
                        set: { settings.themeCustomOverrides.contrast = Int($0) }
                    ),
                    in: 0...100
                )
                HStack {
                    Text(L10n.tr(.settingsAppearanceContrastLow, language: language))
                        .font(.caption)
                        .foregroundStyle(themeColors.fgMuted)
                    Spacer()
                    Text("\(currentContrast)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(themeColors.fgSecondary)
                    Spacer()
                    Text(L10n.tr(.settingsAppearanceContrastHigh, language: language))
                        .font(.caption)
                        .foregroundStyle(themeColors.fgMuted)
                }
            }
        }
    }

    // MARK: - 字体排版

    private var typographySection: some View {
        SettingsSection(
            title: L10n.tr(.settingsAppearanceTypographyTitle, language: language)
        ) {
            HStack {
                Text(L10n.tr(.settingsAppearanceSourceFontSize, language: language))
                Spacer()
                Stepper(
                    "\(settings.sourceFontSize) pt",
                    value: $settings.sourceFontSize,
                    in: 10...24
                )
            }

            HStack {
                Text(L10n.tr(.settingsAppearanceContentPadding, language: language))
                Spacer()
                Stepper(
                    "\(settings.contentPadding) pt",
                    value: $settings.contentPadding,
                    in: 8...40
                )
            }
        }
    }

    // MARK: - 方法

    private func selectScheme(_ theme: ThemeDefinition) {
        settings.themeId = theme.id
        // 切换配色方案时清除自定义覆盖，参照 buddy-macos 行为
        settings.themeCustomOverrides = .empty
    }

    private func applyAppearance(_ mode: AppearanceMode) {
        NSApp.appearance = mode.nsAppearance
        NSApp.windows.forEach { window in
            window.invalidateShadow()
        }
    }
}

// MARK: - 主题模式卡片

private struct ThemeModeCard: View {
    let mode: AppearanceMode
    let icon: String
    let title: String
    let description: String
    let isSelected: Bool
    let language: Language
    let action: () -> Void
    @Environment(\.themeColors) private var themeColors

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                // 卡片内容：2 行布局
                VStack(alignment: .leading, spacing: 4) {
                    // Row 1: 图标 + 标题横排
                    HStack(spacing: 6) {
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(isSelected ? themeColors.accent : themeColors.fgSecondary)
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(themeColors.ink)
                        Spacer()
                    }

                    // Row 2: 描述
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(themeColors.fgMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)

                // 右上角选中指示器
                Circle()
                    .fill(isSelected ? themeColors.accent : Color.clear)
                    .frame(width: 12, height: 12)
                    .overlay {
                        Circle()
                            .strokeBorder(isSelected ? Color.clear : themeColors.border, lineWidth: 1.5)
                            .frame(width: 12, height: 12)
                    }
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(themeColors.surface)
            )
            .overlay {
                // 选中态：accent 描边 + 软底色双层强调
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? themeColors.accent : themeColors.border, lineWidth: isSelected ? 2 : 1)
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(themeColors.accent.opacity(0.3), lineWidth: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 配色方案卡片

private struct ColorSchemeCard: View {
    let theme: ThemeDefinition
    let isSelected: Bool
    let language: Language
    let action: () -> Void
    @Environment(\.themeColors) private var themeColors

    /// 安全解析 hex 颜色
    private var surfaceColor: Color {
        Color(hex: theme.surface) ?? Color(nsColor: .controlBackgroundColor)
    }
    private var accentColor: Color {
        Color(hex: theme.accent) ?? themeColors.accent
    }
    private var inkColor: Color {
        Color(hex: theme.ink) ?? themeColors.ink
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    // 迷你预览条：accent 圆点 + ink 线条（卡片背景已是 surfaceColor，无需再填充）
                    RoundedRectangle(cornerRadius: 4)
                        .fill(surfaceColor.opacity(0.5))
                        .frame(height: 24)
                        .overlay {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(accentColor)
                                    .frame(width: 6, height: 6)
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(inkColor.opacity(0.5))
                                    .frame(width: 18, height: 2)
                            }
                            .padding(.leading, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 4)

                    // 选中指示器
                    if isSelected {
                        Circle()
                            .fill(themeColors.accent)
                            .frame(width: 8, height: 8)
                            .overlay {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 5, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .padding(4)
                    }
                }

                // 主题名称（使用主题自身的 ink 色）
                Text(theme.name)
                    .font(.system(size: 10))
                    .foregroundStyle(inkColor)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(surfaceColor)
            )
            .overlay {
                // 选中态：accent 描边 + 软底色双层强调
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? themeColors.accent : themeColors.border, lineWidth: isSelected ? 2 : 0.5)
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(themeColors.accent.opacity(0.15))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 颜色条

private struct ColorBarRow: View {
    let label: String
    let hexValue: String
    let isCustom: Bool
    let onColorChange: (String) -> Void
    let onReset: () -> Void
    @Environment(\.themeColors) private var themeColors

    @State private var isEditingHex = false
    @State private var editHexText = ""
    @State private var pickerColor: Color = .gray
    @State private var isPickerActive = false

    var body: some View {
        HStack(spacing: 10) {
            // 颜色色块按钮：直接打开 NSColorPanel
            Button {
                pickerColor = Color(hex: hexValue) ?? .gray
                isPickerActive = true
                openNativeColorPanel()
            } label: {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: hexValue) ?? .gray)
                    .frame(width: 24, height: 24)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(themeColors.ink.opacity(0.15), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            // 监听 NSColorPanel 变化
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NSColorPanelColorDidChangeNotification"))) { _ in
                guard isPickerActive else { return }
                let panel = NSColorPanel.shared
                guard let rgbColor = panel.color.usingColorSpace(.sRGB) else { return }
                let newHex = String(format: "#%02X%02X%02X",
                    Int(round(rgbColor.redComponent * 0xFF)),
                    Int(round(rgbColor.greenComponent * 0xFF)),
                    Int(round(rgbColor.blueComponent * 0xFF)))
                onColorChange(newHex)
            }
            .onDisappear {
                if isPickerActive {
                    NSColorPanel.shared.close()
                    isPickerActive = false
                }
            }

            // 标签
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(themeColors.ink)

            Spacer()

            // Hex 值（可点击编辑，始终大写显示）
            if isEditingHex {
                TextField("#", text: $editHexText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 72)
                    .onSubmit {
                        let cleaned = editHexText.hasPrefix("#") ? String(editHexText.dropFirst()) : editHexText
                        if cleaned.count == 6 && cleaned.allSatisfy({ $0.isHexDigit }) {
                            onColorChange("#" + cleaned.uppercased())
                        }
                        isEditingHex = false
                    }
            } else {
                Button {
                    editHexText = hexValue
                    isEditingHex = true
                } label: {
                    Text(hexValue.uppercased())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(themeColors.fgSecondary)
                }
                .buttonStyle(.plain)
            }

            // 重置按钮（仅自定义时显示）
            if isCustom {
                Button {
                    onReset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(themeColors.fgSecondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr(.reset, language: .en))
            }
        }
        .padding(.vertical, 2)
    }

    /// 打开原生 NSColorPanel
    private func openNativeColorPanel() {
        let panel = NSColorPanel.shared
        let nsColor = NSColor(Color(hex: hexValue) ?? .gray)
        panel.color = nsColor.usingColorSpace(.sRGB) ?? NSColor.gray
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.isContinuous = true
        panel.showsAlpha = false
        panel.makeKeyAndOrderFront(nil)
        // 监听面板关闭
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [self] _ in
            Task { @MainActor in
                isPickerActive = false
            }
        }
    }
}

// MARK: - 设置区段辅助视图

private struct SettingsSection<Content: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder let content: Content
    @Environment(\.themeColors) private var themeColors

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(themeColors.ink)

            if let desc = description {
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(themeColors.fgMuted)
            }

            content
        }
    }
}

private struct SettingsDivider: View {
    @Environment(\.themeColors) private var themeColors

    var body: some View {
        Rectangle()
            .fill(themeColors.border)
            .frame(height: 1)
            .padding(.vertical, 12)
    }
}

// MARK: - LanguagePref 辅助扩展

extension LanguagePref {
    static func languageKey(for pref: LanguagePref) -> L10n.Key {
        switch pref {
        case .auto: .languageAuto
        case .zhCN: .languageZhCN
        case .zhTW: .languageZhTW
        case .en: .languageEn
        }
    }
}

// MARK: - Color hex 扩展

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        // 支持 3 位 hex（#fff → #ffffff）
        if hexSanitized.count == 3 {
            let chars = Array(hexSanitized)
            hexSanitized = "\(chars[0])\(chars[0])\(chars[1])\(chars[1])\(chars[2])\(chars[2])"
        }

        guard hexSanitized.count == 6,
              let rgb = UInt64(hexSanitized, radix: 16) else {
            return nil
        }

        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }

    func toHexString() -> String {
        let nsColor = NSColor(self)
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(rgbColor.redComponent * 0xFF))
        let g = Int(round(rgbColor.greenComponent * 0xFF))
        let b = Int(round(rgbColor.blueComponent * 0xFF))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

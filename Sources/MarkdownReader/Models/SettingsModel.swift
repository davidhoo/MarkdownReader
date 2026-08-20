import SwiftUI
import MarkdownReaderKit
import UniformTypeIdentifiers

/// 最近打开的文件/目录记录
struct RecentItem: Codable, Identifiable, Equatable {
    let id: UUID
    let url: URL
    /// 是否为目录
    let isDirectory: Bool
    /// 记录时间戳
    let timestamp: Date

    init(url: URL, isDirectory: Bool, timestamp: Date = Date()) {
        self.id = UUID()
        self.url = url
        self.isDirectory = isDirectory
        self.timestamp = timestamp
    }

    /// 显示名称：使用绝对路径
    var displayName: String {
        url.path
    }

    static func == (lhs: RecentItem, rhs: RecentItem) -> Bool {
        lhs.url == rhs.url
    }
}

/// 设置模型，使用 @Observable + 手动 UserDefaults 同步
/// @Observable 和 @AppStorage 不兼容，因此使用 didSet 手动同步到 UserDefaults
/// 参照 buddy-macos 的设置结构，适配 SwiftUI 原生方案
@MainActor
@Observable
final class SettingsModel {

    // MARK: - 单例

    /// 全局共享实例，确保 ContentView 与 SettingsView 引用同一对象
    /// 语言切换等设置变更可即时传播到所有视图
    static let shared = SettingsModel()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let defaultDisplayMode   = "com.markdownreader.defaultDisplayMode"
        static let reopenLastLocation   = "com.markdownreader.reopenLastLocation"
        static let showHiddenFiles      = "com.markdownreader.showHiddenFiles"
        static let showNonMarkdownFiles = "com.markdownreader.showNonMarkdownFiles"
        static let appearanceMode       = "com.markdownreader.appearanceMode"
        static let sourceFontSize       = "com.markdownreader.sourceFontSize"
        static let contentPadding       = "com.markdownreader.contentPadding"
        static let showSourceLineNumbers = "com.markdownreader.showSourceLineNumbers"
        static let languagePref         = SharedPreferenceKey.languagePref
        static let themeId              = "com.markdownreader.themeId"
        static let themeCustomOverrides = "com.markdownreader.themeCustomOverrides"
        static let lastOpenedDirectory  = "com.markdownreader.lastOpenedDirectory"
        static let lastOpenedFilePath   = "com.markdownreader.lastOpenedFilePath"
        static let isDefaultMdOpener    = "com.markdownreader.isDefaultMdOpener"
        static let enableCommandLine    = "com.markdownreader.enableCommandLine"
        static let recentItems          = "com.markdownreader.recentItems"
        static let skipFileModifiedAlert = "com.markdownreader.skipFileModifiedAlert"
        static let maxContentWidthFollowsWindow = "com.markdownreader.maxContentWidthFollowsWindow"
        static let skippedVersion       = "com.markdownreader.skippedVersion"
        static let lastUpdateCheckTime  = "com.markdownreader.lastUpdateCheckTime"
        static let enableQuickLookPreview = SharedPreferenceKey.enableQuickLookPreview
        static let enableDocumentCopy     = SharedPreferenceKey.enableDocumentCopy
        static let quickLookDocumentCopyFormat = SharedPreferenceKey.quickLookDocumentCopyFormat
    }

    private let defaults = UserDefaults.standard

    // MARK: - 通用设置

    /// 界面语言偏好
    var languagePref: LanguagePref {
        didSet {
            defaults.set(languagePref.rawValue, forKey: Keys.languagePref)
            let language = languagePref.resolvedLanguage
            Task { @MainActor in
                MainMenuLocalizationService.setLanguage(language)
            }
        }
    }

    /// 默认显示模式（渲染 / 原文）
    var defaultDisplayMode: DisplayMode {
        didSet { defaults.set(defaultDisplayMode.rawValue, forKey: Keys.defaultDisplayMode) }
    }

    /// 启动时重新打开上次位置
    var reopenLastLocation: Bool {
        didSet { defaults.set(reopenLastLocation, forKey: Keys.reopenLastLocation) }
    }

    /// 在侧边栏显示隐藏文件
    var showHiddenFiles: Bool {
        didSet { defaults.set(showHiddenFiles, forKey: Keys.showHiddenFiles) }
    }

    /// 在侧边栏显示非 Markdown 文件
    var showNonMarkdownFiles: Bool {
        didSet { defaults.set(showNonMarkdownFiles, forKey: Keys.showNonMarkdownFiles) }
    }

    /// 是否已设为 Markdown 文件默认打开程序（.md / .markdown / .mdown / .mkd）
    /// 初始化时从系统实时检测；设置变更后同步写入 UserDefaults 作为缓存
    var isDefaultMdOpener: Bool {
        didSet { defaults.set(isDefaultMdOpener, forKey: Keys.isDefaultMdOpener) }
    }

    /// 跳过「文件被外部修改」确认弹窗
    var skipFileModifiedAlert: Bool {
        didSet { defaults.set(skipFileModifiedAlert, forKey: Keys.skipFileModifiedAlert) }
    }

    /// 渲染视图最大宽度跟随窗口可用宽度（默认不选中，使用固定 980px）
    var maxContentWidthFollowsWindow: Bool {
        didSet { defaults.set(maxContentWidthFollowsWindow, forKey: Keys.maxContentWidthFollowsWindow) }
    }

    /// 启用命令行工具（安装 mdr 命令到 /usr/local/bin/）
    var enableCommandLine: Bool {
        didSet { defaults.set(enableCommandLine, forKey: Keys.enableCommandLine) }
    }

    /// 启用 Quick Look 预览（在 Finder 中按空格键预览 Markdown 文件）
    var enableQuickLookPreview: Bool {
        didSet { defaults.set(enableQuickLookPreview, forKey: Keys.enableQuickLookPreview) }
    }

    /// 内容一键复制总开关：控制主阅读、Raw 编辑、Quick Look 三处整篇内容复制按钮。
    /// 默认开启；仅在新 key 缺失时写入 true，绝不覆盖已有用户值。
    var enableDocumentCopy: Bool {
        didSet { defaults.set(enableDocumentCopy, forKey: Keys.enableDocumentCopy) }
    }

    /// Quick Look 整篇内容复制格式。仅决定 Quick Look 复制语义，
    /// 不影响主应用阅读（富文本）与 Raw 编辑（原始 Markdown）。
    /// 默认富文本；仅在新 key 缺失时写入，绝不覆盖已有用户值。
    var quickLookDocumentCopyFormat: QuickLookDocumentCopyFormat {
        didSet { defaults.set(quickLookDocumentCopyFormat.rawValue, forKey: Keys.quickLookDocumentCopyFormat) }
    }

    // MARK: - 自动更新

    /// 用户跳过的版本号（点击「跳过此版本」后记录）
    var skippedVersion: String? {
        didSet { defaults.set(skippedVersion, forKey: Keys.skippedVersion) }
    }

    /// 上次自动检查更新的时间
    var lastUpdateCheckTime: Date? {
        didSet { defaults.set(lastUpdateCheckTime, forKey: Keys.lastUpdateCheckTime) }
    }

    // MARK: - 外观设置

    /// 外观模式（浅色 / 深色 / 跟随系统）
    var appearanceMode: AppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: Keys.appearanceMode) }
    }

    /// 当前主题 ID（参照 buddy-macos 的 themeId）
    var themeId: String {
        didSet { defaults.set(themeId, forKey: Keys.themeId) }
    }

    /// 主题自定义颜色覆盖（参照 buddy-macos 的 custom）
    var themeCustomOverrides: ThemeCustomOverrides {
        didSet {
            if let data = try? JSONEncoder().encode(themeCustomOverrides) {
                defaults.set(data, forKey: Keys.themeCustomOverrides)
            }
        }
    }

    /// 源码视图字号（pt）
    var sourceFontSize: Int {
        didSet { defaults.set(sourceFontSize, forKey: Keys.sourceFontSize) }
    }

    /// 渲染视图内容边距（pt）
    var contentPadding: Int {
        didSet { defaults.set(contentPadding, forKey: Keys.contentPadding) }
    }

    /// 在 Raw 编辑器左侧显示源码行号。默认关闭，避免改变现有阅读布局。
    var showSourceLineNumbers: Bool {
        didSet { defaults.set(showSourceLineNumbers, forKey: Keys.showSourceLineNumbers) }
    }

    // MARK: - 上次位置记忆

    /// 上次打开的目录 URL。
    /// Task 13：仅最后活动窗口可更新（经 recordLastOpened），后台窗口不得覆盖。
    var lastOpenedDirectory: URL? {
        didSet {
            defaults.set(lastOpenedDirectory?.path, forKey: Keys.lastOpenedDirectory)
        }
    }

    /// 上次打开的单文件 URL。
    /// Task 13：仅最后活动窗口可更新（经 recordLastOpened），后台窗口不得覆盖。
    var lastOpenedFile: URL? {
        didSet {
            defaults.set(lastOpenedFile?.path, forKey: Keys.lastOpenedFilePath)
        }
    }

    /// Task 13：记录最后打开位置。仅当本窗口是 Coordinator 的最后活动窗口时才写入，
    /// 防止后台窗口加载/切换覆盖主窗口的位置记忆。
    /// - Parameters:
    ///   - file: 打开的文件 URL（nil 表示目录模式）
    ///   - directory: 打开的目录 URL（nil 表示单文件模式）
    ///   - isActive: 本窗口是否为最后活动窗口（由调用方查 coordinator.lastActiveWindowID == windowID）
    func recordLastOpened(file: URL?, directory: URL?, isActive: Bool) {
        guard isActive else { return }
        if let directory {
            lastOpenedDirectory = directory
            lastOpenedFile = nil
        } else if let file {
            lastOpenedFile = file
            lastOpenedDirectory = nil
        }
    }

    // MARK: - 最近打开记录

    /// 最近打开的文件/目录列表（最多 10 条，按时间倒序）
    var recentItems: [RecentItem] {
        didSet {
            if let data = try? JSONEncoder().encode(recentItems) {
                defaults.set(data, forKey: Keys.recentItems)
            }
        }
    }

    /// 添加一条最近打开记录，自动去重、按时间倒序排列、限制最多 10 条
    func addRecentItem(url: URL, isDirectory: Bool) {
        // 验证路径是否仍然存在
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists else { return }

        let item = RecentItem(url: url, isDirectory: isDirectory)
        // 去重：移除相同 URL 的旧记录
        recentItems.removeAll { $0.url == url }
        // 插入到最前面
        recentItems.insert(item, at: 0)
        // 限制最多 10 条
        if recentItems.count > 10 {
            recentItems = Array(recentItems.prefix(10))
        }
    }

    /// 清除所有最近打开记录
    func clearRecentItems() {
        recentItems = []
    }

    // MARK: - 计算属性

    /// 系统当前是否为深色模式（运行时状态，不持久化）
    /// 由 ContentView 通过 colorScheme 环境值驱动更新
    var systemIsDark: Bool

    /// 解析后的主题类型（考虑跟随系统）
    var resolvedThemeType: ThemeType {
        switch appearanceMode {
        case .light: .light
        case .dark: .dark
        case .system: systemIsDark ? .dark : .light
        }
    }

    /// 当前基础主题（根据 themeId 查找，类型不匹配时回退到默认）
    var currentBaseTheme: ThemeDefinition {
        if let theme = PresetThemes.themeById(themeId), theme.type == resolvedThemeType {
            return theme
        }
        return PresetThemes.defaultTheme(for: resolvedThemeType)
    }

    /// 合并自定义覆盖后的完整主题
    var resolvedTheme: ThemeDefinition {
        resolveTheme(base: currentBaseTheme, custom: themeCustomOverrides)
    }

    /// 源码视图字号（安全范围 10~24）
    var sourceFontPointSize: CGFloat {
        CGFloat(min(max(sourceFontSize, 10), 24))
    }

    /// 内容边距（安全范围 8~40）
    var contentPaddingPoints: CGFloat {
        CGFloat(min(max(contentPadding, 8), 40))
    }

    // MARK: - 默认打开程序

    static func checkIsDefaultMdOpener() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        let extensions = ["md", "markdown", "mdown", "mkd"]
        for ext in extensions {
            guard let type = UTType(filenameExtension: ext) else { continue }
            if let defaultAppURL = NSWorkspace.shared.urlForApplication(toOpen: type),
               defaultAppURL.resolvingSymlinksInPath() == bundleURL.resolvingSymlinksInPath() {
                continue
            }
            // 任一扩展名未设为默认，则返回 false
            return false
        }
        return true
    }

    /// 将当前应用设为 Markdown 文件的默认打开程序
    /// 同时注册 .md/.markdown/.mdown/.mkd 扩展名
    /// 使用 NSWorkspace 的 async completionHandler 验证设置结果
    /// - Parameter completion: 设置结果回调（主线程），true 表示成功
    func setAsDefaultMdOpener(completion: @MainActor @escaping (Bool) -> Void = { _ in }) {
        let bundleURL = Bundle.main.bundleURL
        let extensions = ["md", "markdown", "mdown", "mkd"]
        let types = extensions.compactMap { UTType(filenameExtension: $0) }

        guard !types.isEmpty else {
            completion(false)
            return
        }

        // 使用非隔离的计数器类来安全地跟踪并发回调
        // NSLock 保护内部可变状态，线程安全但 Swift 类型系统无法证明
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _count = 0
            private var _results: [Bool]

            init(count: Int) {
                _results = Array(repeating: false, count: count)
            }

            func setResult(at index: Int, _ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                _results[index] = value
                _count += 1
            }

            var isComplete: Bool {
                lock.lock()
                defer { lock.unlock() }
                return _count == _results.count
            }

            var hasSuccess: Bool {
                lock.lock()
                defer { lock.unlock() }
                return _results.contains(true)
            }
        }

        let counter = Counter(count: types.count)

        for (index, type) in types.enumerated() {
            NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpen: type) { [weak self] error in
                counter.setResult(at: index, error == nil)

                if counter.isComplete {
                    let success = counter.hasSuccess
                    DispatchQueue.main.async {
                        self?.isDefaultMdOpener = success
                        completion(success)
                    }
                }
            }
        }
    }

    /// 刷新默认打开程序状态（从系统重新检测）
    func refreshDefaultOpenerStatus() {
        isDefaultMdOpener = Self.checkIsDefaultMdOpener()
    }

    // MARK: - 初始化（从 UserDefaults 恢复）

    init() {
        let defaults = UserDefaults.standard

        self.defaultDisplayMode = DisplayMode(rawValue: defaults.string(forKey: Keys.defaultDisplayMode) ?? "") ?? .rendered
        self.languagePref = LanguagePref(rawValue: defaults.string(forKey: Keys.languagePref) ?? "") ?? .auto
        self.reopenLastLocation = defaults.object(forKey: Keys.reopenLastLocation) as? Bool ?? false
        self.showHiddenFiles = defaults.object(forKey: Keys.showHiddenFiles) as? Bool ?? false
        self.showNonMarkdownFiles = defaults.object(forKey: Keys.showNonMarkdownFiles) as? Bool ?? true
        self.isDefaultMdOpener = Self.checkIsDefaultMdOpener()
        self.skipFileModifiedAlert = defaults.object(forKey: Keys.skipFileModifiedAlert) as? Bool ?? false
        self.maxContentWidthFollowsWindow = defaults.object(forKey: Keys.maxContentWidthFollowsWindow) as? Bool ?? false
        self.enableCommandLine = FileManager.default.fileExists(atPath: "/usr/local/bin/mdr")
        // Quick Look 预览默认启用，必须持久化到 UserDefaults
        // （Extension 通过 CFPreferences 读取，key 不存在时返回 false）
        if defaults.object(forKey: Keys.enableQuickLookPreview) == nil {
            defaults.set(true, forKey: Keys.enableQuickLookPreview)
        }
        self.enableQuickLookPreview = defaults.bool(forKey: Keys.enableQuickLookPreview)
        // 内容一键复制默认开启，仅在新 key 缺失时写入 true，绝不覆盖已有用户值
        // （Extension 通过 CFPreferences 读取，key 不存在时总开关视为关闭）。
        if defaults.object(forKey: Keys.enableDocumentCopy) == nil {
            defaults.set(true, forKey: Keys.enableDocumentCopy)
        }
        self.enableDocumentCopy = defaults.bool(forKey: Keys.enableDocumentCopy)
        // Quick Look 复制格式默认富文本，仅在新 key 缺失时写入，绝不覆盖已有用户值。
        if defaults.object(forKey: Keys.quickLookDocumentCopyFormat) == nil {
            defaults.set(QuickLookDocumentCopyFormat.richText.rawValue, forKey: Keys.quickLookDocumentCopyFormat)
        }
        self.quickLookDocumentCopyFormat = QuickLookDocumentCopyFormat(
            rawValue: defaults.string(forKey: Keys.quickLookDocumentCopyFormat) ?? ""
        ) ?? .richText
        self.skippedVersion = defaults.string(forKey: Keys.skippedVersion)
        self.lastUpdateCheckTime = defaults.object(forKey: Keys.lastUpdateCheckTime) as? Date
        self.appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearanceMode) ?? "") ?? .system
        self.themeId = defaults.string(forKey: Keys.themeId) ?? "buddy-dark"
        if let data = defaults.data(forKey: Keys.themeCustomOverrides),
           let overrides = try? JSONDecoder().decode(ThemeCustomOverrides.self, from: data) {
            self.themeCustomOverrides = overrides
        } else {
            self.themeCustomOverrides = .empty
        }
        self.sourceFontSize = defaults.object(forKey: Keys.sourceFontSize) as? Int ?? 13
        self.contentPadding = defaults.object(forKey: Keys.contentPadding) as? Int ?? 20
        self.showSourceLineNumbers = defaults.object(forKey: Keys.showSourceLineNumbers) as? Bool ?? false
        // NSApp 在应用启动极早期可能尚未初始化（如通过 UpdateViewModel → SettingsModel.shared 触发时），
        // 使用可选链安全访问，不可用时默认为 false（浅色）
        self.systemIsDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // 恢复上次位置（验证路径是否仍存在）
        if let dirPath = defaults.string(forKey: Keys.lastOpenedDirectory) {
            let url = URL(fileURLWithPath: dirPath)
            var isDir: ObjCBool = false
            self.lastOpenedDirectory = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                ? url : nil
        } else {
            self.lastOpenedDirectory = nil
        }

        if let filePath = defaults.string(forKey: Keys.lastOpenedFilePath) {
            let url = URL(fileURLWithPath: filePath)
            self.lastOpenedFile = FileManager.default.fileExists(atPath: url.path) ? url : nil
        } else {
            self.lastOpenedFile = nil
        }

        // 恢复最近打开记录（过滤掉已不存在的路径）
        if let data = defaults.data(forKey: Keys.recentItems),
           let items = try? JSONDecoder().decode([RecentItem].self, from: data) {
            self.recentItems = items.filter { item in
                FileManager.default.fileExists(atPath: item.url.path)
            }
        } else {
            self.recentItems = []
        }
    }
}

// MARK: - 外观模式枚举

/// 外观模式：浅色、深色、跟随系统
enum AppearanceMode: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light:  return "浅色"
        case .dark:   return "深色"
        case .system: return "跟随系统"
        }
    }

    /// 转换为 NSAppearance
    var nsAppearance: NSAppearance? {
        switch self {
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }
}

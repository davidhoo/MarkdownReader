import AppKit
import MarkdownReaderKit

/// SwiftUI 创建的标准一级菜单角色。
enum StandardMainMenuRole: CaseIterable, Hashable, Sendable {
    case file
    case edit
    case view
    case window
    case help
}

/// 让 SwiftUI/AppKit 标准一级菜单跟随应用内语言设置。
///
/// 自定义菜单和菜单项继续由 `L10n` 渲染；这里只识别系统标准菜单在三种受支持语言下
/// 的标题，因此不会改变应用菜单或自定义的 Find 菜单。
@MainActor
enum MainMenuLocalizationService {

    private static var language: Language = .en
    private static var observerTokens: [NSObjectProtocol] = []

    static func titles(for language: Language) -> [StandardMainMenuRole: String] {
        switch language {
        case .en:
            [
                .file: "File",
                .edit: "Edit",
                .view: "View",
                .window: "Window",
                .help: "Help",
            ]
        case .zhCN:
            [
                .file: "文件",
                .edit: "编辑",
                .view: "显示",
                .window: "窗口",
                .help: "帮助",
            ]
        case .zhTW:
            [
                .file: "檔案",
                .edit: "編輯",
                .view: "顯示方式",
                .window: "視窗",
                .help: "輔助說明",
            ]
        }
    }

    static func role(for title: String) -> StandardMainMenuRole? {
        for language in Language.allCases {
            if let match = titles(for: language).first(where: { $0.value == title }) {
                return match.key
            }
        }
        return nil
    }

    static func apply(language: Language, to menu: NSMenu) {
        let localizedTitles = titles(for: language)

        for item in menu.items {
            guard
                let role = role(for: item.title),
                let localizedTitle = localizedTitles[role]
            else {
                continue
            }
            if item.title != localizedTitle {
                item.title = localizedTitle
            }
            if let submenu = item.submenu, submenu.title != localizedTitle {
                submenu.title = localizedTitle
            }
        }
    }

    /// 启动应用级菜单同步。重复调用只更新目标语言，不重复注册监听。
    static func start(language: Language) {
        self.language = language

        if observerTokens.isEmpty {
            let center = NotificationCenter.default
            observerTokens = [
                NSMenu.didAddItemNotification,
                NSMenu.didChangeItemNotification,
            ].map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor in
                        applyCurrentLanguage()
                    }
                }
            }
        }

        applyCurrentLanguage()
    }

    /// 应用内语言改变时更新目标语言；菜单若随后被 SwiftUI 重建，监听器会再次同步。
    static func setLanguage(_ language: Language) {
        self.language = language
        applyCurrentLanguage()
    }

    private static func applyCurrentLanguage() {
        guard let mainMenu = NSApp.mainMenu else { return }
        apply(language: language, to: mainMenu)
    }
}

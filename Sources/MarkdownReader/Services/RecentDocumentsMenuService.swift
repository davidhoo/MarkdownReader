import AppKit
import MarkdownReaderKit

/// 维护 macOS 主菜单「打开最近使用」子菜单的动态更新（AppKit 桥接）。
///
/// SwiftUI 的 `.commands` 静态构建后无法响应 `@Observable` 的变更以刷新
/// 子菜单项。本服务通过 `NSMenuDelegate` 在用户展开「打开最近使用」时，
/// 从 `SettingsModel.shared.recentItems` 动态填充最新列表。
@MainActor
final class RecentDocumentsMenuService: NSObject, NSMenuDelegate {

    static let shared = RecentDocumentsMenuService()

    var settings: SettingsModel
    private var observerTokens: [NSObjectProtocol] = []
    private weak var attachedSubmenu: NSMenu?

    init(settings: SettingsModel = .shared) {
        self.settings = settings
        super.init()
    }

    /// 启动最近项菜单服务。
    static func start() {
        shared.setupObservers()
        shared.attachToMainMenu()
    }

    private func setupObservers() {
        guard observerTokens.isEmpty else { return }
        let center = NotificationCenter.default
        observerTokens = [
            NSMenu.didAddItemNotification,
            NSMenu.didChangeItemNotification,
        ].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.attachToMainMenu()
                }
            }
        }
    }

    /// 在主菜单 File 菜单中定位「打开最近使用」并挂接 delegate。
    func attachToMainMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for menu in mainMenu.items.compactMap(\.submenu) {
            for item in menu.items {
                if isRecentMenu(item: item) {
                    ensureSubmenu(for: item)
                    return
                }
            }
        }
    }

    /// 为扁平化的「打开最近使用」菜单项补建子菜单。
    func ensureSubmenu(for item: NSMenuItem) {
        let language = settings.languagePref.resolvedLanguage
        let title = L10n.tr(.openRecent, language: language)

        item.title = title
        if item.submenu == nil {
            item.submenu = NSMenu(title: title)
        }
        if let submenu = item.submenu {
            if submenu.delegate !== self {
                submenu.delegate = self
                attachedSubmenu = submenu
            }
            populateMenu(submenu)
        }
    }

    private func isRecentMenu(item: NSMenuItem) -> Bool {
        let title = item.title
        let candidates: Set<String> = [
            "Open Recent",
            "打开最近使用",
            "開啟最近使用",
            "最近打开",
            "打开最近",
            "No Recent Items",
            "无最近打开的项",
            "無最近開啟的項目"
        ]
        return candidates.contains(title)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu(menu)
    }

    /// 动态构建最近项列表
    func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let language = settings.languagePref.resolvedLanguage
        let recentItems = settings.recentItems

        if recentItems.isEmpty {
            let emptyItem = NSMenuItem(
                title: L10n.tr(.openRecentEmpty, language: language),
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        let files = recentItems.filter { !$0.isDirectory }
        let folders = recentItems.filter { $0.isDirectory }

        for file in files {
            let item = NSMenuItem(
                title: file.displayName,
                action: #selector(handleOpenRecentItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = file.url
            if let image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) {
                item.image = image
            }
            menu.addItem(item)
        }

        if !files.isEmpty && !folders.isEmpty {
            menu.addItem(.separator())
        }

        for folder in folders {
            let item = NSMenuItem(
                title: folder.displayName,
                action: #selector(handleOpenRecentItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = folder.url
            if let image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil) {
                item.image = image
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let clearItem = NSMenuItem(
            title: L10n.tr(.clearRecentItems, language: language),
            action: #selector(handleClearRecentItems(_:)),
            keyEquivalent: ""
        )
        clearItem.target = self
        menu.addItem(clearItem)
    }

    @objc func handleOpenRecentItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        AppDelegate.coordinator.enqueue(OpenRequest(url: url, source: .openRecent))
    }

    @objc func handleClearRecentItems(_ sender: NSMenuItem) {
        settings.clearRecentItems()
    }
}

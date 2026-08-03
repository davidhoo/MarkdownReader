import AppKit
import MarkdownReaderKit
import XCTest
@testable import MarkdownReader

@MainActor
final class MenuLocalizationTests: XCTestCase {

    func testMainBundleDeclaresAllSupportedLocalizations() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let projectRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = projectRoot.appendingPathComponent("scripts/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )

        XCTAssertEqual(plist["CFBundleDevelopmentRegion"] as? String, "en")
        XCTAssertEqual(
            Set(plist["CFBundleLocalizations"] as? [String] ?? []),
            Set(["en", "zh-Hans", "zh-Hant"])
        )
    }

    func testStandardMenuTitlesMatchSupportedLanguages() {
        XCTAssertEqual(
            MainMenuLocalizationService.titles(for: .en),
            [.file: "File", .edit: "Edit", .view: "View", .window: "Window", .help: "Help"]
        )
        XCTAssertEqual(
            MainMenuLocalizationService.titles(for: .zhCN),
            [.file: "文件", .edit: "编辑", .view: "显示", .window: "窗口", .help: "帮助"]
        )
        XCTAssertEqual(
            MainMenuLocalizationService.titles(for: .zhTW),
            [.file: "檔案", .edit: "編輯", .view: "顯示方式", .window: "視窗", .help: "輔助說明"]
        )
    }

    func testRecognizesStandardMenuRolesAcrossSupportedLanguages() {
        for language in Language.allCases {
            for (role, title) in MainMenuLocalizationService.titles(for: language) {
                XCTAssertEqual(MainMenuLocalizationService.role(for: title), role)
            }
        }
        XCTAssertNil(MainMenuLocalizationService.role(for: "Find"))
        XCTAssertNil(MainMenuLocalizationService.role(for: "Markdown Reader"))
    }

    func testApplyChangesOnlyStandardTopLevelMenuTitles() {
        let menu = NSMenu()
        ["Markdown Reader", "文件", "编辑", "显示", "查找", "窗口", "帮助"]
            .map { NSMenuItem(title: $0, action: nil, keyEquivalent: "") }
            .forEach(menu.addItem)

        MainMenuLocalizationService.apply(language: .en, to: menu)

        XCTAssertEqual(
            menu.items.map(\.title),
            ["Markdown Reader", "File", "Edit", "View", "查找", "Window", "Help"]
        )
    }

    func testApplyAlsoChangesStandardSubmenuTitles() {
        let menu = NSMenu()
        let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        fileItem.submenu = NSMenu(title: "文件")
        menu.addItem(fileItem)

        MainMenuLocalizationService.apply(language: .en, to: menu)

        XCTAssertEqual(fileItem.title, "File")
        XCTAssertEqual(fileItem.submenu?.title, "File")
    }
}

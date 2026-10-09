import XCTest
import MarkdownReaderKit
@testable import MarkdownReader

/// 工作区相关 L10n 键三语齐备性测试（方案 3.3：MenuLocalizationTests 扩展项）。
///
/// `L10n.tr` 在键缺失时回退为 `key.rawValue`，据此断言三语字典均已收录。
final class WorkspaceLocalizationTests: XCTestCase {

    /// 本次工作区功能新增的全部 L10n 键。
    private let workspaceKeys: [L10n.Key] = [
        .menuAddFolderToWorkspace,
        .menuSaveWorkspace,
        .menuSaveWorkspaceAs,
        .workspaceRemoveFolder,
        .workspaceUntitledName,
        .workspaceRootDeleted,
        .workspaceMissingFolders,
        .workspaceAlreadyAdded,
        .workspaceNestedConflict,
        .unsavedWorkspaceTitle,
        .unsavedWorkspaceMessage,
        .workspaceLoadFailed,
    ]

    func testAllWorkspaceKeysPresentInEveryLanguage() {
        for language in Language.allCases {
            for key in workspaceKeys {
                let translated = L10n.tr(key, language: language)
                XCTAssertNotEqual(
                    translated, key.rawValue,
                    "L10n 键 \(key.rawValue) 在语言 \(language.rawValue) 缺失翻译"
                )
                XCTAssertFalse(
                    translated.isEmpty,
                    "L10n 键 \(key.rawValue) 在语言 \(language.rawValue) 翻译为空"
                )
            }
        }
    }

    func testWorkspaceKeysDifferAcrossLanguagesWhereExpected() {
        // 中英至少应不同（防止整段复制错误语言字典）
        for key in workspaceKeys {
            let en = L10n.tr(key, language: .en)
            let zhCN = L10n.tr(key, language: .zhCN)
            XCTAssertNotEqual(en, zhCN, "键 \(key.rawValue) 中英文翻译不应相同")
        }
    }
}

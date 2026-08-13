import MarkdownReaderKit
import XCTest

/// Quick Look 复制设置快照单测。
///
/// `QuickLookDocumentCopySettings` 把主应用 CFPreferences 域中的原始 Bool/String
/// 解析为跨进程共享的设置快照。本测试锁定兼容默认值与无效值回退规则：
/// - 缺失/无效的格式一律回退 `richText`；
/// - 缺失的总开关一律视为开启；
/// - `auto` 语言偏好使用显式传入的检测语言，非 `auto` 值直接映射。
/// 测试必须显式传 `detectedLanguage`，绝不依赖当前机器 Locale。
final class QuickLookDocumentCopySettingsTests: XCTestCase {

    // MARK: - 缺失值保持兼容默认（已有用户不被打扰）

    func testMissingStoredValuesKeepExistingUsersOnRichTextCopy() {
        let settings = QuickLookDocumentCopySettings(
            storedDocumentCopyEnabled: nil,
            storedFormatRawValue: nil,
            storedLanguagePrefRawValue: nil,
            detectedLanguage: .en
        )

        XCTAssertTrue(settings.isDocumentCopyEnabled)
        XCTAssertEqual(settings.format, .richText)
        XCTAssertEqual(settings.language, .en)
    }

    // MARK: - 无效格式回退富文本

    func testUnknownFormatFallsBackToRichText() {
        let settings = QuickLookDocumentCopySettings(
            storedDocumentCopyEnabled: false,
            storedFormatRawValue: "invalid",
            storedLanguagePrefRawValue: LanguagePref.zhCN.rawValue,
            detectedLanguage: .en
        )

        XCTAssertFalse(settings.isDocumentCopyEnabled)
        XCTAssertEqual(settings.format, .richText)
        XCTAssertEqual(settings.language, .zhCN)
    }

    // MARK: - rawMarkdown 格式

    func testRawMarkdownFormatIsPreservedWhenValid() {
        let settings = QuickLookDocumentCopySettings(
            storedDocumentCopyEnabled: true,
            storedFormatRawValue: QuickLookDocumentCopyFormat.rawMarkdown.rawValue,
            storedLanguagePrefRawValue: LanguagePref.en.rawValue,
            detectedLanguage: .zhCN
        )

        XCTAssertTrue(settings.isDocumentCopyEnabled)
        XCTAssertEqual(settings.format, .rawMarkdown)
        XCTAssertEqual(settings.language, .en)
    }

    // MARK: - auto 语言偏好使用检测语言

    func testAutoLanguagePrefUsesDetectedLanguage() {
        let settings = QuickLookDocumentCopySettings(
            storedDocumentCopyEnabled: true,
            storedFormatRawValue: QuickLookDocumentCopyFormat.richText.rawValue,
            storedLanguagePrefRawValue: LanguagePref.auto.rawValue,
            detectedLanguage: .zhTW
        )

        XCTAssertEqual(settings.language, .zhTW)
    }

    // MARK: - 缺失语言偏好视为 auto，使用检测语言

    func testMissingLanguagePrefUsesDetectedLanguage() {
        let settings = QuickLookDocumentCopySettings(
            storedDocumentCopyEnabled: nil,
            storedFormatRawValue: nil,
            storedLanguagePrefRawValue: nil,
            detectedLanguage: .zhCN
        )

        XCTAssertEqual(settings.language, .zhCN)
    }
}

import Foundation
import AppKit
import MarkdownReaderKit

/// `UnsavedCloseInteraction` 的生产实现：弹 `NSAlert` 与 `NSSavePanel`（Task 1）。
///
/// 头部为唯一来源，避免之前 `WindowCloseGuard` 与 `ApplicationTerminationCoordinator`
/// 各自复制一份弹窗逻辑（且各自带死锁）。
@MainActor
final class AppKitUnsavedCloseInteraction: UnsavedCloseInteraction {

    func presentUnsavedChangesPrompt(for session: WindowSession) -> UnsavedPromptChoice {
        let language = SettingsModel.shared.languagePref.resolvedLanguage

        let alert = NSAlert()
        alert.messageText = L10n.tr(.unsavedChangesTitle, language: language)
        alert.informativeText = L10n.tr(.unsavedChangesMessage, language: language)
        alert.alertStyle = .warning

        alert.addButton(withTitle: L10n.tr(.unsavedSave, language: language))
        alert.addButton(withTitle: L10n.tr(.unsavedDontSave, language: language))
        alert.addButton(withTitle: L10n.tr(.unsavedCancel, language: language))

        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "d"
        alert.buttons[1].keyEquivalentModifierMask = .command
        alert.buttons[2].keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            return .dontSave
        default:
            return .cancel
        }
    }

    func chooseSaveAsTarget(
        for session: WindowSession,
        suggestedName: String,
        defaultDirectory: URL?
    ) async -> URL? {
        let language = SettingsModel.shared.languagePref.resolvedLanguage
        return await OpenPanelHelper.showSavePanel(
            for: session.window,
            language: language,
            defaultDirectory: defaultDirectory,
            suggestedName: suggestedName
        )
    }

    func presentUnsavedWorkspacePrompt(for session: WindowSession) -> UnsavedPromptChoice {
        let language = SettingsModel.shared.languagePref.resolvedLanguage

        let alert = NSAlert()
        alert.messageText = L10n.tr(.unsavedWorkspaceTitle, language: language)
        alert.informativeText = L10n.tr(.unsavedWorkspaceMessage, language: language)
        alert.alertStyle = .warning

        alert.addButton(withTitle: L10n.tr(.unsavedSave, language: language))
        alert.addButton(withTitle: L10n.tr(.unsavedDontSave, language: language))
        alert.addButton(withTitle: L10n.tr(.unsavedCancel, language: language))

        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "d"
        alert.buttons[1].keyEquivalentModifierMask = .command
        alert.buttons[2].keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            return .dontSave
        default:
            return .cancel
        }
    }

    func chooseWorkspaceSaveTarget(
        for session: WindowSession,
        suggestedName: String,
        defaultDirectory: URL?
    ) async -> URL? {
        let language = SettingsModel.shared.languagePref.resolvedLanguage
        return await OpenPanelHelper.showWorkspaceSavePanel(
            for: session.window,
            language: language,
            defaultDirectory: defaultDirectory,
            suggestedName: suggestedName
        )
    }
}

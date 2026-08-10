import Foundation
import AppKit

/// 未保存决策结果（Task 1）。
///
/// `.proceed` 表示用户已保存或选择不保存，关闭流程可继续；
/// `.cancel` 表示用户取消或保存失败，必须保留窗口与 Untitled 内容。
enum UnsavedCloseDecision: Sendable, Equatable {
    case proceed
    case cancel
}

/// 未保存文档关闭前的交互边界（Task 1）。
///
/// 生产实现弹 `NSAlert` 与 `NSSavePanel`；测试注入 fake 实现，避免 headless 环境无法展示 AppKit UI。
/// 所有方法在 `@MainActor` 执行（弹窗需要主线程 + 窗口上下文）。
@MainActor
protocol UnsavedCloseInteraction {
    /// 展示「保存 / 不保存 / 取消」提示。
    /// - Returns: `.save` / `.dontSave` / `.cancel`。
    func presentUnsavedChangesPrompt(for session: WindowSession) -> UnsavedPromptChoice

    /// 选择 Save As 目标 URL。用户取消返回 nil。
    func chooseSaveAsTarget(for session: WindowSession, suggestedName: String, defaultDirectory: URL?) async -> URL?

    /// 展示「保存工作区 / 不保存 / 取消」提示。
    func presentUnsavedWorkspacePrompt(for session: WindowSession) -> UnsavedPromptChoice

    /// 选择工作区保存目标 URL。用户取消返回 nil。
    func chooseWorkspaceSaveTarget(for session: WindowSession, suggestedName: String, defaultDirectory: URL?) async -> URL?
}

extension UnsavedCloseInteraction {
    /// 默认实现：保持既有测试 fake 可编译（既有场景不会进入工作区分支）。
    func presentUnsavedWorkspacePrompt(for session: WindowSession) -> UnsavedPromptChoice {
        .dontSave
    }

    /// 默认实现：同上。
    func chooseWorkspaceSaveTarget(for session: WindowSession, suggestedName: String, defaultDirectory: URL?) async -> URL? {
        nil
    }
}

/// 「保存 / 不保存 / 取消」三选一。
enum UnsavedPromptChoice: Sendable, Equatable {
    case save
    case dontSave
    case cancel
}

/// 可复用的单文档关闭协调组件（Task 1）。
///
/// 职责限定为：询问 → 选择 Save As 目标 → 等待保存完成 → 返回 `.proceed` / `.cancel`。
/// 保存失败必须返回 `.cancel`，保留窗口与 Untitled 内容。
/// 不负责应用级遍历、重入控制或 termination reply（那是 `ApplicationTerminationCoordinator` 的事），
/// 也不再重复实现弹窗（委托给注入的 `UnsavedCloseInteraction`）。
@MainActor
final class UnsavedDocumentCloseCoordinator {

    private let interaction: UnsavedCloseInteraction

    init(interaction: UnsavedCloseInteraction) {
        self.interaction = interaction
    }

    /// 询问并处理单个 session 的未保存 Untitled。
    ///
    /// 调用方应仅在 `session.prepareForClose() == .needsUntitledDecision` 时调用本方法。
    /// 保存是异步的（文件写入在后台），但本方法不阻塞主 actor —— 它 `await` 写入，调用方在
    /// 异步上下文里等待结果即可。
    ///
    /// 成功路径副作用（所有权迁移由调用方负责，本方法只处理文档状态）：
    /// - 选择保存且写入成功：内容落盘，Untitled 清除，返回 `.proceed`。
    /// - 选择不保存：丢弃 Untitled 临时文件，返回 `.proceed`。
    /// - 取消 / 保存面板取消 / 写入失败：返回 `.cancel`，保留窗口与内容。
    func resolveUnsavedChanges(for session: WindowSession) async -> UnsavedCloseDecision {
        let doc = session.documentViewModel
        let settings = SettingsModel.shared

        let choice = interaction.presentUnsavedChangesPrompt(for: session)

        switch choice {
        case .save:
            let defaultDir = settings.lastOpenedDirectory ?? settings.lastOpenedFile?.deletingLastPathComponent()
            let suggestedName = doc.fileName.isEmpty ? "Untitled.md" : doc.fileName

            guard let saveURL = await interaction.chooseSaveAsTarget(
                for: session,
                suggestedName: suggestedName,
                defaultDirectory: defaultDir
            ) else {
                // 用户取消保存面板：保留窗口与内容
                return .cancel
            }

            let success = await doc.saveAs(to: saveURL)
            if success {
                // 保存成功：清除未保存标记（saveAs 已落盘并清 isUntitled）
                session.appViewModel.hasUnsavedUntitled = false
                return .proceed
            } else {
                // 写入失败：saveAs 已设置 fileError 并保留原内容，窗口保持打开
                return .cancel
            }

        case .dontSave:
            doc.discardUntitledFile()
            session.appViewModel.hasUnsavedUntitled = false
            return .proceed

        case .cancel:
            return .cancel
        }
    }
}

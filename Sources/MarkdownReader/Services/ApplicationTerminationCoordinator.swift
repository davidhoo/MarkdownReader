import Foundation
import AppKit
import os
import MarkdownReaderKit

/// 应用级终止状态机（Task 1）。
enum TerminationState: Sendable, Equatable {
    case idle
    case processing
    case terminating
}

/// 应用级终止协调器（Task 1 重构）。
///
/// 只负责：应用级遍历、重入控制、最终 termination reply。
/// 不再重复实现弹窗 —— 单文档保存确认委托给 `UnsavedDocumentCloseCoordinator`。
///
/// 重入语义：
/// - `applicationShouldTerminate` 返回 `.terminateLater` 前，同步把状态从 `.idle`
///   切到 `.processing`，消除「重复 Cmd+Q 排队」窗口。重复 Cmd+Q 在 `.processing`
///   期间直接 no-op，不会再产生第二个 `reply`。
/// - 全部 session 允许关闭后 `reply(true)`，状态切到 `.terminating`（不复位 idle，
///   因为应用即将退出）。
/// - 任一 session 取消或保存失败 `reply(false)`，状态复位 `.idle` 允许下次尝试。
@MainActor
final class ApplicationTerminationCoordinator {

    private let logger = Logger(subsystem: "com.markdownreader.app", category: "TerminationCoordinator")

    weak var coordinator: WindowCoordinator?

    /// 单文档关闭协调（弹窗/保存面板边界），由外部注入；默认用 AppKit 实现。
    private var closeInteraction: UnsavedCloseInteraction

    /// 复用的单文档关闭协调器（无状态，可共享，避免每次调用新建）。
    private lazy var closeCoordinator = UnsavedDocumentCloseCoordinator(interaction: closeInteraction)

    /// 当前终止状态。`applicationShouldTerminate` 同步读改写，消除重入窗口。
    private(set) var state: TerminationState = .idle

    init(
        coordinator: WindowCoordinator? = nil,
        closeInteraction: UnsavedCloseInteraction = AppKitUnsavedCloseInteraction()
    ) {
        self.coordinator = coordinator
        self.closeInteraction = closeInteraction
    }

    /// 注入交互边界（测试用）。重置复用的协调器以绑定新交互。
    func setCloseInteraction(_ interaction: UnsavedCloseInteraction) {
        closeInteraction = interaction
        closeCoordinator = UnsavedDocumentCloseCoordinator(interaction: closeInteraction)
    }

    // MARK: - 单窗口关闭（供 WindowCloseGuard 复用）

    /// 同步判断是否可直接关闭（无脏 Untitled）。
    /// 脏 Untitled 由 `resolveUnsavedChanges` 异步处理后经 `allowNextClose` 复关。
    func shouldCloseImmediately(session: WindowSession) -> Bool {
        return session.prepareForClose() == .close
    }

    /// 异步处理单个脏 Untitled session 的保存确认。
    /// 供 Cmd+W 流程调用，调用方在 `Task` 内 await 结果。
    func resolveUnsavedChanges(for session: WindowSession) async -> UnsavedCloseDecision {
        return await closeCoordinator.resolveUnsavedChanges(for: session)
    }

    /// 异步处理单个 session 的全部关闭阻塞项：先脏 Untitled 文档，后脏工作区。
    /// 任一环节取消/失败即返回 `.cancel`，保留窗口。
    func resolveCloseBlockers(for session: WindowSession) async -> UnsavedCloseDecision {
        if session.documentViewModel.isUntitled && session.documentViewModel.isDirty {
            let decision = await closeCoordinator.resolveUnsavedChanges(for: session)
            if decision == .cancel {
                return .cancel
            }
        }
        if session.workspaceNeedsSaveDecision {
            return await resolveWorkspaceChanges(for: session)
        }
        return .proceed
    }

    /// 异步处理脏工作区的保存确认：询问 → 选择目标 → 落盘。
    /// 保存失败/取消返回 `.cancel`，保留窗口与工作区状态。
    func resolveWorkspaceChanges(for session: WindowSession) async -> UnsavedCloseDecision {
        let settings = SettingsModel.shared
        let choice = closeInteraction.presentUnsavedWorkspacePrompt(for: session)

        switch choice {
        case .save:
            // 已关联工作区文件：直接覆写原文件，不弹另存为面板
            if let existingURL = session.appViewModel.workspaceFileURL {
                return session.performWorkspaceSave(to: existingURL) ? .proceed : .cancel
            }

            // 未关联文件：走另存为面板
            let suggestedName = (session.fileTreeViewModel.rootDirectories.first?.lastPathComponent ?? "Workspace")
                + "." + WorkspaceDocument.fileExtension
            let defaultDir = settings.lastOpenedDirectory ?? settings.lastOpenedFile?.deletingLastPathComponent()

            guard let saveURL = await closeInteraction.chooseWorkspaceSaveTarget(
                for: session,
                suggestedName: suggestedName,
                defaultDirectory: defaultDir
            ) else {
                // 用户取消保存面板：保留窗口与工作区状态
                return .cancel
            }

            return session.performWorkspaceSave(to: saveURL) ? .proceed : .cancel

        case .dontSave:
            // 丢弃工作区更改：复位脏标记，窗口可关闭
            session.fileTreeViewModel.markWorkspaceSaved()
            return .proceed

        case .cancel:
            return .cancel
        }
    }

    // MARK: - 应用退出

    /// 进入终止处理：同步切到 `.processing`，返回是否接管。
    /// 重复 Cmd+Q 在 `.processing` / `.terminating` 期间返回 false，调用方不再 `reply`。
    @discardableResult
    func beginTermination() -> Bool {
        guard state == .idle else {
            logger.info("beginTermination ignored: state=\(String(describing: self.state))")
            return false
        }
        state = .processing
        return true
    }

    /// 异步串行处理所有脏 Untitled session，最终 `reply(toApplicationShouldTerminate:)`。
    /// 由 `applicationShouldTerminate` 经 `beginTermination` 切到 `.processing` 后调用。
    func processTermination() async {
        guard state == .processing else {
            logger.info("processTermination ignored: state=\(String(describing: self.state))")
            return
        }

        guard let coordinator else {
            // 无 coordinator：直接放行
            state = .terminating
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }

        // 按确定顺序（WindowID uuid 字符串）处理所有有关闭阻塞项的 session
        // （脏 Untitled 文档或脏工作区），保证可测试、可复现。
        let dirtySessions = coordinator.sessions.values
            .filter {
                ($0.documentViewModel.isUntitled && $0.documentViewModel.isDirty)
                    || $0.workspaceNeedsSaveDecision
            }
            .sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }

        for session in dirtySessions {
            let decision = await resolveCloseBlockers(for: session)
            if decision == .cancel {
                // 任一 session 取消或保存失败：终止整个退出流程，复位 idle 允许下次尝试
                state = .idle
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
        }

        // 全部允许关闭：放行退出，不复位 idle（应用即将退出）
        state = .terminating
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func handleReopen() {
        guard let coordinator else { return }
        if coordinator.hasRegisteredSession {
            if let lastID = coordinator.lastActiveWindowID {
                coordinator.activate(windowID: lastID)
            }
        } else {
            coordinator.openBlankWindow()
        }
    }

    // MARK: - 测试支持

    /// 仅供测试：复位终止状态。生产代码不应调用。
    func resetStateForTesting() {
        state = .idle
    }
}

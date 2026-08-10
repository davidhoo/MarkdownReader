import SwiftUI
import MarkdownReaderKit

/// 目录树中单个文件/目录行视图
struct FileRowView: View {
    let node: FileNode
    let fileTreeViewModel: FileTreeViewModel
    let documentViewModel: DocumentViewModel
    /// Task 9：用于跨窗口所有权标记。
    let session: WindowSession
    /// 是否为工作区顶层根节点：工作区模式下显示绝对路径副标题，便于区分多根。
    var isWorkspaceRoot: Bool = false
    @Environment(\.themeColors) private var themeColors
    @Environment(\.language) private var language

    /// 当前文件是否有未保存的修改
    private var isDirty: Bool {
        !node.isDirectory && documentViewModel.isFileDirty(at: node.path)
    }

    /// Task 9：该文件是否由「本窗口之外」的窗口持有。仅文件行判断。
    private var isOpenInAnotherWindow: Bool {
        guard !node.isDirectory else { return false }
        return session.coordinator?.isFileOwnedByAnotherWindow(node.path, besides: session.id) ?? false
    }

    var body: some View {
        HStack(spacing: 6) {
            if node.isDirectory {
                Image(systemName: "folder.fill")
                    .foregroundStyle(themeColors.ink)
                    .frame(width: 16)
            } else {
                Image(systemName: node.isMarkdown ? "doc.text" : "doc")
                    .foregroundStyle(node.isMarkdown ? themeColors.fgSecondary : themeColors.fgMuted)
                    .frame(width: 16)
            }

            Text(node.name)
                .foregroundStyle(node.isMarkdown || node.isDirectory ? themeColors.ink : themeColors.fgSecondary)
                .lineLimit(1)
                .layoutPriority(1)  // 名称优先保留完整宽度，路径副标题先被截断

            // 工作区模式的顶层根：名称后追加绝对路径（弱色），便于区分同名/多根目录。
            // 宽度不足时由 Spacer 前的行内布局自然截断。
            if isWorkspaceRoot && node.isDirectory && session.appViewModel.isWorkspaceMode {
                Text(node.path.path)
                    .font(.system(size: 10))
                    .foregroundStyle(themeColors.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if isDirty {
                Text("*")
                    .foregroundStyle(themeColors.accent)
            }

            Spacer()

            // Task 9：跨窗口所有权标记。macwindow 图标 + 三语 tooltip/accessibility。
            // 不改变行高，避免目录树抖动。
            if isOpenInAnotherWindow {
                Image(systemName: "macwindow")
                    .font(.system(size: 10))
                    .foregroundStyle(themeColors.fgMuted)
                    .help(L10n.tr(.fileOwnedByAnotherWindow, language: language))
                    .accessibilityLabel(L10n.tr(.fileOwnedByAnotherWindow, language: language))
            }
        }
        .padding(.vertical, 4)
    }
}

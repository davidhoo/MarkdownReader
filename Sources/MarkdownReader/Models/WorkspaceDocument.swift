import Foundation

/// 工作区持久化模型（.mdworkspace 文件内容）。
///
/// 一个工作区 = 一组有序的根目录 + 目录浏览状态（展开目录、选中文件）。
/// 路径存绝对路径（应用非沙箱，无需 security-scoped bookmark）；
/// 加载时不存在的目录跳过，不整体失败。
struct WorkspaceDocument: Codable, Equatable {

    /// 当前格式版本。
    static let currentVersion = 1

    /// 工作区文件扩展名。
    static let fileExtension = "mdworkspace"

    /// 格式版本号。
    var version: Int

    /// 根目录绝对路径列表（有序，决定侧边栏展示顺序）。
    var folders: [String]

    /// 展开状态的目录绝对路径列表。
    var expandedDirs: [String]

    /// 上次选中的文件绝对路径（可选）。
    var selectedFile: String?

    init(
        version: Int = WorkspaceDocument.currentVersion,
        folders: [String],
        expandedDirs: [String] = [],
        selectedFile: String? = nil
    ) {
        self.version = version
        self.folders = folders
        self.expandedDirs = expandedDirs
        self.selectedFile = selectedFile
    }

    /// 判断给定 URL 是否为工作区文件（按扩展名，大小写不敏感）。
    static func isWorkspaceFile(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare(fileExtension) == .orderedSame
    }
}

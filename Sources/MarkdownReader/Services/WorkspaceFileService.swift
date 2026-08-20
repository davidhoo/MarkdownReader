import Foundation

/// 工作区文件（.mdworkspace）读写服务。
///
/// 纯逻辑层：无 UI 依赖，可单测。格式为 UTF-8 JSON（见 `WorkspaceDocument`）。
enum WorkspaceFileService {

    /// 工作区文件读写错误。
    enum WorkspaceFileError: Error, Equatable {
        /// 文件不存在或不可读
        case unreadable(URL)
        /// JSON 解码失败（非工作区文件或已损坏）
        case decodeFailed(URL)
        /// 不支持的高版本格式
        case unsupportedVersion(Int)
        /// 工作区不含任何文件夹
        case emptyWorkspace
    }

    /// 保存工作区文档到指定 URL（UTF-8 JSON，带缩进便于人工检查）。
    /// 若目标 URL 缺少 `.mdworkspace` 扩展名则自动补齐。
    /// - Returns: 实际写入的 URL。
    @discardableResult
    static func save(_ document: WorkspaceDocument, to url: URL) throws -> URL {
        var target = url
        if target.pathExtension.caseInsensitiveCompare(WorkspaceDocument.fileExtension) != .orderedSame {
            target = target.appendingPathExtension(WorkspaceDocument.fileExtension)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        try data.write(to: target, options: .atomic)
        return target
    }

    /// 从指定 URL 加载工作区文档。
    /// - Throws: `WorkspaceFileError`
    static func load(from url: URL) throws -> WorkspaceDocument {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw WorkspaceFileError.unreadable(url)
        }
        let data = try Data(contentsOf: url)
        let document: WorkspaceDocument
        do {
            document = try JSONDecoder().decode(WorkspaceDocument.self, from: data)
        } catch {
            throw WorkspaceFileError.decodeFailed(url)
        }
        guard document.version <= WorkspaceDocument.currentVersion else {
            throw WorkspaceFileError.unsupportedVersion(document.version)
        }
        guard !document.folders.isEmpty else {
            throw WorkspaceFileError.emptyWorkspace
        }
        return document
    }

    /// 从会话状态构造工作区文档（保存入口复用）。
    /// - Parameters:
    ///   - folders: 当前根目录列表（有序）
    ///   - expandedDirs: 当前展开的目录集合
    ///   - selectedFile: 当前选中文件
    static func makeDocument(
        folders: [URL],
        expandedDirs: Set<URL>,
        selectedFile: URL?
    ) -> WorkspaceDocument {
        WorkspaceDocument(
            folders: folders.map(\.path),
            expandedDirs: expandedDirs.map(\.path).sorted(),
            selectedFile: selectedFile?.path
        )
    }
}

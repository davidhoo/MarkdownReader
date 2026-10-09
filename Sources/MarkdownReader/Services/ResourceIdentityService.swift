import Foundation

/// 资源身份规范化服务。
///
/// 集中所有路径标准化逻辑，调用处不再复制规范化代码。规则：
///
/// 1. 使用 `standardizedFileURL` 消除 `.`、`..`。
/// 2. 对已存在路径使用 `resolvingSymlinksInPath()`，使符号链接与其目标共享身份。
/// 3. 查询卷是否大小写敏感；不敏感卷的 comparison key 统一为小写，避免 `A.md`/`a.md` 绕过去重。
/// 4. 保留 canonical URL 用于显示和文件操作。
/// 5. 文件不存在时仍生成稳定的标准化 path key，供错误和幂等处理使用。
///
/// 该服务本身无状态，安全跨线程使用（遵守 `Sendable`）。卷大小写敏感查询直接
/// 读取 `URLResourceValues`，不维护可变缓存，避免 Swift 6 并发隔离问题。
struct ResourceIdentityService: Sendable {

    init() {}

    /// 为给定 URL 与类型生成规范化身份。
    /// - Parameters:
    ///   - url: 资源 URL（必须是 file URL，见设计文档 §6.2）。
    ///   - kind: 资源类型（文件或目录）。类型不可互换。
    /// - Returns: 规范化后的 `ResourceIdentity`。
    /// - Throws: 非 file URL 抛 `OpenRoutingError.unsupportedType`。
    func identity(for url: URL, kind: ResourceIdentity.Kind) throws -> ResourceIdentity {
        guard url.isFileURL else {
            throw OpenRoutingError.unsupportedType(url)
        }
        let standardized = url.standardizedFileURL
        let resolved: URL
        if FileManager.default.fileExists(atPath: standardized.path) {
            // 已存在路径解析符号链接，使链接与目标共享身份
            resolved = standardized.resolvingSymlinksInPath()
        } else {
            // 不存在路径不能 resolvingSymlinksInPath（会失败），用标准化结果
            resolved = standardized
        }

        let key = comparisonKey(for: resolved, kind: kind)
        return ResourceIdentity(kind: kind, canonicalURL: resolved, comparisonKey: key)
    }

    /// 生成稳定的比较 key。
    /// 格式：`<kind>:<case-folded-path>`，确保文件/目录不冲突，且大小写不敏感卷归一。
    private func comparisonKey(for url: URL, kind: ResourceIdentity.Kind) -> String {
        let path = url.path
        let folded: String
        if isCaseSensitive(volumeFor: url) {
            folded = path
        } else {
            folded = path.lowercased()
        }
        return "\(kindPrefix(kind)):\(folded)"
    }

    private func kindPrefix(_ kind: ResourceIdentity.Kind) -> String {
        switch kind {
        case .file: return "file"
        case .directory: return "dir"
        case .workspace: return "ws"
        }
    }

    /// 查询给定 URL 所在卷是否大小写敏感。
    /// 默认假设大小写敏感（APFS 默认）；查询失败回退到敏感。
    private func isCaseSensitive(volumeFor url: URL) -> Bool {
        // 用卷的 case-sensitive 名字能力判断。直接对原 URL 查询该键，避免依赖
        // volumeURL 在某些 SDK 上的可用性差异。
        do {
            let values = try url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            return values.volumeSupportsCaseSensitiveNames ?? true
        } catch {
            return true
        }
    }
}

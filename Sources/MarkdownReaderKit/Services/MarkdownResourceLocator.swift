import Foundation

/// 统一负责 MarkdownReader 主应用、Quick Look 扩展、PDF 导出以及单测环境下的静态资源定位与加载。
///
/// 解决核心问题：
/// 1. 兼容现代 SwiftPM 的嵌套 bundle 结构（`MarkdownReader_MarkdownReader.bundle/Contents/Resources/Resources/`）
///    与历史平铺结构（`MarkdownReader_MarkdownReader.bundle/Resources/`）。
/// 2. 避免各处硬编码猜测 `Bundle.main.resourceURL`，支持指定 `hostBundle` 与自定义候选路径。
/// 3. 主应用与 Quick Look 各自只解析传入的 host bundle，互不借用对方的资源。
/// 4. 统一 MIME 类型推导与非空/合规性校验。
public enum MarkdownResourceLocator {

    public static let defaultBundleName = "MarkdownReader_MarkdownReader.bundle"

    /// 获取指定宿主 Bundle 下的所有候选资源根目录（已去重并保序）
    public static func candidateResourceRoots(
        for hostBundle: Bundle = .main,
        customSearchPaths: [URL]? = nil
    ) -> [URL] {
        // 1. 若显式指定了自定义搜索目录，遵守 v2.4.5 语义仅使用该目录，不回退 Bundle 默认目录
        if let customSearchPaths {
            return customSearchPaths
        }

        var roots: [URL] = []

        // 2. 宿主 Bundle 的 resourceURL
        if let hostResourceURL = hostBundle.resourceURL {
            roots.append(contentsOf: bundleResourceRoots(inDirectory: hostResourceURL))
            roots.append(hostResourceURL.appendingPathComponent("Resources"))
            roots.append(hostResourceURL)
        }

        // 扩展与主应用各自解析自己的 bundle。不向上搜宿主 App，
        // 否则 Quick Look 会读到主应用里未裁剪的 mermaid.min.js。

        // 3. 去重保序
        var seen = Set<String>()
        var uniqueRoots: [URL] = []
        for root in roots {
            let standardPath = root.standardizedFileURL.path
            if !seen.contains(standardPath) {
                seen.insert(standardPath)
                uniqueRoots.append(root)
            }
        }

        return uniqueRoots
    }

    /// 在指定目录下查找资源 bundle（如 `MarkdownReader_MarkdownReader.bundle`）并解析其内部根路径
    public static func bundleResourceRoots(
        inDirectory dir: URL,
        bundleName: String = defaultBundleName
    ) -> [URL] {
        let nestedBundleURL = dir.appendingPathComponent(bundleName)
        guard FileManager.default.fileExists(atPath: nestedBundleURL.path) else {
            return []
        }

        var roots: [URL] = []

        // 优先通过 Foundation Bundle(url:) 解析
        if let innerBundle = Bundle(url: nestedBundleURL),
           let innerResourceURL = innerBundle.resourceURL {
            // SwiftPM `.copy("Resources")` 产生的资源存放在 innerResourceURL/Resources
            roots.append(innerResourceURL.appendingPathComponent("Resources"))
            roots.append(innerResourceURL)
        }

        // 兜底补全各层可能布局
        roots.append(nestedBundleURL.appendingPathComponent("Contents/Resources/Resources"))
        roots.append(nestedBundleURL.appendingPathComponent("Contents/Resources"))
        roots.append(nestedBundleURL.appendingPathComponent("Resources"))
        roots.append(nestedBundleURL)

        var seen = Set<String>()
        var uniqueRoots: [URL] = []
        for root in roots {
            let standardPath = root.standardizedFileURL.path
            if !seen.contains(standardPath) {
                seen.insert(standardPath)
                uniqueRoots.append(root)
            }
        }
        return uniqueRoots
    }

    /// 解析指定相对或绝对资源路径为本地文件 URL
    public static func resolveResourceURL(
        path: String,
        baseURL: URL? = nil,
        resourceSearchPaths: [URL]? = nil,
        hostBundle: Bundle = .main
    ) -> URL? {
        var cleanPath = path
        if cleanPath.hasPrefix("/") {
            cleanPath = String(cleanPath.dropFirst())
        }

        // 1. 绝对文件路径
        let absoluteURL = URL(fileURLWithPath: "/" + cleanPath)
        if FileManager.default.fileExists(atPath: absoluteURL.path) {
            return absoluteURL
        }

        // 2. 基于 baseURL 的相对路径（例如 Markdown 本地引用的相对图片）
        if let baseURL {
            let relativeURL = baseURL.appendingPathComponent(cleanPath)
            if FileManager.default.fileExists(atPath: relativeURL.path) {
                return relativeURL
            }
        }

        // 3. 在候选根目录中检索
        let roots = candidateResourceRoots(for: hostBundle, customSearchPaths: resourceSearchPaths)
        for root in roots {
            let candidate = root.appendingPathComponent(cleanPath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    /// 读取资源文件并校验非空与 MIME 类型
    public static func loadResourceData(at resourceURL: URL) throws -> (data: Data, mimeType: String) {
        guard FileManager.default.fileExists(atPath: resourceURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let data = try Data(contentsOf: resourceURL)
        let ext = resourceURL.pathExtension.lowercased()

        // 核心排版/脚本/字体资源若为 0 字节，视为损坏或未正确打包
        let isCriticalAsset = ["css", "js", "woff", "woff2", "ttf", "otf"].contains(ext)
        if isCriticalAsset && data.isEmpty {
            throw CocoaError(.fileReadCorruptFile)
        }

        let mime = mimeType(for: ext)
        return (data, mime)
    }

    /// 根据文件后缀名推导 MIME 类型
    public static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "html", "htm": return "text/html"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "json": return "application/json"
        case "map": return "application/json"
        default: return "application/octet-stream"
        }
    }
}

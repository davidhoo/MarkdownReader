import Foundation

/// Mermaid 图表的绘制引擎。
///
/// 用户仍写 ` ```mermaid `。本枚举只决定页面壳加载哪一份脚本：
/// Mermaid.js 保持现有布局；Pele 同步输出可随主题变色的 SVG。
/// 默认 `.mermaid`，缺失或无法识别的偏好值也回退到它。
public enum DiagramRenderEngine: String, CaseIterable, Codable, Sendable, Identifiable {
    case mermaid
    case pele

    public var id: String { rawValue }

    /// `mr:///` 下的脚本路径。一次页面只加载其中一份。
    public var scriptResourcePath: String {
        switch self {
        case .mermaid: return "js/mermaid.min.js"
        case .pele: return "js/pele.global.js"
        }
    }

    public var scriptTag: String {
        "<script src=\"mr:///\(scriptResourcePath)\"></script>"
    }
}

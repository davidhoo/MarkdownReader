import Foundation

/// 文档复制按钮共享的 SF Symbol 名称常量。
///
/// 唯一维护默认态与成功态的 symbol name，供原生 SwiftUI `Image(systemName:)`
/// 与 WebKit 渲染模式（经 `SFSymbolWebImageProvider` 栅格化）共用，避免两处
/// 维护不一致的图标图形。
public enum DocumentCopySymbol: String, Sendable, Equatable {
    /// 默认态：两张重叠文档（与顶部路径按钮、编辑模式一致）。
    case copy = "doc.on.doc"
    /// 成功态：对号。
    case copied = "checkmark"
}

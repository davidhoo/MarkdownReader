import Foundation

/// 模式切换专用的小数源码位置锚点。
///
/// 与既有 `SourceLine`（整数、1-based，供大纲/查找/标题跳转使用）并列，**仅**用于单栏
/// Raw ↔ Rendered 模式切换时的位置交接。两者不得混用：`sourcePosition` 不是数组索引，
/// 也不得传给大纲或查找。
///
/// - `sourcePosition`：1-based 小数源码位置。`18.4` 表示第 18 行到第 19 行之间的 40%
///   位置。初始化要求 `>= 1`，非法输入触发 `precondition` 失败。
/// - `documentProgress`：全文滚动进度兜底，值域 `0...1`。源码范围、DOM 布局或 Raw 排版
///   任一不可用时才使用；两者都不可用时降级到文档顶部（即 `0`）。初始化采用钳制策略，
///   超出 `0...1` 的输入会被夹到边界，不崩溃也不保留越界值。
///
/// 完整块范围为闭区间 `[start, end]`；映射时使用半开范围 `[start, end + 1)`，从而单行
/// 块也有非零跨度。
public struct SourceScrollAnchor: Equatable, Sendable {
    /// 1-based 小数源码位置（`>= 1`）。
    public let sourcePosition: Double

    /// 全文滚动进度兜底，钳制到 `0...1`。
    public let documentProgress: Double

    public init(sourcePosition: Double, documentProgress: Double) {
        precondition(sourcePosition >= 1, "SourceScrollAnchor.sourcePosition must be >= 1")
        self.sourcePosition = sourcePosition
        self.documentProgress = min(max(documentProgress, 0), 1)
    }
}

/// 一次性模式切换位置交接。
///
/// 携带目标模式、内容版本和 UUID，**仅**由目的视图消费/确认。采样与回执都必须验证
/// `contentVersion`，过期内容、过期模式或快速 A→B→A 切换产生的回调必须丢弃。
public struct ScrollTransfer: Equatable, Sendable, Identifiable {
    /// 请求身份；目的视图应用定位后必须以相同 UUID 回执。
    public let id: UUID

    /// 目的模式（`.rendered` 或 `.raw`）。仅目的模式可消费本次交接。
    public let destination: DisplayMode

    /// 创建交接时的内容版本号。回执时须与当前 `contentVersion` 比对，不一致则丢弃。
    public let contentVersion: Int

    /// 位置锚点。
    public let anchor: SourceScrollAnchor

    public init(id: UUID, destination: DisplayMode, contentVersion: Int, anchor: SourceScrollAnchor) {
        self.id = id
        self.destination = destination
        self.contentVersion = contentVersion
        self.anchor = anchor
    }
}

/// 模式切换定位策略：决定用精确小数源码位置还是全文进度兜底来恢复阅读位置。
///
/// 纯函数，无 UI/布局依赖，可单测。`canResolveSourcePosition` 表示目的视图当前能否
/// 把 `sourcePosition` 映射到真实布局（源码范围/DOM/Raw 排版任一可用即为 true）。
/// 契约：源码范围、DOM 布局或 Raw 排版任一不可用时才用 `documentProgress`；两者都不可
/// 用时降级到文档顶部（由 `documentProgress == 0` 表达）。
public enum SourceAnchorResolution {
    /// 用 `anchor.sourcePosition` 精确定位。
    case sourcePosition
    /// 用 `anchor.documentProgress` 全文进度兜底定位。
    case documentProgress

    /// 根据锚点与目的视图当前的可解析性选择定位模式。
    /// - 可解析 → `.sourcePosition`；否则 → `.documentProgress`。
    public static func mode(for anchor: SourceScrollAnchor, canResolveSourcePosition: Bool) -> SourceAnchorResolution {
        canResolveSourcePosition ? .sourcePosition : .documentProgress
    }
}

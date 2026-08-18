/// Markdown 源码行的 1-based 位置值类型。
///
/// 统一所有跨模块、跨模式的源码行号契约：禁止裸 `Int` 传递行号，避免 0-based 数组索引
/// 与 1-based 行号混用导致的偏差。
///
/// - `oneBased`：对应 swift-markdown `SourceLocation.line`、HTML `data-line` 与
///   JavaScript `MR.scrollToLine`，值域 `1...`。
/// - `zeroBasedIndex`：仅在 Raw 编辑器从 `content.components(separatedBy: "\n")`
///   计算字符偏移时使用，值域 `0...`。
///
/// 未定位的源码位置用 `nil` 表示，不引入 `0` 哨兵；非法输入触发 `precondition` 失败。
public struct SourceLine: Equatable, Hashable, Sendable {
    public let oneBased: Int

    public init(oneBased: Int) {
        precondition(oneBased >= 1, "SourceLine.oneBased must be >= 1")
        self.oneBased = oneBased
    }

    public init(zeroBasedIndex: Int) {
        precondition(zeroBasedIndex >= 0, "SourceLine.zeroBasedIndex must be >= 0")
        self.oneBased = zeroBasedIndex + 1
    }

    public var zeroBasedIndex: Int { oneBased - 1 }

    public static let first = SourceLine(oneBased: 1)
}

import Foundation

/// 资源的规范化身份。
///
/// 目录身份和文件身份不可互换；相同路径的 `.file` 与 `.directory` 不相等。
/// 相等性只基于 `kind` 与 `comparisonKey`，`canonicalURL` 仅用于显示和文件操作。
struct ResourceIdentity: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case file
        case directory
        /// 工作区文件（.mdworkspace），按文件身份参与路由与所有权
        case workspace
    }

    let kind: Kind
    let canonicalURL: URL
    let comparisonKey: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.comparisonKey == rhs.comparisonKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(comparisonKey)
    }
}

import Foundation
import MarkdownReaderKit

/// WebView 渲染触发的最终状态快照。
///
/// 只表示 WebView 实际需要渲染的状态（文件身份、内容、强制刷新世代），
/// 不包含主题、padding、查找或缩放——这些继续走独立的局部 JavaScript 更新，
/// 不应被误升级为完整页面重载。详见
/// `docs/plans/2026-08-12-webview-render-trigger-coalescing-design.md`。
struct WebViewRenderSnapshot: Equatable {
    let fileURL: URL?
    let content: String
    let contentVersion: Int
}

/// `WebViewRenderPolicy.action(previous:next:)` 的可选结果。
enum WebViewRenderAction: Equatable {
    case none
    case replaceContent
    case loadPage
}

/// 纯渲染决策：依据“文件身份、内容、强制刷新世代”选择渲染动作。
///
/// 与 SwiftUI/WebKit 无关，以便单元测试锁定规则：
/// 1. 没有已应用快照：`loadPage`；
/// 2. `fileURL` 改变：`loadPage`（资源基路径、滚动重置、整页初始化均属新文档）；
/// 3. `contentVersion` 改变：`loadPage`（保留 Reload、外部刷新及同内容强制刷新语义）；
/// 4. 仅 `content` 改变：`replaceContent`；
/// 5. 三项都相同：`none`。
enum WebViewRenderPolicy {
    static func action(
        previous: WebViewRenderSnapshot?,
        next: WebViewRenderSnapshot
    ) -> WebViewRenderAction {
        guard let previous else { return .loadPage }
        guard previous.fileURL == next.fileURL else { return .loadPage }
        guard previous.contentVersion == next.contentVersion else { return .loadPage }
        return previous.content == next.content ? .none : .replaceContent
    }
}

/// latest-wins 的请求世代计数器。
///
/// `WebViewMarkdownView` 的三个文档输入（`fileURL`/`content`/`contentVersion`）
/// 任一变化只递增世代；`.task(id: generation)` 在一次 `Task.yield()` 后读取最终快照，
/// 旧世代的增量 JavaScript 请求因世代不匹配被拒绝。零延迟：世代递增只是状态失效标记，
/// 不引入任何毫秒级防抖。
struct WebViewRenderScheduler {
    private(set) var generation: UInt = 0

    /// 发起一次渲染请求，返回该请求所属世代。世代只递增，永不重用。
    mutating func request() -> UInt {
        generation &+= 1
        return generation
    }

    /// 该世代是否仍为最新请求。旧世代在 `request()` 后立即失效。
    func accepts(_ generation: UInt) -> Bool {
        generation == self.generation
    }
}

/// 纯运行时升级策略：依据“已加载运行时需求”与“下一份 HTML 的运行时需求”选择渲染动作。
///
/// 与 SwiftUI/WebKit 无关，以便单元测试锁定规则：
/// - `current == nil`（尚未整页加载）：`.loadPage`；
/// - 新旧需求相同：`.replaceContent`（沿用既有 latest-wins 增量替换）；
/// - 需求不同：`.loadPage`（新出现的图表/公式需对应脚本，已加载库无法卸载，必须整页重建）。
///
/// 该策略只判断运行时需求，不替代 `WebViewRenderPolicy` 的 `fileURL` / `contentVersion` 决策。
enum WebViewRuntimePolicy {
    static func action(
        current: MarkdownHTMLService.MarkdownRuntimeRequirements?,
        next: MarkdownHTMLService.MarkdownRuntimeRequirements
    ) -> WebViewRenderAction {
        current == next ? .replaceContent : .loadPage
    }
}

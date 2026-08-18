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

/// 渲染模式过渡的纯状态机。
///
/// 管理 Raw 过渡层在 Raw → Rendered 切换期间是否保持可见。它只回答一个问题：
/// “现在是否还要挡住 WebView，不让用户看到中间的空白或旧渲染内容”。它不取代
/// `WebViewRenderScheduler` 的 latest-wins 世代判定——后者决定哪个渲染请求有效，
/// 这里只决定 Raw 何时可以退场。
///
/// 生命周期：
/// 1. `begin()`：Raw → Rendered 切换的第一步，立即要求 Raw 保持可见，此时还不知道
///    目标渲染世代。
/// 2. `track(generation:)`：WebView 真正发起 `requestRender()` 后报告其世代，覆盖
///    之前的 target；新 track 使任何旧世代的完成回调失效。
/// 3. `completeIfMatching(generation:)`：只有匹配当前 target 的完成回调才能结束过渡；
///    不匹配返回 false 且不改状态。
/// 4. `cancel()`：Rendered → Raw 或 DetailView 消失时清理。
struct RenderedModeTransitionState: Equatable {
    private(set) var targetGeneration: UInt?
    private(set) var keepsRawVisible = false

    /// 开始一次 Raw → Rendered 过渡：Raw 保持可见，等待真实目标世代。
    mutating func begin() {
        targetGeneration = nil
        keepsRawVisible = true
    }

    /// 记录 WebView 实际请求的渲染世代。新世代覆盖旧 target，使旧世代的完成回调失效。
    mutating func track(generation: UInt) {
        guard keepsRawVisible else { return }
        targetGeneration = generation
    }

    /// 仅当传入世代匹配当前目标世代时结束过渡；否则保持不变。
    @discardableResult
    mutating func completeIfMatching(generation: UInt) -> Bool {
        guard keepsRawVisible, let target = targetGeneration, generation == target else {
            return false
        }
        targetGeneration = nil
        keepsRawVisible = false
        return true
    }

    /// 取消过渡：Rendered → Raw 或视图消失。
    mutating func cancel() {
        targetGeneration = nil
        keepsRawVisible = false
    }
}

/// 文档输入变更的种类，用于渲染闸门判断。
///
/// 只区分四个驱动 `requestRender` 的来源：纯内容编辑、文件切换、强制刷新世代、
/// 显示模式切换。它不携带具体值，仅作 eligibility 判定的标签，保持策略与
/// SwiftUI/WebKit 无关。
enum WebViewRenderChange {
    case content
    case fileURL
    case contentVersion
    case displayMode
}

/// 纯渲染闸门：决定某类文档输入变更是否应当请求隐藏的常驻 WebView 重渲染。
///
/// 与 SwiftUI/WebKit 无关，以便单元测试锁定规则：
/// - `content`：仅 Rendered 模式请求。Raw 编辑时隐藏 WebView 保持上次已应用快照，
///   不随每次击键重渲染（固定合同 2）。
/// - `fileURL`：始终请求，保证新文件进入内容区时隐藏 WebView 在后台预热，
///   切到 Rendered 时已是最新文件。
/// - `contentVersion`：始终请求，保留 Reload、外部刷新及同内容强制刷新语义。
/// - `displayMode`：仅进入 Rendered 时请求最新快照；切回 Raw 不请求（无意义）。
enum WebViewRenderEligibility {
    static func shouldRequest(
        change: WebViewRenderChange,
        isRenderedMode: Bool
    ) -> Bool {
        switch change {
        case .content:
            return isRenderedMode
        case .fileURL, .contentVersion:
            return true
        case .displayMode:
            return isRenderedMode
        }
    }
}

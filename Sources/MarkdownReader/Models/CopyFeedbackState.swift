import Foundation

/// 内容区复制反馈的纯状态值类型（Task 1）。
///
/// 不含计时器、不含剪贴板 I/O——只负责跟踪“某次复制成功是否仍处于反馈窗口”，
/// 并保证连续成功时只有最新一次的计时能取消对号，旧计时不会提前清掉新反馈。
///
/// 调用方约定：
/// - 复制真实成功后调用 `begin()`，返回一个 `generation`，启动 5 秒计时。
/// - 计时到期后用同一 `generation` 调用 `reset(ifCurrent:)`。若期间发生过新的
///   成功（generation 已推进），`reset` 是 no-op，旧计时不会清掉新对号。
/// - 模式/文件/视图生命周期变化时调用 `invalidate()`，立即隐藏并废弃所有在途
///   generation，旧计时即便随后触发 `reset` 也无法恢复成功态。
struct CopyFeedbackState {
    /// 当前是否处于“已复制”成功反馈态。
    private(set) var isShowingSuccess = false

    /// 单调递增的成功 generation。每次 `begin()` 推进；`invalidate()` 推进以
    /// 废弃所有在途 reset。
    private var generation = 0

    /// 标记一次真实复制成功，显示对号并返回本次计时用的 generation。
    @discardableResult
    mutating func begin() -> Int {
        generation += 1
        isShowingSuccess = true
        return generation
    }

    /// 计时到期回调。仅当传入的 generation 仍是最新一次成功时才隐藏对号，
    /// 旧 generation 的迟到 reset 不影响后续成功反馈。
    mutating func reset(ifCurrent generation: Int) {
        guard generation == self.generation else { return }
        isShowingSuccess = false
    }

    /// 立即隐藏对号并废弃所有在途计时。通过推进 generation，使任何旧 generation
    /// 的后续 `reset` 都因不匹配而 no-op，避免生命周期结束后旧计时恢复成功态。
    mutating func invalidate() {
        generation += 1
        isShowingSuccess = false
    }
}

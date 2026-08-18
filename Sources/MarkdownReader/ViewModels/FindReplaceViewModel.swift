import Foundation
import MarkdownReaderKit

/// 查找替换功能的搜索状态与逻辑
/// 管理 NSRegularExpression 搜索、匹配导航、搜索选项切换
/// 用于 Raw 模式（通过 TextViewSearchRef 高亮/选择）和 Rendered 模式（行号跳转）
@MainActor
@Observable
final class FindReplaceViewModel {

    // MARK: - 搜索状态

    var searchText: String = ""
    var replaceText: String = ""
    var isCaseSensitive: Bool = false
    var isWholeWord: Bool = false
    var isRegularExpression: Bool = false
    var currentMatchIndex: Int = 0
    var totalMatchCount: Int = 0
    var isReplaceExpanded: Bool = false

    // MARK: - 私有存储

    // Raw 模式：高亮/选择；Rendered 模式：行号跳转
    private(set) var matchRanges: [NSRange] = []
    private var searchResult: SearchResult?

    // MARK: - 计算属性

    var currentMatchRange: NSRange? {
        guard hasResults, currentMatchIndex < matchRanges.count else { return nil }
        return matchRanges[currentMatchIndex]
    }

    // 当前匹配所在源码行（1-based），供 Rendered 模式跳转。
    // 内部 SearchResult 仍用 0-based 行号，仅在此边界构造 SourceLine。
    var currentMatchSourceLine: SourceLine? {
        guard let range = currentMatchRange else { return nil }
        return searchResult.map { SourceLine(zeroBasedIndex: $0.lineNumber(for: range.location)) }
    }

    // "3/15" or "No results"
    var matchDisplayText: String {
        if totalMatchCount == 0 {
            return L10n.tr(.findBarNoResults, language: SettingsModel.shared.languagePref.resolvedLanguage)
        }
        return "\(currentMatchIndex + 1)/\(totalMatchCount)"
    }

    var hasResults: Bool {
        totalMatchCount > 0 && !matchRanges.isEmpty
    }

    // MARK: - 搜索

    func performSearch(in text: String) {
        // 空搜索文本 → 清除结果
        guard !searchText.isEmpty else {
            clearMatchState()
            return
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // 构建正则模式
        let pattern: String
        if isRegularExpression {
            pattern = searchText
        } else {
            // 转义正则特殊字符
            pattern = NSRegularExpression.escapedPattern(for: searchText)
        }

        // 全词匹配：添加 \b 边界
        let finalPattern: String
        if isWholeWord {
            finalPattern = "\\b\(pattern)\\b"
        } else {
            finalPattern = pattern
        }

        // 创建正则（无效正则静默失败 → 显示无结果）
        let options: NSRegularExpression.Options = isCaseSensitive ? [] : .caseInsensitive
        guard let regex = try? NSRegularExpression(pattern: finalPattern, options: options) else {
            clearMatchState()
            return
        }

        // 执行搜索
        let matches = regex.matches(in: text, options: [], range: fullRange)
        matchRanges = matches.map { $0.range }

        // 构建搜索结果（用于行号计算）
        searchResult = SearchResult(text: text, ranges: matchRanges)

        // 更新计数与索引
        totalMatchCount = matchRanges.count
        if totalMatchCount > 0 {
            currentMatchIndex = min(currentMatchIndex, totalMatchCount - 1)
        } else {
            currentMatchIndex = 0
        }
    }

    // MARK: - 导航

    func goToNextMatch() {
        guard hasResults else { return }
        currentMatchIndex = (currentMatchIndex + 1) % totalMatchCount
    }

    func goToPreviousMatch() {
        guard hasResults else { return }
        currentMatchIndex = (currentMatchIndex - 1 + totalMatchCount) % totalMatchCount
    }

    // MARK: - 状态操作

    func clearSearch() {
        searchText = ""
        replaceText = ""
        isCaseSensitive = false
        isWholeWord = false
        isRegularExpression = false
        isReplaceExpanded = false
        clearMatchState()
    }

    func toggleCaseSensitive() {
        isCaseSensitive.toggle()
    }

    func toggleWholeWord() {
        isWholeWord.toggle()
    }

    func toggleRegularExpression() {
        isRegularExpression.toggle()
    }

    func expandReplace() {
        isReplaceExpanded = true
    }

    func collapseReplace() {
        isReplaceExpanded = false
    }

    // Exposed for TextViewSearchRef
    func allMatchRanges() -> [NSRange] {
        matchRanges
    }

    func currentIndex() -> Int {
        currentMatchIndex
    }

    // MARK: - 私有方法

    // Resets match state only, preserves search text and options
    private func clearMatchState() {
        matchRanges = []
        searchResult = nil
        totalMatchCount = 0
        currentMatchIndex = 0
    }
}

// MARK: - SearchResult

/// 搜索结果辅助结构，缓存换行位置用于快速行号计算
private struct SearchResult {

    /// 每行起始位置的字符偏移（0-based）
    /// lines[0] = 0, lines[1] = 第一行长度+1, ...
    private let lineOffsets: [Int]

    /// 匹配范围列表
    private let ranges: [NSRange]

    init(text: String, ranges: [NSRange]) {
        self.ranges = ranges
        self.lineOffsets = Self.computeLineOffsets(from: text)
    }

    /// 根据字符偏移计算行号（0-based）
    func lineNumber(for charOffset: Int) -> Int {
        // 二分查找：找到最后一个 lineOffset <= charOffset 的行
        var lo = 0
        var hi = lineOffsets.count - 1
        while lo <= hi {
            let mid = lo + (hi - lo) / 2
            if lineOffsets[mid] <= charOffset {
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return max(0, hi)
    }

    /// 预计算每行的起始字符偏移
    private static func computeLineOffsets(from text: String) -> [Int] {
        var offsets = [0]
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let newlinePattern = "\n"
        // 使用正则遍历所有换行符位置
        guard let regex = try? NSRegularExpression(pattern: newlinePattern, options: []) else {
            return offsets
        }
        let matches = regex.matches(in: text, options: [], range: fullRange)
        for match in matches {
            // 下一行从换行符后一个字符开始
            offsets.append(match.range.location + 1)
        }
        return offsets
    }
}

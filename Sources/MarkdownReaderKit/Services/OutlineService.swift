import Foundation

/// Markdown 大纲解析服务，从 Markdown 文本中提取标题结构
public enum OutlineService {

    /// 解析 Markdown 内容，返回大纲项列表
    /// - Parameter content: Markdown 原始文本
    /// - Returns: 按出现顺序排列的大纲项
    public static func parse(_ content: String) -> [OutlineItem] {
        var items: [OutlineItem] = []
        let lines = content.components(separatedBy: "\n")
        var isInCodeBlock = false

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 跳过空行
            guard !trimmed.isEmpty else { continue }

            // 追踪代码块状态（``` 围栏代码块）
            if trimmed.hasPrefix("```") {
                isInCodeBlock.toggle()
                continue
            }

            // 跳过代码块内的所有行
            if isInCodeBlock {
                continue
            }

            // ATX 风格标题：# Title
            if let item = parseATXHeading(trimmed, zeroBasedIndex: index) {
                items.append(item)
                continue
            }

            // Setext 风格标题在下一行判断（=== 为 h1，--- 为 h2）
            if index + 1 < lines.count {
                let nextLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
                if nextLine.hasPrefix("===") {
                    items.append(OutlineItem(level: 1, title: trimmed, sourceLine: SourceLine(zeroBasedIndex: index)))
                } else if nextLine.hasPrefix("---") && !trimmed.hasPrefix("#") {
                    items.append(OutlineItem(level: 2, title: trimmed, sourceLine: SourceLine(zeroBasedIndex: index)))
                }
            }
        }

        return items
    }

    /// 解析 ATX 风格标题（# 开头）
    private static func parseATXHeading(_ line: String, zeroBasedIndex: Int) -> OutlineItem? {
        var hashCount = 0
        for char in line {
            if char == "#" {
                hashCount += 1
            } else {
                break
            }
        }

        // 标题层级 1~6
        guard (1...6).contains(hashCount) else { return nil }

        // # 后必须跟空格或行尾
        let afterHashes = line.dropFirst(hashCount)
        guard let firstChar = afterHashes.first, firstChar == " " || firstChar == "\t" else {
            return nil
        }

        // 提取标题文本，去除前导空格和尾部 ###
        var title = afterHashes.dropFirst(1).trimmingCharacters(in: .whitespaces)

        // 去除尾部可选的 ### 序列（ATX 闭合标记）
        if let lastHashRange = title.range(of: "\\s+#+\\s*$", options: .regularExpression) {
            title = String(title[..<lastHashRange.lowerBound])
        }

        title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }

        return OutlineItem(level: hashCount, title: title, sourceLine: SourceLine(zeroBasedIndex: zeroBasedIndex))
    }
}

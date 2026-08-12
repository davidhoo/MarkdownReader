import Foundation
import Markdown
import os.log

public enum MarkdownHTMLService {

    static let logger = Logger(subsystem: "com.markdownreader.app.QuickLook", category: "MarkdownHTMLService")

    public struct RenderResult {
        public let html: String
        public let headings: [HeadingInfo]
    }

    public struct HeadingInfo {
        public let id: String
        public let level: Int
        public let title: String
        public let lineNumber: Int

        public init(id: String, level: Int, title: String, lineNumber: Int) {
            self.id = id
            self.level = level
            self.title = title
            self.lineNumber = lineNumber
        }
    }

    public static func render(_ markdown: String, baseURL: URL? = nil) -> RenderResult {
        let preprocessed = preprocess(markdown)
        let doc = Markdown.Document(parsing: preprocessed)
        var formatter = CustomHTMLFormatter(baseURL: baseURL, inlineImages: false)
        formatter.visit(doc)
        return RenderResult(
            html: formatter.result,
            headings: formatter.headings
        )
    }

    public static func renderWithInlineImages(_ markdown: String, baseURL: URL? = nil) -> RenderResult {
        let preprocessed = preprocess(markdown)
        let doc = Markdown.Document(parsing: preprocessed)
        var formatter = CustomHTMLFormatter(baseURL: baseURL, inlineImages: true)
        formatter.visit(doc)
        return RenderResult(
            html: formatter.result,
            headings: formatter.headings
        )
    }

    public static func buildFullHTML(content: String, themeCSS: String, contentPadding: CGFloat, maxContentWidthFollowsWindow: Bool = false, baseURL: URL?, isDark: Bool = true, documentCopyTitle: String = "", documentCopiedTitle: String = "", documentCopyWebIcons: DocumentCopyWebIcons = .unavailable) -> String {
        buildFullHTML(
            renderResult: render(content, baseURL: baseURL),
            themeCSS: themeCSS,
            contentPadding: contentPadding,
            maxContentWidthFollowsWindow: maxContentWidthFollowsWindow,
            baseURL: baseURL,
            isDark: isDark,
            documentCopyTitle: documentCopyTitle,
            documentCopiedTitle: documentCopiedTitle,
            documentCopyWebIcons: documentCopyWebIcons
        )
    }

    /// 以已有 `RenderResult` 装配完整 HTML 页面壳。不接收原始 Markdown，也不再次调用
    /// `render`，仅供调用方（如 WebView 完整加载）复用单次解析结果，避免重复 Markdown 预处理与解析。
    public static func buildFullHTML(renderResult: RenderResult, themeCSS: String, contentPadding: CGFloat, maxContentWidthFollowsWindow: Bool = false, baseURL: URL?, isDark: Bool = true, documentCopyTitle: String = "", documentCopiedTitle: String = "", documentCopyWebIcons: DocumentCopyWebIcons = .unavailable) -> String {
        let baseURLAttr = baseURL != nil ? " data-base-url=\"\(baseURL!.path.addingXMLAttributeEscapes)\"" : ""
        let copyTitleAttr = " data-document-copy-title=\"\(documentCopyTitle.addingXMLAttributeEscapes)\""
        let copiedTitleAttr = " data-document-copied-title=\"\(documentCopiedTitle.addingXMLAttributeEscapes)\""
        let copyIconVars = documentCopyWebIcons.cssFragment

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <link rel="stylesheet" href="mr:///css/markdown.css">
            <link rel="stylesheet" href="mr:///css/scroll.css">
            <link rel="stylesheet" href="mr:///css/katex.min.css">
            <style id="mr-theme-style">\(themeCSS)</style>
            <style>
            :root { \(copyIconVars) --content-padding: \(contentPadding)px; --content-max-width: \(maxContentWidthFollowsWindow ? "none" : "980px"); }
            </style>
        </head>
        <body>
            <div class="markdown-preview"\(baseURLAttr)\(copyTitleAttr)\(copiedTitleAttr)>
                <div id="mr-content">
                    \(renderResult.html)
                </div>
            </div>
            <script src="mr:///js/mermaid.min.js"></script>
            <script src="mr:///js/katex.min.js"></script>
            <script src="mr:///js/prism-core.min.js"></script>
            <script src="mr:///js/prism-autoloader.min.js"></script>
            <script>
            Prism.plugins.autoloader.languages_path = 'mr:///js/';
            </script>
            <script src="mr:///js/markdown-reader.js" data-is-dark="\(isDark)"></script>
        </body>
        </html>
        """
    }

    public static func buildContentAwareHTML(content: String, themeCSS: String, contentPadding: CGFloat, baseURL: URL?, isDark: Bool, hasMermaid: Bool, hasKaTeX: Bool, inlineImages: Bool = false) -> String {
        let renderResult = inlineImages ? renderWithInlineImages(content, baseURL: baseURL) : render(content, baseURL: baseURL)

        let baseURLAttr = baseURL != nil ? " data-base-url=\"\(baseURL!.path.addingXMLAttributeEscapes)\"" : ""

        var scriptTags = ""
        if hasMermaid {
            scriptTags += "<script src=\"mr:///js/mermaid.min.js\"></script>\n"
        }
        if hasKaTeX {
            scriptTags += "<script src=\"mr:///js/katex.min.js\"></script>\n"
        }
        scriptTags += """
        <script src="mr:///js/prism-core.min.js"></script>
        <script src="mr:///js/prism-autoloader.min.js"></script>
        <script>
        Prism.plugins.autoloader.languages_path = 'mr:///js/';
        </script>
        <script src="mr:///js/markdown-reader.js" data-is-dark="\(isDark)"></script>
        """

        let katexCSS = hasKaTeX ? "<link rel=\"stylesheet\" href=\"mr:///css/katex.min.css\">\n" : ""

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <link rel="stylesheet" href="mr:///css/markdown.css">
            <link rel="stylesheet" href="mr:///css/scroll.css">
            \(katexCSS)<style id="mr-theme-style">\(themeCSS)</style>
            <style>
            :root { --content-padding: \(contentPadding)px; --content-max-width: 980px; }
            </style>
        </head>
        <body>
            <div class="markdown-preview"\(baseURLAttr)>
                <div id="mr-content">
                    \(renderResult.html)
                </div>
            </div>
            \(scriptTags)
        </body>
        </html>
        """
    }

    private static func preprocess(_ content: String) -> String {
        var result = content
        result = stripYAMLFrontMatter(result)

        var codeStore: [String] = []
        result = protectCodeRegions(result, store: &codeStore)

        result = preprocessBlockMath(result)
        result = preprocessInlineDoubleMath(result)
        result = preprocessInlineMath(result)
        result = preprocessFootnotes(result)
        result = preprocessHighlight(result)
        result = preprocessSuperscript(result)
        result = preprocessSubscript(result)
        result = EmojiService.replaceEmojiShortcodes(result)

        result = restoreCodeRegions(result, store: codeStore)

        return result
    }

    // MARK: - 代码区域保护

    /// 将围栏代码块和行内代码替换为占位符，避免正则误伤内部内容
    private static func protectCodeRegions(_ content: String, store: inout [String]) -> String {
        var result = content

        // 围栏代码块 ```...``` 或 ~~~...~~~
        let fencedPattern = "(?m)(^`{3,}|^~{3,})[^\\n]*\\n[\\s\\S]*?\\1[ \\t]*$"
        if let regex = try? NSRegularExpression(pattern: fencedPattern, options: []) {
            let nsRange = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: nsRange)
            // 从后向前替换，避免偏移问题
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let placeholder = "\u{0000}CODEBLOCK_\(store.count)\u{0000}"
                store.append(String(result[range]))
                result.replaceSubrange(range, with: placeholder)
            }
        }

        // 行内代码 `...`
        let inlinePattern = "(?<!`)(`+)(?!`)(.*?)(?<!`)(\\1)(?!`)"
        if let regex = try? NSRegularExpression(pattern: inlinePattern, options: [.dotMatchesLineSeparators]) {
            let nsRange = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: nsRange)
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let placeholder = "\u{0000}CODEINLINE_\(store.count)\u{0000}"
                store.append(String(result[range]))
                result.replaceSubrange(range, with: placeholder)
            }
        }

        return result
    }

    /// 将占位符还原为原始代码文本
    private static func restoreCodeRegions(_ content: String, store: [String]) -> String {
        var result = content
        for (index, original) in store.enumerated() {
            // 匹配 CODEBLOCK_ 和 CODEINLINE_ 两种占位符
            for prefix in ["CODEBLOCK_", "CODEINLINE_"] {
                let placeholder = "\u{0000}\(prefix)\(index)\u{0000}"
                result = result.replacingOccurrences(of: placeholder, with: original)
            }
        }
        return result
    }

    // MARK: - 数学公式预处理

    /// 将 $$...$$ 块级数学公式转换为 ```math 代码块格式，复用已有 KaTeX 渲染管线
    private static func preprocessBlockMath(_ content: String) -> String {
        // 仅匹配独占一行的 $$...$$（块级公式）
        // 行内的 $$...$$ 由 preprocessInlineDoubleMath 处理
        let pattern = #"(?m)^\s*\$\$([\s\S]+?)\$\$\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return content }
        let nsRange = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: nsRange)

        var result = content
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let contentRange = Range(match.range(at: 1), in: result) else { continue }
            let mathContent = String(result[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            // 确保 ```math 块前后有空行，避免相邻块级公式产生 ``````math 合并问题
            let replacement = "\n```math\n\(mathContent)\n```\n"
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// 将行内 $$...$$ 数学公式转换为 HTML span，由 JS KaTeX 渲染
    /// 处理不在行首的 $$...$$（即行内双美元符号公式），渲染为 displayMode 行内公式
    private static func preprocessInlineDoubleMath(_ content: String) -> String {
        // 匹配行内 $$...$$（行内双美元符号公式，允许 $$ 后有空格）
        let pattern = #"(?<!\$)\$\$(.+?)\$\$(?!\$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return content }
        let nsRange = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: nsRange)

        var result = content
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let contentRange = Range(match.range(at: 1), in: result) else { continue }
            let mathContent = String(result[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines).htmlEscaped
            // 使用 data-display="true" 标记为 display 模式
            let replacement = "<code class=\"language-math inline\" data-display=\"true\">\(mathContent)</code>"
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// 将 $...$ 行内数学公式转换为 HTML span，由 JS KaTeX 渲染
    /// 转换为 <code class="language-math inline"> 格式，与现有 KaTeX 管道兼容
    private static func preprocessInlineMath(_ content: String) -> String {
        // 匹配 $...$ 但不匹配 $$（已由块级处理）和 \$（转义美元符号）
        // 要求 $ 后不能为空格，$ 前不能为空格（避免匹配普通美元符号）
        let pattern = #"(?<!\$)\$(?!\s)(.+?)(?<!\s)\$(?!\$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return content }
        let nsRange = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: nsRange)

        var result = content
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let contentRange = Range(match.range(at: 1), in: result) else { continue }
            let mathContent = String(result[contentRange]).htmlEscaped
            let replacement = "<code class=\"language-math inline\">\(mathContent)</code>"
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    // MARK: - 脚注预处理

    /// 将脚注语法 [^n] 和 [^n]: 定义转换为 HTML
    /// Apple swift-markdown 不支持脚注，需预处理为原生 HTML
    private static func preprocessFootnotes(_ content: String) -> String {
        var result = content
        var footnotes: [(label: String, text: String)] = []

        // 1. 提取脚注定义 [^label]: text，并从内容中移除
        let defPattern = #"(?m)^\[\^([^\]]+)\]:\s+(.+)$"#
        if let regex = try? NSRegularExpression(pattern: defPattern, options: []) {
            let nsRange = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: nsRange)
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result),
                      let labelRange = Range(match.range(at: 1), in: result),
                      let textRange = Range(match.range(at: 2), in: result) else { continue }
                let label = String(result[labelRange])
                let text = String(result[textRange])
                footnotes.append((label: label, text: text))
                result.replaceSubrange(range, with: "")
            }
        }

        guard !footnotes.isEmpty else { return result }

        // 2. 替换行内脚注引用 [^label] → <sup> 链接
        let refPattern = #"\[\^([^\]]+)\]"#
        if let regex = try? NSRegularExpression(pattern: refPattern, options: []) {
            let nsRange = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: nsRange)
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result),
                      let labelRange = Range(match.range(at: 1), in: result) else { continue }
                let label = String(result[labelRange])
                let escapedLabel = label.htmlEscaped
                let replacement = "<sup class=\"footnote-ref\" id=\"fnref-\(escapedLabel)\"><a href=\"#fn-\(escapedLabel)\">\(escapedLabel)</a></sup>"
                result.replaceSubrange(range, with: replacement)
            }
        }

        // 3. 在文档末尾追加脚注列表
        result += "\n<section class=\"footnotes\">\n<ol>\n"
        for (_, fn) in footnotes.enumerated() {
            let escapedLabel = fn.label.htmlEscaped
            let escapedText = fn.text.htmlEscaped
            result += "<li id=\"fn-\(escapedLabel)\"><p>\(escapedText)&#160;<a href=\"#fnref-\(escapedLabel)\" class=\"footnote-backref\">&#8617;</a></p></li>\n"
        }
        result += "</ol>\n</section>\n"

        return result
    }

    // MARK: - 高亮/Mark 预处理

    /// 将 ==text== 转换为 <mark>text</mark>
    private static func preprocessHighlight(_ content: String) -> String {
        let pattern = #"==([^=]+)=="#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return content }
        let nsRange = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: nsRange)

        var result = content
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let textRange = Range(match.range(at: 1), in: result) else { continue }
            let text = String(result[textRange]).htmlEscaped
            let replacement = "<mark>\(text)</mark>"
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    // MARK: - 上标预处理

    /// 将 ^text^ 转换为 <sup>text</sup>
    /// 注意：不处理 ^ 开头的行（可能是列表标记）和代码块内的内容
    private static func preprocessSuperscript(_ content: String) -> String {
        // 匹配 ^非空内容^，要求内容不含空白行，且不是行首
        let pattern = #"(?<!\^)\^(?!\s)([^\s\^]+?)(?<!\s)\^(?!\^)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return content }
        let nsRange = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: nsRange)

        var result = content
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let textRange = Range(match.range(at: 1), in: result) else { continue }
            let text = String(result[textRange]).htmlEscaped
            let replacement = "<sup>\(text)</sup>"
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    // MARK: - 下标预处理

    /// 将 ~text~（单波浪号）转换为 <sub>text</sub>
    /// 注意：必须区分删除线 ~~text~~（双波浪号），仅处理单波浪号
    private static func preprocessSubscript(_ content: String) -> String {
        // 匹配单个 ~ 包裹的内容，前后不能是 ~（避免匹配 ~~删除线~~）
        let pattern = #"(?<!~)~(?!\s)([^\s~]+?)(?<!\s)~(?!~)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return content }
        let nsRange = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: nsRange)

        var result = content
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let textRange = Range(match.range(at: 1), in: result) else { continue }
            let text = String(result[textRange]).htmlEscaped
            let replacement = "<sub>\(text)</sub>"
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func stripYAMLFrontMatter(_ content: String) -> String {
        let pattern = #"^---\s*\n[\s\S]*?\n---\s*\n"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return content }
        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: "")
    }
}

private struct CustomHTMLFormatter: MarkupWalker {
    var result = ""
    var headings: [MarkdownHTMLService.HeadingInfo] = []
    private var headingCounter = 0
    private let baseURL: URL?

    private let inlineImages: Bool

    init(baseURL: URL? = nil, inlineImages: Bool = false) {
        self.baseURL = baseURL
        self.inlineImages = inlineImages
    }

    /// 将相对路径转换为 mr:// 绝对路径，使其通过 URLSchemeHandler 加载
    private func resolveRelativeURL(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        // 已经是绝对 URL 的不做转换
        if path.hasPrefix("http://") || path.hasPrefix("https://") ||
           path.hasPrefix("mr://") || path.hasPrefix("data:") ||
           path.hasPrefix("/") || path.hasPrefix("#") ||
           path.hasPrefix("mailto:") {
            return path
        }
        // 相对路径：基于 baseURL 转为 mr:// 绝对路径
        if let baseURL = baseURL {
            let absoluteURL = baseURL.appendingPathComponent(path)
            return "mr:///" + absoluteURL.path
        }
        return path
    }

    /// 将相对路径图片转为 base64 data URL，用于沙盒环境（如 Quick Look）下无法通过 scheme 加载本地文件的场景
    private func inlineImageData(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        // 已经是绝对 URL 或 data URL 的不做转换
        if path.hasPrefix("http://") || path.hasPrefix("https://") ||
           path.hasPrefix("data:") || path.hasPrefix("#") ||
           path.hasPrefix("mailto:") {
            return path
        }
        // 绝对路径或相对路径：尝试读取文件并转为 base64
        var fileURL: URL?
        if path.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: path)
        } else if let baseURL = baseURL {
            fileURL = baseURL.appendingPathComponent(path)
        }
        guard let fileURL else {
            MarkdownHTMLService.logger.warning("inlineImageData: no fileURL for path=\(path), baseURL=\(self.baseURL?.path ?? "nil")")
            return path
        }
        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        guard let data = try? Data(contentsOf: fileURL) else {
            MarkdownHTMLService.logger.warning("inlineImageData: failed to read file=\(fileURL.path), exists=\(fileExists)")
            return path
        }
        let mimeType = Self.mimeTypeForPathExtension(fileURL.pathExtension)
        let base64 = data.base64EncodedString()
        MarkdownHTMLService.logger.info("inlineImageData: success for \(path) -> data:\(mimeType);base64,... (\(data.count) bytes)")
        return "data:\(mimeType);base64,\(base64)"
    }

    private static func mimeTypeForPathExtension(_ pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "bmp": return "image/bmp"
        case "tiff", "tif": return "image/tiff"
        default: return "application/octet-stream"
        }
    }

    mutating func visitDocument(_ document: Markdown.Document) {
        for child in document.children {
            visit(child)
        }
    }

    mutating func visitHeading(_ heading: Heading) {
        headingCounter += 1
        let id = "heading-\(headingCounter)"
        let lineNumber = heading.range?.lowerBound.line ?? 0
        let title = heading.plainText

        headings.append(MarkdownHTMLService.HeadingInfo(
            id: id,
            level: heading.level,
            title: title,
            lineNumber: lineNumber
        ))

        result += "<h\(heading.level) id=\"\(id)\" data-line=\"\(lineNumber)\">"
        descendInto(heading)
        result += "</h\(heading.level)>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        let lineNumber = paragraph.range?.lowerBound.line ?? 0
        result += "<p data-line=\"\(lineNumber)\">"
        descendInto(paragraph)
        result += "</p>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let language = codeBlock.language ?? ""
        let languageClass = language.isEmpty ? "" : " class=\"language-\(language.htmlEscaped)\""
        let lineNumber = codeBlock.range?.lowerBound.line ?? 0
        result += "<pre data-line=\"\(lineNumber)\"><code\(languageClass)>\(codeBlock.code.htmlEscaped)</code></pre>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        let lineNumber = blockQuote.range?.lowerBound.line ?? 0
        result += "<blockquote data-line=\"\(lineNumber)\">\n"
        descendInto(blockQuote)
        result += "</blockquote>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        let lineNumber = unorderedList.range?.lowerBound.line ?? 0
        result += "<ul data-line=\"\(lineNumber)\">\n"
        descendInto(unorderedList)
        result += "</ul>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let lineNumber = orderedList.range?.lowerBound.line ?? 0
        result += "<ol data-line=\"\(lineNumber)\">\n"
        descendInto(orderedList)
        result += "</ol>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if let checkbox = listItem.checkbox {
            result += "<li class=\"task-list-item\">"
            result += "<input type=\"checkbox\" disabled=\"\""
            if checkbox == .checked {
                result += " checked=\"\""
            }
            result += " /> "
        } else {
            result += "<li>"
        }
        descendInto(listItem)
        result += "</li>\n"
    }

    mutating func visitTable(_ table: Table) {
        let lineNumber = table.range?.lowerBound.line ?? 0
        result += "<table data-line=\"\(lineNumber)\">\n<thead>\n<tr>\n"
        for cell in table.head.cells {
            let align = alignmentAttr(table.columnAlignments[cell.indexInParent])
            result += "<th\(align)>"
            descendInto(cell)
            result += "</th>\n"
        }
        result += "</tr>\n</thead>\n"
        let bodyRows = Array(table.body.rows)
        if !bodyRows.isEmpty {
            result += "<tbody>\n"
            for row in bodyRows {
                result += "<tr>\n"
                for cell in row.cells {
                    let align = alignmentAttr(table.columnAlignments[cell.indexInParent])
                    result += "<td\(align)>"
                    descendInto(cell)
                    result += "</td>\n"
                }
                result += "</tr>\n"
            }
            result += "</tbody>\n"
        }
        result += "</table>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        let lineNumber = thematicBreak.range?.lowerBound.line ?? 0
        result += "<hr data-line=\"\(lineNumber)\" />\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        result += html.rawHTML
        result += "\n"
    }

    mutating func visitText(_ text: Text) {
        result += text.string.htmlEscaped
    }

    mutating func visitStrong(_ strong: Strong) {
        result += "<strong>"
        descendInto(strong)
        result += "</strong>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        result += "<em>"
        descendInto(emphasis)
        result += "</em>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        result += "<del>"
        descendInto(strikethrough)
        result += "</del>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += "<code>\(inlineCode.code.htmlEscaped)</code>"
    }

    mutating func visitLink(_ link: Link) {
        let rawDestination = link.destination?.htmlEscaped ?? ""
        let destination = resolveRelativeURL(rawDestination)
        let title = link.title != nil ? " title=\"\(link.title!.htmlEscaped)\"" : ""
        result += "<a href=\"\(destination)\"\(title)>"
        descendInto(link)
        result += "</a>"
    }

    mutating func visitImage(_ image: Image) {
        let rawSource = image.source ?? ""
        let source: String
        if inlineImages {
            // inlineImageData 用原始未转义路径做文件解析，data URL 不需要 htmlEscape
            source = inlineImageData(rawSource)
        } else {
            source = resolveRelativeURL(rawSource.htmlEscaped)
        }
        let title = image.title != nil ? " title=\"\(image.title!.htmlEscaped)\"" : ""
        let alt = image.plainText.htmlEscaped
        result += "<img src=\"\(source)\" alt=\"\(alt)\"\(title) />"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        result += "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "<br />\n"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        result += inlineHTML.rawHTML
    }

    private func alignmentAttr(_ alignment: Table.ColumnAlignment?) -> String {
        switch alignment {
        case .left: return " align=\"left\""
        case .center: return " align=\"center\""
        case .right: return " align=\"right\""
        case nil: return ""
        }
    }
}

extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    var addingXMLAttributeEscapes: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

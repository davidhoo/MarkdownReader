import Foundation
import WebKit
import AppKit

// MARK: - 资源门禁验证工具
// 编译方法:
// swiftc -parse-as-library Sources/MarkdownReaderKit/Services/MarkdownResourceLocator.swift Sources/MarkdownReaderKit/Services/MarkdownURLSchemeHandler.swift scripts/verify-render-resources.swift -o scripts/.verify-render-resources-bin
// 用法: scripts/.verify-render-resources-bin <MarkdownReader.app 路径>
//
// 验证内容：
// 1. 静态清单门禁：调用生产环境 MarkdownResourceLocator，检查主应用与 QL 扩展中必需 CSS、JS、Prism、KaTeX、字体及 Mermaid。
// 2. 裁剪验证：确认 QL 扩展未打包冗余 Mermaid。
// 3. WebPage 运行时冒烟：通过真实 WebPage + 生产 MarkdownURLSchemeHandler(hostBundle: appBundle)，
//    验证 computed font、.markdown-preview computed padding、window.MR 入口、MR.replaceContent 正文替换、
//    真实 MR.scrollToSourceScrollAnchor 滚动回执，以及 MR.captureSourceScrollAnchor 锚点采集。

@main
struct VerifyRenderResources {
    static func main() async {
        _ = NSApplication.shared

        guard CommandLine.arguments.count > 1 else {
            fputs("❌ 缺少参数：请提供待验证的 .app 路径\n用法: verify-render-resources <path/to/MarkdownReader.app>\n", stderr)
            exit(1)
        }

        let appPath = CommandLine.arguments[1]
        let appURL = URL(fileURLWithPath: appPath).standardizedFileURL

        guard FileManager.default.fileExists(atPath: appURL.path) else {
            fputs("❌ 指定的 App 不存在: \(appURL.path)\n", stderr)
            exit(1)
        }

        guard let appBundle = Bundle(url: appURL) else {
            fputs("❌ 无法解析为 Bundle: \(appURL.path)\n", stderr)
            exit(1)
        }

        print("🔍 开始验证打包产物资源门禁: \(appURL.lastPathComponent)")

        // MARK: - 1. 主应用静态清单门禁（生产定位器规则）

        let mainRequiredResources = [
            "css/markdown.css",
            "css/scroll.css",
            "css/katex.min.css",
            "css/fonts/KaTeX_Main-Regular.woff2",
            "css/fonts/KaTeX_Math-Italic.woff2",
            "js/markdown-reader.js",
            "js/prism-core.min.js",
            "js/prism-autoloader.min.js",
            "js/prism-swift.min.js",
            "js/katex.min.js",
            "js/mermaid.min.js"
        ]

        print("📦 验证主应用必需资源清单（通过 MarkdownResourceLocator）...")
        var missingMain: [String] = []
        for res in mainRequiredResources {
            guard let url = MarkdownResourceLocator.resolveResourceURL(path: res, hostBundle: appBundle) else {
                missingMain.append(res)
                continue
            }
            guard let (data, _) = try? MarkdownResourceLocator.loadResourceData(at: url), !data.isEmpty else {
                missingMain.append("\(res) (0 bytes or unreadable)")
                continue
            }
        }

        if !missingMain.isEmpty {
            fputs("❌ 主应用缺失关键资源:\n", stderr)
            for item in missingMain {
                fputs("   - \(item)\n", stderr)
            }
            exit(1)
        }
        print("   ✅ 主应用 \(mainRequiredResources.count) 项关键资源均就绪且非空")

        // MARK: - 2. Quick Look Extension 静态清单门禁与裁剪验证

        let qlAppexURL = appURL.appendingPathComponent("Contents/PlugIns/MarkdownReaderQL.appex")
        guard FileManager.default.fileExists(atPath: qlAppexURL.path), let qlBundle = Bundle(url: qlAppexURL) else {
            fputs("❌ 缺少 Quick Look Extension 或无法解析为 Bundle: \(qlAppexURL.path)\n", stderr)
            exit(1)
        }
        do {
            print("📦 验证 Quick Look Extension 资源...")
            let qlRequiredResources = [
                "css/markdown.css",
                "css/scroll.css",
                "css/katex.min.css",
                "css/fonts/KaTeX_Main-Regular.woff2",
                "js/markdown-reader.js",
                "js/prism-core.min.js",
                "js/katex.min.js"
            ]
            var missingQL: [String] = []
            for res in qlRequiredResources {
                guard let url = MarkdownResourceLocator.resolveResourceURL(path: res, hostBundle: qlBundle) else {
                    missingQL.append(res)
                    continue
                }
                guard let (data, _) = try? MarkdownResourceLocator.loadResourceData(at: url), !data.isEmpty else {
                    missingQL.append("\(res) (0 bytes or unreadable)")
                    continue
                }
            }
            if !missingQL.isEmpty {
                fputs("❌ Quick Look Extension 缺失关键资源:\n", stderr)
                for item in missingQL {
                    fputs("   - \(item)\n", stderr)
                }
                exit(1)
            }
            print("   ✅ Quick Look Extension \(qlRequiredResources.count) 项必需资源就绪且非空")

            // 检查 Mermaid 是否已成功从 QL Extension 中裁剪
            let appexInternalBundle = qlAppexURL.appendingPathComponent("Contents/Resources/MarkdownReader_MarkdownReader.bundle")
            let internalMermaidPaths = [
                appexInternalBundle.appendingPathComponent("Contents/Resources/Resources/js/mermaid.min.js"),
                appexInternalBundle.appendingPathComponent("Contents/Resources/js/mermaid.min.js"),
                appexInternalBundle.appendingPathComponent("Resources/js/mermaid.min.js")
            ]
            for path in internalMermaidPaths {
                if FileManager.default.fileExists(atPath: path.path) {
                    fputs("❌ Quick Look Extension 未按预期裁剪 mermaid.min.js（应省 ~3.1MB）: \(path.path)\n", stderr)
                    exit(1)
                }
            }
            print("   ✅ Quick Look Extension 裁剪验证通过")
        }

        // MARK: - 3. WebPage 运行时真实冒烟验证

        print("🌐 执行真实 WebPage + MarkdownURLSchemeHandler 运行时冒烟验证...")

        let scheme = URLScheme("mr")!
        let handler = MarkdownURLSchemeHandler(baseURL: nil, hostBundle: appBundle)
        var config = WebPage.Configuration()
        config.urlSchemeHandlers[scheme] = handler
        let page = WebPage(configuration: config)

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>:root { --content-padding: 20px; }</style>
            <link rel="stylesheet" href="mr:///css/markdown.css">
            <link rel="stylesheet" href="mr:///css/scroll.css">
            <script src="mr:///js/markdown-reader.js"></script>
        </head>
        <body>
            <div class="markdown-preview" id="mr-content">
                <h1 id="title" data-source-start="1" data-source-end="1">Verification Document</h1>
                <p data-source-start="2" data-source-end="4">Verification paragraph line.</p>
            </div>
        </body>
        </html>
        """

        _ = page.load(html: html, baseURL: URL(string: "mr://localhost/")!)

        var smokeSuccess = false
        var failureReason: String?

        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))

            let js = """
            return (() => {
                if (typeof window.MR !== "object" || window.MR === null) {
                    return { ready: false, reason: "missing_mr" };
                }
                if (typeof window.MR.replaceContent !== "function") {
                    return { ready: false, reason: "missing_replaceContent" };
                }
                if (typeof window.MR.scrollToSourceScrollAnchor !== "function") {
                    return { ready: false, reason: "missing_scrollToSourceScrollAnchor" };
                }
                if (typeof window.MR.captureSourceScrollAnchor !== "function") {
                    return { ready: false, reason: "missing_captureSourceScrollAnchor" };
                }

                const bodyStyle = window.getComputedStyle(document.body);
                const bodyFont = bodyStyle.fontFamily || "";
                if (bodyFont.indexOf("-apple-system") === -1) {
                    return { ready: false, reason: "fallback_font: " + bodyFont };
                }

                const preview = document.querySelector('.markdown-preview');
                const pad = preview ? window.getComputedStyle(preview).paddingLeft : "";
                if (pad === "0px" || pad === "") {
                    return { ready: false, reason: "zero_padding: " + pad };
                }

                const replaceOk = window.MR.replaceContent('<p id="replaced">Replaced Paragraph</p>');
                if (replaceOk !== true) {
                    return { ready: false, reason: "replaceContent_failed" };
                }

                return { ready: true, bodyFont: bodyFont, pad: pad };
            })()
            """

            do {
                if let result = try await page.callJavaScript(js) as? [String: Any],
                   result["ready"] as? Bool == true {
                    // 验证滚动定位与回执
                    let scrollJS = "return await MR.scrollToSourceScrollAnchor(1, 0)"
                    let scrollReceipt = try await page.callJavaScript(scrollJS)
                    let scrollOk = (scrollReceipt as? Bool) ?? ((scrollReceipt as? Int) == 1)
                    guard scrollOk else {
                        failureReason = "MR.scrollToSourceScrollAnchor returned false"
                        break
                    }

                    // 验证锚点采集
                    let anchorJS = "return MR.captureSourceScrollAnchor()"
                    guard let anchorDict = try await page.callJavaScript(anchorJS) as? [String: Any],
                          let pos = anchorDict["sourcePosition"] as? Double, pos >= 1 else {
                        failureReason = "MR.captureSourceScrollAnchor failed to return valid anchor"
                        break
                    }

                    smokeSuccess = true
                    break
                }
            } catch {
                failureReason = "JavaScript execution error: \(error)"
            }
        }

        guard smokeSuccess else {
            fputs("❌ WebPage 冒烟测试未通过: \(failureReason ?? "超时未就绪")\n", stderr)
            exit(1)
        }

        print("   ✅ WebPage 冒烟验证通过（CSS 字体生效、20px 边距生效、MR 对象就绪、正文替换成功、滚动定位与锚点采集回执正常）")
        print("🎉 打包产物所有渲染资源门禁验证通过！")
        exit(0)
    }
}

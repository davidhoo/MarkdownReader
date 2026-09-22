import Foundation

// MARK: - 资源门禁验证工具
// 编译方法:
// swiftc -parse-as-library Sources/MarkdownReaderKit/Services/MarkdownResourceLocator.swift scripts/verify-render-resources.swift -o scripts/.verify-render-resources-bin
// 用法: scripts/.verify-render-resources-bin <MarkdownReader.app 路径>
//
// 验证内容：
// 1. 静态清单门禁：调用生产环境 MarkdownResourceLocator，检查主应用与 QL 扩展中必需 CSS、JS、Prism、KaTeX、字体及 Mermaid。
// 2. 裁剪验证：确认 QL 扩展未打包冗余 Mermaid。
// 3. 通过 open -n 启动待验收 .app 的自检入口，验证它实际链接的渲染代码。
//    此工具只检查资源清单及主程序回执，不编译另一份 WebPage/handler 替代主程序。

@main
struct VerifyRenderResources {
    static func main() async {
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

        // MARK: - 3. 启动待发布的实际主程序，而不是用验证器的代码渲染资源

        let argument = "--verify-packaged-render"
        // 旧程序没有自检入口，拒绝启动，避免它忽略参数后打开用户文档或修改偏好。
        guard let executableURL = appBundle.executableURL,
              let executable = try? Data(contentsOf: executableURL),
              executable.range(of: Data(argument.utf8)) != nil else {
            fputs("❌ 主程序缺少打包自检入口，可能混入了旧二进制\n", stderr)
            exit(1)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-packaged-verification-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fputs("❌ 无法创建自检回执目录: \(error)\n", stderr)
            exit(1)
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let reportURL = directory.appendingPathComponent("result.json")
        let nonce = UUID().uuidString
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-g", "-W", appURL.path, "--args", argument, reportURL.path, nonce]
        process.currentDirectoryURL = directory
        print("🌐 启动打包主程序执行渲染自检: \(appURL.path)")
        do {
            try process.run()
            for _ in 0..<300 {
                // LaunchServices 的 open 可能先退出；以主程序的原子回执为完成边界。
                if FileManager.default.fileExists(atPath: reportURL.path) { break }
                if !process.isRunning && process.terminationStatus != 0 {
                    throw VerificationError(message: "无法启动打包主程序（open: \(process.terminationStatus)）")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard FileManager.default.fileExists(atPath: reportURL.path) else {
                if process.isRunning { process.terminate() }
                throw VerificationError(message: "打包主程序自检超时")
            }
            guard let data = try? Data(contentsOf: reportURL),
                  let report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  report["schemaVersion"] as? Int == 1,
                  report["nonce"] as? String == nonce,
                  report["bundlePath"] as? String == appURL.resolvingSymlinksInPath().path else {
                throw VerificationError(message: "未收到当前打包主程序的有效自检回执")
            }
            guard report["success"] as? Bool == true else {
                throw VerificationError(message: report["error"] as? String ?? "渲染自检失败")
            }
            print("   ✅ 打包主程序自检通过: \(report["metrics"] ?? [:])")
        } catch {
            fputs("❌ \(error)\n", stderr)
            // exit 不运行 defer，显式清理失败回执目录。
            try? FileManager.default.removeItem(at: directory)
            exit(1)
        }
        print("🎉 打包产物资源清单与实际主程序渲染均通过验证")
    }

    private struct VerificationError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}

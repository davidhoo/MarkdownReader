import SwiftUI

/// 自检必须在 SwiftUI App 初始化之前分流，避免读写用户偏好、恢复文档或检查更新。
@main
enum MarkdownReaderEntryPoint {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first == PackagedRenderVerification.argument {
            guard CommandLine.arguments.count == 4 else { exit(64) }
            PackagedRenderVerification.run(
                reportURL: URL(fileURLWithPath: CommandLine.arguments[2]),
                nonce: CommandLine.arguments[3]
            )
        } else {
            MarkdownReaderApp.main()
        }
    }
}

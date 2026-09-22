import Foundation
import XCTest
@testable import MarkdownReaderKit

final class MarkdownResourceLocatorTests: TemporaryDirectoryTestCase {

    // MARK: - Fixture Helpers

    /// 构造带 Contents/Resources/Resources 的结构化 bundle（现代 SwiftPM .copy("Resources")）
    private func createStructuredAppBundle(named appName: String = "MarkdownReader.app") throws -> URL {
        let appURL = try makeDirectory(named: appName)
        _ = try makeDirectory(named: "\(appName)/Contents")
        _ = try makeDirectory(named: "\(appName)/Contents/Resources")
        _ = try makeDirectory(named: "\(appName)/Contents/Resources/MarkdownReader_MarkdownReader.bundle")
        let innerContents = try makeDirectory(named: "\(appName)/Contents/Resources/MarkdownReader_MarkdownReader.bundle/Contents")
        _ = try makeDirectory(named: "\(appName)/Contents/Resources/MarkdownReader_MarkdownReader.bundle/Contents/Resources")
        _ = try makeDirectory(named: "\(appName)/Contents/Resources/MarkdownReader_MarkdownReader.bundle/Contents/Resources/Resources")

        let cssDir = try makeDirectory(named: "\(appName)/Contents/Resources/MarkdownReader_MarkdownReader.bundle/Contents/Resources/Resources/css")
        let jsDir = try makeDirectory(named: "\(appName)/Contents/Resources/MarkdownReader_MarkdownReader.bundle/Contents/Resources/Resources/js")


        // 写入最小 Info.plist 以保证 Bundle(url:) 识别
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.markdownreader.resources</string>
            <key>CFBundleName</key>
            <string>MarkdownReader_MarkdownReader</string>
        </dict>
        </plist>
        """
        try makeFile(named: "Info.plist", in: innerContents, content: plistContent)
        try makeFile(named: "markdown.css", in: cssDir, content: "body { font-family: -apple-system; }")
        try makeFile(named: "scroll.css", in: cssDir, content: "/* scroll */")
        try makeFile(named: "markdown-reader.js", in: jsDir, content: "window.MR = {};")
        try makeFile(named: "prism-core.min.js", in: jsDir, content: "/* prism */")

        return appURL
    }

    /// 构造平铺旧结构 bundle
    private func createFlatAppBundle(named appName: String = "MarkdownReaderFlat.app") throws -> URL {
        let appURL = try makeDirectory(named: appName)
        _ = try makeDirectory(named: "\(appName)/Contents/Resources")
        _ = try makeDirectory(named: "\(appName)/Contents/Resources/MarkdownReader_MarkdownReader.bundle")
        _ = try makeDirectory(named: "\(appName)/Contents/Resources/MarkdownReader_MarkdownReader.bundle/Resources")

        let cssDir = try makeDirectory(named: "\(appName)/Contents/Resources/MarkdownReader_MarkdownReader.bundle/Resources/css")
        let jsDir = try makeDirectory(named: "\(appName)/Contents/Resources/MarkdownReader_MarkdownReader.bundle/Resources/js")

        try makeFile(named: "markdown.css", in: cssDir, content: "body { font-family: -apple-system; }")
        try makeFile(named: "markdown-reader.js", in: jsDir, content: "window.MR = {};")

        return appURL
    }

    /// 构造 Quick Look 扩展目录结构（内嵌在主 App 的 Contents/PlugIns/ 中）
    private func createQuickLookAppex(inApp appURL: URL) throws -> URL {
        let appexURL = appURL.appendingPathComponent("Contents/PlugIns/MarkdownReaderQL.appex")
        let qlResources = appexURL.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: qlResources, withIntermediateDirectories: true)

        let qlBundle = qlResources.appendingPathComponent("MarkdownReader_MarkdownReader.bundle")
        let innerContents = qlBundle.appendingPathComponent("Contents")
        let innerResources = innerContents.appendingPathComponent("Resources")
        let copiedResources = innerResources.appendingPathComponent("Resources")
        let cssDir = copiedResources.appendingPathComponent("css")
        try FileManager.default.createDirectory(at: cssDir, withIntermediateDirectories: true)

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.markdownreader.qlresources</string>
        </dict>
        </plist>
        """
        try plistContent.write(to: innerContents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try "body { font-family: -apple-system; }".write(to: cssDir.appendingPathComponent("markdown.css"), atomically: true, encoding: .utf8)

        return appexURL
    }

    // MARK: - 测试用例

    func testResolveStructuredBundleResources() throws {
        let appURL = try createStructuredAppBundle()
        guard let hostBundle = Bundle(url: appURL) else {
            XCTFail("无法创建 host bundle")
            return
        }

        let cssURL = MarkdownResourceLocator.resolveResourceURL(path: "css/markdown.css", hostBundle: hostBundle)
        XCTAssertNotNil(cssURL, "结构化 bundle 必须能解析 css/markdown.css")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cssURL?.path ?? ""))

        let jsURL = MarkdownResourceLocator.resolveResourceURL(path: "js/markdown-reader.js", hostBundle: hostBundle)
        XCTAssertNotNil(jsURL, "结构化 bundle 必须能解析 js/markdown-reader.js")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsURL?.path ?? ""))
    }

    func testResolveFlatBundleResources() throws {
        let appURL = try createFlatAppBundle()
        guard let hostBundle = Bundle(url: appURL) else {
            XCTFail("无法创建 host bundle")
            return
        }

        let cssURL = MarkdownResourceLocator.resolveResourceURL(path: "css/markdown.css", hostBundle: hostBundle)
        XCTAssertNotNil(cssURL, "平铺结构 bundle 必须能解析 css/markdown.css")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cssURL?.path ?? ""))
    }

    func testResolvePathsWithSpacesAndChineseCharacters() throws {
        let appURL = try createStructuredAppBundle(named: "测试 应用 with space.app")
        guard let hostBundle = Bundle(url: appURL) else {
            XCTFail("无法创建带空格和中文路径的 host bundle")
            return
        }

        let cssURL = MarkdownResourceLocator.resolveResourceURL(path: "css/markdown.css", hostBundle: hostBundle)
        XCTAssertNotNil(cssURL, "路径包含空格和中文时必须能正确解析")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cssURL?.path ?? ""))
    }

    func testQuickLookExtensionResourceResolution() throws {
        let appURL = try createStructuredAppBundle()
        let appexURL = try createQuickLookAppex(inApp: appURL)
        guard let qlBundle = Bundle(url: appexURL) else {
            XCTFail("无法创建 QL bundle")
            return
        }

        let cssURL = MarkdownResourceLocator.resolveResourceURL(path: "css/markdown.css", hostBundle: qlBundle)
        XCTAssertNotNil(cssURL, "QL 扩展必须能解析自己 bundle 里的 css/markdown.css")
        XCTAssertTrue(cssURL?.path.contains("MarkdownReaderQL.appex") == true, "扩展不能改读主应用里的同名资源")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cssURL?.path ?? ""))
    }

    func testLoadResourceDataValidatesNonEmpty() throws {
        let appURL = try createStructuredAppBundle()
        guard let hostBundle = Bundle(url: appURL),
              let cssURL = MarkdownResourceLocator.resolveResourceURL(path: "css/markdown.css", hostBundle: hostBundle) else {
            XCTFail("未定位到测试资源")
            return
        }

        let result = try MarkdownResourceLocator.loadResourceData(at: cssURL)
        XCTAssertFalse(result.data.isEmpty, "有效资源内容不得为空")
        XCTAssertEqual(result.mimeType, "text/css", "CSS MIME 类型必须为 text/css")
    }

    func testLoadResourceDataRejectsEmptyCSSOrJS() throws {
        let emptyFileURL = try makeFile(named: "empty.css", content: "")
        XCTAssertThrowsError(try MarkdownResourceLocator.loadResourceData(at: emptyFileURL)) { error in
            XCTAssertTrue(error is CocoaError || (error as NSError).domain == NSCocoaErrorDomain)
        }
    }

    func testMissingResourceReturnsNil() throws {
        let appURL = try createStructuredAppBundle()
        guard let hostBundle = Bundle(url: appURL) else {
            XCTFail("无法创建 host bundle")
            return
        }

        let missingURL = MarkdownResourceLocator.resolveResourceURL(path: "css/nonexistent.css", hostBundle: hostBundle)
        XCTAssertNil(missingURL, "不存在的资源必须返回 nil")
    }

    func testMimeTypeResolution() {
        XCTAssertEqual(MarkdownResourceLocator.mimeType(for: "css"), "text/css")
        XCTAssertEqual(MarkdownResourceLocator.mimeType(for: "js"), "application/javascript")
        XCTAssertEqual(MarkdownResourceLocator.mimeType(for: "woff2"), "font/woff2")
        XCTAssertEqual(MarkdownResourceLocator.mimeType(for: "woff"), "font/woff")
        XCTAssertEqual(MarkdownResourceLocator.mimeType(for: "ttf"), "font/ttf")
        XCTAssertEqual(MarkdownResourceLocator.mimeType(for: "svg"), "image/svg+xml")
        XCTAssertEqual(MarkdownResourceLocator.mimeType(for: "png"), "image/png")
        XCTAssertEqual(MarkdownResourceLocator.mimeType(for: "json"), "application/json")
        XCTAssertEqual(MarkdownResourceLocator.mimeType(for: "unknown"), "application/octet-stream")
    }

    func testSchemeHandlerServesResourceWith200AndNonEmptyData() async throws {
        let appURL = try createStructuredAppBundle()
        guard let hostBundle = Bundle(url: appURL) else {
            XCTFail("无法创建 host bundle")
            return
        }

        let handler = MarkdownURLSchemeHandler(baseURL: nil, hostBundle: hostBundle)
        let request = URLRequest(url: URL(string: "mr:///css/markdown.css")!)
        var receivedResponse: HTTPURLResponse?
        var receivedData = Data()

        for try await result in handler.reply(for: request) {
            switch result {
            case .response(let resp):
                receivedResponse = resp as? HTTPURLResponse
            case .data(let data):
                receivedData.append(data)
            @unknown default:
                break
            }
        }

        XCTAssertEqual(receivedResponse?.statusCode, 200)
        XCTAssertEqual(receivedResponse?.value(forHTTPHeaderField: "Content-Type"), "text/css")
        XCTAssertFalse(receivedData.isEmpty)
    }

    func testSchemeHandlerServes404ForMissingResource() async throws {
        let appURL = try createStructuredAppBundle()
        guard let hostBundle = Bundle(url: appURL) else {
            XCTFail("无法创建 host bundle")
            return
        }

        let handler = MarkdownURLSchemeHandler(baseURL: nil, hostBundle: hostBundle)
        let request = URLRequest(url: URL(string: "mr:///css/missing.css")!)
        var receivedResponse: HTTPURLResponse?

        for try await result in handler.reply(for: request) {
            switch result {
            case .response(let resp):
                receivedResponse = resp as? HTTPURLResponse
            default:
                break
            }
        }

        XCTAssertEqual(receivedResponse?.statusCode, 404)
    }

    func testAppExtensionDoesNotReadHostAppResources() throws {
        let appURL = try createStructuredAppBundle()
        let appexURL = appURL.appendingPathComponent("Contents/PlugIns/MarkdownReaderQL.appex")
        try FileManager.default.createDirectory(at: appexURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.markdownreader.ql</string>
        </dict>
        </plist>
        """
        try plistContent.write(to: appexURL.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)

        guard let qlBundle = Bundle(url: appexURL) else {
            XCTFail("无法创建 QL bundle")
            return
        }

        let cssURL = MarkdownResourceLocator.resolveResourceURL(path: "css/markdown.css", hostBundle: qlBundle)
        XCTAssertNil(cssURL, "扩展没有自己的资源时，不能借用主应用里的同名文件")
    }

    func testExplicitCustomSearchPathsDoesNotFallbackToBundle() throws {
        let appURL = try createStructuredAppBundle()
        guard let hostBundle = Bundle(url: appURL) else {
            XCTFail("无法创建 host bundle")
            return
        }

        let emptyCustomDir = try makeDirectory(named: "empty_custom")
        // 传入了自定义搜索目录，遵守 v2.4.5 语义不再回退 Bundle 默认目录
        let resolved = MarkdownResourceLocator.resolveResourceURL(
            path: "css/markdown.css",
            resourceSearchPaths: [emptyCustomDir],
            hostBundle: hostBundle
        )
        XCTAssertNil(resolved, "显式传入自定义搜索目录时不得回退搜 bundle")
    }

    func testRelativeAndAbsoluteLocalResources() throws {
        let baseDir = try makeDirectory(named: "doc_base")
        let relativeImage = try makeFile(named: "image.png", in: baseDir, content: "fake-png-data")

        // 1. 相对路径（通过 baseURL 找到）
        let resolvedRelative = MarkdownResourceLocator.resolveResourceURL(
            path: "image.png",
            baseURL: baseDir
        )
        XCTAssertEqual(resolvedRelative?.standardizedFileURL.path, relativeImage.standardizedFileURL.path)

        // 2. 绝对路径（以 "/" 或直接存在的文件路径）
        let resolvedAbsolute = MarkdownResourceLocator.resolveResourceURL(
            path: relativeImage.path.hasPrefix("/") ? String(relativeImage.path.dropFirst()) : relativeImage.path
        )
        XCTAssertEqual(resolvedAbsolute?.standardizedFileURL.path, relativeImage.standardizedFileURL.path)
    }
}


import Foundation
import WebKit
import OSLog

public struct MarkdownURLSchemeHandler: URLSchemeHandler {
    private static let logger = Logger(subsystem: "com.markdownreader.app", category: "MarkdownURLSchemeHandler")
    private let baseURL: URL?
    private let resourceSearchPaths: [URL]?
    private let hostBundle: Bundle

    public init(baseURL: URL?, resourceSearchPaths: [URL]? = nil, hostBundle: Bundle = .main) {
        self.baseURL = baseURL
        self.resourceSearchPaths = resourceSearchPaths
        self.hostBundle = hostBundle
    }

    public func reply(for request: URLRequest) -> some AsyncSequence<URLSchemeTaskResult, any Error> {
        let capturedBaseURL = baseURL
        let capturedResourceSearchPaths = resourceSearchPaths
        let capturedHostBundle = hostBundle
        return AsyncThrowingStream { continuation in
            let url = request.url
            let scheme = url?.scheme

            guard scheme == "mr" else {
                continuation.finish()
                return
            }

            guard var path = url?.path else {
                continuation.finish()
                return
            }

            if path.hasPrefix("/") {
                path = String(path.dropFirst())
            }

            let resourceURL = MarkdownResourceLocator.resolveResourceURL(
                path: path,
                baseURL: capturedBaseURL,
                resourceSearchPaths: capturedResourceSearchPaths,
                hostBundle: capturedHostBundle
            )

            guard let resourceURL, FileManager.default.fileExists(atPath: resourceURL.path) else {
                Self.logger.error("Resource 404 not found: \(path, privacy: .public)")
                let response = HTTPURLResponse(
                    url: url!,
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
                continuation.yield(.response(response))
                continuation.yield(.data(Data()))
                continuation.finish()
                return
            }

            do {
                let (data, mimeType) = try MarkdownResourceLocator.loadResourceData(at: resourceURL)
                let response = HTTPURLResponse(
                    url: url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": mimeType]
                )!
                continuation.yield(.response(response))
                continuation.yield(.data(data))
                continuation.finish()
            } catch {
                Self.logger.error("Failed to read resource at \(resourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continuation.finish(throwing: error)
            }
        }
    }

    public static func resolveResourceURL(
        path: String,
        baseURL: URL? = nil,
        resourceSearchPaths: [URL]? = nil,
        hostBundle: Bundle = .main
    ) -> URL? {
        MarkdownResourceLocator.resolveResourceURL(
            path: path,
            baseURL: baseURL,
            resourceSearchPaths: resourceSearchPaths,
            hostBundle: hostBundle
        )
    }

    public static func mimeType(for pathExtension: String) -> String {
        MarkdownResourceLocator.mimeType(for: pathExtension)
    }
}

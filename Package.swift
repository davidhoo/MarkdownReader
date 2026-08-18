// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MarkdownReader",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "MarkdownReader",
            targets: ["MarkdownReader"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-markdown.git",
            from: "0.5.0"
        )
    ],
    targets: [
        // Shared library — rendering logic, theme, localization
        .target(
            name: "MarkdownReaderKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "Sources/MarkdownReaderKit"
        ),
        // Main application
        .executableTarget(
            name: "MarkdownReader",
            dependencies: [
                "MarkdownReaderKit",
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "Sources/MarkdownReader",
            resources: [
                .process("Assets.xcassets"),
                .copy("Resources")
            ]
        ),
        // Quick Look Preview Extension
        // Built as a regular target (not executable) — the executable entry point
        // (NSExtensionMain) is provided by a C wrapper in build-app.sh at link time.
        // SPM's executableTarget always generates _main, which is wrong for App Extensions.
        .target(
            name: "MarkdownReaderQL",
            dependencies: [
                "MarkdownReaderKit"
            ],
            path: "Sources/MarkdownReaderQL"
        ),
        // Multi-window routing & ownership logic — pure-logic unit tests
        .testTarget(
            name: "MarkdownReaderTests",
            dependencies: ["MarkdownReader", "MarkdownReaderKit"],
            path: "Tests/MarkdownReaderTests"
        )
    ]
)

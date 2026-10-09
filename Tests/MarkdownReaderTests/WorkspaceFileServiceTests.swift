import XCTest
@testable import MarkdownReader

/// 工作区文件读写服务测试（方案 3.3）。
///
/// 覆盖：round-trip、扩展名自动补齐、缺失文件、损坏 JSON、高版本格式、空工作区。
@MainActor
final class WorkspaceFileServiceTests: TemporaryDirectoryTestCase {

    private func makeSampleDocument() -> WorkspaceDocument {
        WorkspaceDocument(
            folders: ["/tmp/docs", "/tmp/notes"],
            expandedDirs: ["/tmp/docs/sub"],
            selectedFile: "/tmp/docs/readme.md"
        )
    }

    // MARK: - round-trip

    func testSaveAndLoadRoundTrip() throws {
        let target = temporaryDirectory.appendingPathComponent("ws.mdworkspace")
        let document = makeSampleDocument()

        let written = try WorkspaceFileService.save(document, to: target)
        XCTAssertEqual(written, target)
        let loaded = try WorkspaceFileService.load(from: target)

        XCTAssertEqual(loaded, document)
    }

    func testSaveAppendsExtensionWhenMissing() throws {
        let target = temporaryDirectory.appendingPathComponent("ws")

        let written = try WorkspaceFileService.save(makeSampleDocument(), to: target)

        XCTAssertEqual(written.pathExtension, WorkspaceDocument.fileExtension)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
    }

    func testSavedFileIsHumanReadableJSON() throws {
        let target = temporaryDirectory.appendingPathComponent("ws.mdworkspace")
        try WorkspaceFileService.save(makeSampleDocument(), to: target)

        let text = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(text.contains("\"folders\""))
        XCTAssertTrue(text.contains("/tmp/docs"))
    }

    // MARK: - 错误路径

    func testLoadMissingFileThrowsUnreadable() {
        let missing = temporaryDirectory.appendingPathComponent("nope.mdworkspace")

        XCTAssertThrowsError(try WorkspaceFileService.load(from: missing)) { error in
            XCTAssertEqual(error as? WorkspaceFileService.WorkspaceFileError, .unreadable(missing))
        }
    }

    func testLoadCorruptedJSONThrowsDecodeFailed() throws {
        let target = try makeFile(named: "bad.mdworkspace", content: "not-json{{{")

        XCTAssertThrowsError(try WorkspaceFileService.load(from: target)) { error in
            XCTAssertEqual(error as? WorkspaceFileService.WorkspaceFileError, .decodeFailed(target))
        }
    }

    func testLoadFutureVersionThrowsUnsupported() throws {
        let target = temporaryDirectory.appendingPathComponent("future.mdworkspace")
        var document = makeSampleDocument()
        document.version = WorkspaceDocument.currentVersion + 1
        let data = try JSONEncoder().encode(document)
        try data.write(to: target)

        XCTAssertThrowsError(try WorkspaceFileService.load(from: target)) { error in
            XCTAssertEqual(
                error as? WorkspaceFileService.WorkspaceFileError,
                .unsupportedVersion(WorkspaceDocument.currentVersion + 1)
            )
        }
    }

    func testLoadEmptyFoldersThrowsEmptyWorkspace() throws {
        let target = temporaryDirectory.appendingPathComponent("empty.mdworkspace")
        let document = WorkspaceDocument(folders: [])
        let data = try JSONEncoder().encode(document)
        try data.write(to: target)

        XCTAssertThrowsError(try WorkspaceFileService.load(from: target)) { error in
            XCTAssertEqual(error as? WorkspaceFileService.WorkspaceFileError, .emptyWorkspace)
        }
    }

    // MARK: - makeDocument

    func testMakeDocumentSerializesCurrentState() {
        let folderA = URL(fileURLWithPath: "/tmp/a")
        let folderB = URL(fileURLWithPath: "/tmp/b")
        let expanded = URL(fileURLWithPath: "/tmp/a/sub")
        let selected = URL(fileURLWithPath: "/tmp/a/readme.md")

        let document = WorkspaceFileService.makeDocument(
            folders: [folderA, folderB],
            expandedDirs: [expanded],
            selectedFile: selected
        )

        XCTAssertEqual(document.folders, ["/tmp/a", "/tmp/b"])
        XCTAssertEqual(document.expandedDirs, ["/tmp/a/sub"])
        XCTAssertEqual(document.selectedFile, "/tmp/a/readme.md")
        XCTAssertEqual(document.version, WorkspaceDocument.currentVersion)
    }

    func testWorkspaceFileDetectionByExtension() {
        XCTAssertTrue(WorkspaceDocument.isWorkspaceFile(URL(fileURLWithPath: "/x/y.mdworkspace")))
        XCTAssertTrue(WorkspaceDocument.isWorkspaceFile(URL(fileURLWithPath: "/x/y.MDWORKSPACE")))
        XCTAssertFalse(WorkspaceDocument.isWorkspaceFile(URL(fileURLWithPath: "/x/y.md")))
        XCTAssertFalse(WorkspaceDocument.isWorkspaceFile(URL(fileURLWithPath: "/x/y.json")))
    }
}

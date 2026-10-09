import XCTest
@testable import MarkdownReader

/// 目录符号链接应作为文件夹浏览，同时不能被链接环或无权限目标拖垮整棵树。
@MainActor
final class DirectorySymlinkScanTests: TemporaryDirectoryTestCase {

    private let fileService = FileService()

    func testDirectorySymlinkListsTargetMarkdownUnderLinkPath() async throws {
        let root = try makeDirectory(named: "root")
        let target = try makeDirectory(named: "target")
        try makeFile(named: "note.md", in: target, content: "# hi")
        try makeFile(named: "plain.txt", in: root, content: "text")
        let link = root.appendingPathComponent("docs")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let nodes = try await fileService.scanDirectory(root)
        let docs = try child(nodes, named: "docs")

        XCTAssertTrue(docs.isDirectory)
        XCTAssertEqual(docs.path.standardizedFileURL.path, link.standardizedFileURL.path)
        let note = try child(docs.children ?? [], named: "note.md")
        XCTAssertFalse(note.isDirectory)
        XCTAssertTrue(note.isMarkdown)
        XCTAssertEqual(note.path.standardizedFileURL.path, link.appendingPathComponent("note.md").path)
        XCTAssertTrue(fileService.directoryContainsMarkdown(root))
    }

    func testRelativeDirectorySymlinkListsTargetContents() async throws {
        let root = try makeDirectory(named: "root")
        let target = try makeDirectory(named: "target")
        try makeFile(named: "note.md", in: target, content: "# hi")
        let link = root.appendingPathComponent("docs")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../target")

        let nodes = try await fileService.scanDirectory(root)
        let docs = try child(nodes, named: "docs")
        XCTAssertTrue(docs.isDirectory)
        XCTAssertEqual(docs.children?.map(\.name), ["note.md"])
    }

    func testSymlinkToFileStaysAFile() async throws {
        let root = try makeDirectory(named: "root")
        let note = try makeFile(named: "note.md", in: root, content: "# hi")
        let alias = root.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: note)

        let nodes = try await fileService.scanDirectory(root)
        let node = try child(nodes, named: "alias.md")
        XCTAssertFalse(node.isDirectory)
        XCTAssertTrue(node.isMarkdown)
        XCTAssertNil(node.children)
    }

    func testBrokenSymlinkStaysAFile() async throws {
        let root = try makeDirectory(named: "root")
        let missing = root.appendingPathComponent("missing")
        try FileManager.default.createSymbolicLink(atPath: missing.path, withDestinationPath: "no-such-dir")

        let nodes = try await fileService.scanDirectory(root)
        let node = try child(nodes, named: "missing")
        XCTAssertFalse(node.isDirectory)
        XCTAssertFalse(fileService.directoryContainsMarkdown(root))
    }

    func testSymlinkBackToAncestorDoesNotRecurse() async throws {
        let root = try makeDirectory(named: "root")
        try makeFile(named: "note.md", in: root, content: "# hi")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop"),
            withDestinationURL: root
        )

        let nodes = try await fileService.scanDirectory(root)
        let loop = try child(nodes, named: "loop")
        XCTAssertTrue(loop.isDirectory)
        XCTAssertEqual(loop.children, [])
        XCTAssertNotNil(nodes.first { $0.name == "note.md" })
    }

    func testPrivatePrefixAliasOfRootIsTreatedAsCycle() async throws {
        let root = try makeDirectory(named: "root")
        try makeFile(named: "note.md", in: root, content: "# hi")
        let destination = root.path.hasPrefix("/private/") ? root.path : "/private" + root.path
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("via-private").path,
            withDestinationPath: destination
        )

        let nodes = try await fileService.scanDirectory(root)
        let link = try child(nodes, named: "via-private")
        XCTAssertTrue(link.isDirectory)
        XCTAssertEqual(link.children, [])
    }

    func testMutualDirectorySymlinkStillShowsTargetFile() async throws {
        let root = try makeDirectory(named: "root")
        let a = try makeNestedDirectory(named: "a", in: root)
        let b = try makeNestedDirectory(named: "b", in: root)
        try makeFile(named: "note.md", in: b, content: "# hi")
        try FileManager.default.createSymbolicLink(at: a.appendingPathComponent("to-b"), withDestinationURL: b)
        try FileManager.default.createSymbolicLink(at: b.appendingPathComponent("to-a"), withDestinationURL: a)

        let nodes = try await fileService.scanDirectory(root)
        let directoryA = try child(nodes, named: "a")
        let toB = try child(directoryA.children ?? [], named: "to-b")
        XCTAssertTrue(toB.isDirectory)
        XCTAssertNotNil(toB.children?.first { $0.name == "note.md" })

        let directoryB = try child(nodes, named: "b")
        let toA = try child(directoryB.children ?? [], named: "to-a")
        XCTAssertTrue(toA.isDirectory)
        let nested = try child(toA.children ?? [], named: "to-b")
        XCTAssertTrue(nested.isDirectory)
        XCTAssertEqual(nested.children, [])
    }

    func testUnreadableDirectorySymlinkDoesNotFailParentScan() async throws {
        let root = try makeDirectory(named: "root")
        try makeFile(named: "visible.md", in: root, content: "# visible")
        let locked = try makeDirectory(named: "locked-target")
        try makeFile(named: "secret.md", in: locked, content: "# secret")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("locked"),
            withDestinationURL: locked
        )

        let nodes = try await fileService.scanDirectory(root)
        XCTAssertNotNil(nodes.first { $0.name == "visible.md" })
        let lockedNode = try child(nodes, named: "locked")
        XCTAssertTrue(lockedNode.isDirectory)
        XCTAssertEqual(lockedNode.children, [])
    }

    func testHiddenDirectorySymlinkFollowsHiddenFileSetting() async throws {
        let root = try makeDirectory(named: "root")
        let target = try makeDirectory(named: "hidden-target")
        try makeFile(named: "secret.md", in: target, content: "# secret")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".docs"),
            withDestinationURL: target
        )

        let hidden = try await fileService.scanDirectory(root, showHiddenFiles: false)
        XCTAssertNil(hidden.first { $0.name == ".docs" })
        XCTAssertFalse(fileService.directoryContainsMarkdown(root, showHiddenFiles: false))

        let shown = try await fileService.scanDirectory(root, showHiddenFiles: true)
        let docs = try child(shown, named: ".docs")
        XCTAssertTrue(docs.isDirectory)
        XCTAssertEqual(docs.children?.map(\.name), ["secret.md"])
        XCTAssertTrue(fileService.directoryContainsMarkdown(root, showHiddenFiles: true))
    }

    func testNonMarkdownFilterStillKeepsDirectorySymlink() async throws {
        let root = try makeDirectory(named: "root")
        let target = try makeDirectory(named: "target")
        try makeFile(named: "note.md", in: target, content: "# hi")
        try makeFile(named: "plain.dat", in: root, content: "text")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("docs"), withDestinationURL: target)

        let nodes = try await fileService.scanDirectory(root, showNonMarkdownFiles: false)
        XCTAssertNil(nodes.first { $0.name == "plain.dat" })
        let docs = try child(nodes, named: "docs")
        XCTAssertTrue(docs.isDirectory)
        XCTAssertEqual(docs.children?.map(\.name), ["note.md"])
    }

    private func child(_ nodes: [FileNode], named name: String, file: StaticString = #filePath, line: UInt = #line) throws -> FileNode {
        try XCTUnwrap(nodes.first { $0.name == name }, "缺少节点 \(name)", file: file, line: line)
    }

    private func makeNestedDirectory(named name: String, in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

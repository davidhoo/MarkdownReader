import XCTest
@testable import MarkdownReader

@MainActor
final class RecentItemsTests: TemporaryDirectoryTestCase {

    private let defaultsSuiteName = "com.markdownreader.tests.recentItems-\(UUID().uuidString)"

    final class SystemRecentRecorder {
        var notedURLs: [URL] = []
        var clearCount = 0
    }

    private func makeSettings() -> (settings: SettingsModel, recorder: SystemRecentRecorder) {
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        let recorder = SystemRecentRecorder()
        let settings = SettingsModel(
            defaults: defaults,
            noteRecentDocument: { recorder.notedURLs.append($0) },
            clearSystemRecentDocuments: { recorder.clearCount += 1 }
        )
        return (settings, recorder)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        super.tearDown()
    }

    func testAddRecentItemDeduplicatesStandardizedURLsAndNotifiesSystem() throws {
        let directory = try makeDirectory(named: "docs")
        let (settings, recorder) = makeSettings()

        settings.addRecentItem(url: URL(fileURLWithPath: directory.path + "/"), isDirectory: true)
        settings.addRecentItem(url: directory, isDirectory: true)

        XCTAssertEqual(settings.recentItems.count, 1)
        XCTAssertEqual(settings.recentItems.first?.url.path, directory.standardizedFileURL.path)
        XCTAssertEqual(recorder.notedURLs.map(\.path), [directory.standardizedFileURL.path])
    }

    func testAddRecentItemRejectsMissingPathAndMismatchedKind() throws {
        let file = try makeFile(named: "note.md", content: "# Note")
        let (settings, recorder) = makeSettings()

        settings.addRecentItem(url: temporaryDirectory.appendingPathComponent("missing.md"), isDirectory: false)
        settings.addRecentItem(url: file, isDirectory: true)

        XCTAssertTrue(settings.recentItems.isEmpty)
        XCTAssertTrue(recorder.notedURLs.isEmpty)
    }

    func testRecentItemsKeepOnlyLatestTenEntries() throws {
        let (settings, _) = makeSettings()
        var urls: [URL] = []

        for index in 0..<11 {
            let url = try makeFile(named: "note-\(index).md", content: "# \(index)")
            urls.append(url)
            settings.addRecentItem(url: url, isDirectory: false)
        }

        XCTAssertEqual(settings.recentItems.map(\.url), Array(urls.reversed().prefix(10)))
    }

    func testClearRecentItemsAlsoClearsSystemRecents() throws {
        let file = try makeFile(named: "note.md", content: "# Note")
        let (settings, recorder) = makeSettings()
        settings.addRecentItem(url: file, isDirectory: false)

        settings.clearRecentItems()

        XCTAssertTrue(settings.recentItems.isEmpty)
        XCTAssertEqual(recorder.clearCount, 1)
    }

    func testRecentItemsPersistInInjectedDefaults() throws {
        let file = try makeFile(named: "note.md", content: "# Note")
        let (settings, _) = makeSettings()
        settings.addRecentItem(url: file, isDirectory: false)

        let restored = SettingsModel(
            defaults: UserDefaults(suiteName: defaultsSuiteName)!,
            noteRecentDocument: { _ in },
            clearSystemRecentDocuments: {}
        )

        XCTAssertEqual(restored.recentItems.map(\.url), [file.standardizedFileURL])
    }

    func testRecentItemEqualityIgnoresTrailingPathSeparator() {
        let directory = temporaryDirectory.appendingPathComponent("docs")
        let withSeparator = RecentItem(url: URL(fileURLWithPath: directory.path + "/"), isDirectory: true)
        let withoutSeparator = RecentItem(url: directory, isDirectory: true)

        XCTAssertEqual(withSeparator, withoutSeparator)
    }

    func testOpenFileRecordsRecentOnlyAfterSuccessfulLoad() async throws {
        let file = try makeFile(named: "note.md", content: "# Note")
        let (settings, _) = makeSettings()
        let session = WindowSession(id: WindowID(), settings: settings)

        await session.openFile(file)

        XCTAssertEqual(settings.recentItems.map(\.url), [file.standardizedFileURL])
        XCTAssertEqual(session.documentViewModel.currentFileURL?.standardizedFileURL, file.standardizedFileURL)
    }

    func testOpenUnsupportedFileDoesNotRecordRecent() async throws {
        let file = try makeFile(named: "binary.xyz", content: "data")
        let (settings, _) = makeSettings()
        let session = WindowSession(id: WindowID(), settings: settings)

        await session.openFile(file)

        XCTAssertNotNil(session.documentViewModel.fileError)
        XCTAssertTrue(settings.recentItems.isEmpty)
    }

    func testOpenDirectoryRecordsRecentOnlyAfterSuccessfulLoad() async throws {
        let directory = try makeDirectory(named: "docs")
        try makeFile(named: "note.md", in: directory, content: "# Note")
        let (settings, _) = makeSettings()
        let session = WindowSession(id: WindowID(), settings: settings)

        await session.openDirectory(directory)

        XCTAssertEqual(settings.recentItems.map(\.url.path), [directory.standardizedFileURL.path])
        XCTAssertEqual(session.appViewModel.rootDirectory?.standardizedFileURL, directory.standardizedFileURL)
    }

    func testOpenMissingDirectoryDoesNotRecordRecent() async throws {
        let directory = temporaryDirectory.appendingPathComponent("missing")
        let (settings, _) = makeSettings()
        let session = WindowSession(id: WindowID(), settings: settings)

        await session.openDirectory(directory)

        XCTAssertNotNil(session.fileTreeViewModel.errorMessage)
        XCTAssertTrue(settings.recentItems.isEmpty)
    }
}

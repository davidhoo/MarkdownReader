import XCTest
import MarkdownReaderKit
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

    func testDocumentViewModelLoadFileRecordsRecentItem() async throws {
        let file = try makeFile(named: "guide.md", content: "# Guide")
        let (settings, _) = makeSettings()
        let docVM = DocumentViewModel(settings: settings)

        await docVM.loadFile(at: file)

        XCTAssertEqual(settings.recentItems.map(\.url), [file.standardizedFileURL])
        XCTAssertEqual(docVM.currentFileURL?.standardizedFileURL, file.standardizedFileURL)
    }

    func testDocumentViewModelLoadFileDoesNotRecordUntitledTempFile() async throws {
        let (settings, _) = makeSettings()
        let docVM = DocumentViewModel(settings: settings)
        let tempDir = DocumentViewModel.untitledDirectory
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempFile = tempDir.appendingPathComponent("Untitled.md")
        try "# Untitled".write(to: tempFile, atomically: true, encoding: .utf8)

        await docVM.loadFile(at: tempFile)

        XCTAssertTrue(settings.recentItems.isEmpty)
    }

    func testRecentDocumentsMenuServicePopulatesMenu() throws {
        let (settings, _) = makeSettings()
        let menu = NSMenu(title: "Open Recent")
        let service = RecentDocumentsMenuService(settings: settings)

        // 1. Empty state
        service.populateMenu(menu)
        XCTAssertEqual(menu.items.count, 1)
        XCTAssertFalse(menu.items[0].isEnabled)

        // 2. Add an item
        let file = try makeFile(named: "note.md", content: "# Note")
        settings.addRecentItem(url: file, isDirectory: false)
        service.populateMenu(menu)

        XCTAssertTrue(menu.items.contains { $0.title == file.standardizedFileURL.path })
        guard let clearItem = menu.items.first(where: { $0.action == #selector(RecentDocumentsMenuService.handleClearRecentItems(_:)) }) else {
            XCTFail("Missing clear recent items item")
            return
        }

        // 3. Trigger clear action
        service.handleClearRecentItems(clearItem)
        XCTAssertTrue(settings.recentItems.isEmpty)
    }

    func testRecentDocumentsMenuServiceRepairsFlattenedMenuItem() throws {
        let (settings, _) = makeSettings()
        let service = RecentDocumentsMenuService(settings: settings)
        let item = NSMenuItem(
            title: L10n.tr(.openRecentEmpty, language: settings.languagePref.resolvedLanguage),
            action: nil,
            keyEquivalent: ""
        )

        service.ensureSubmenu(for: item)

        XCTAssertEqual(item.title, L10n.tr(.openRecent, language: settings.languagePref.resolvedLanguage))
        XCTAssertNotNil(item.submenu)
        XCTAssertEqual(item.submenu?.items.count, 1)
        XCTAssertFalse(item.submenu?.items.first?.isEnabled ?? true)
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import MarkdownReader

@MainActor
final class WindowChromeTests: XCTestCase {

    func testWindowChromeConfiguratorShowsCentersAndKeepsNativeTrafficLightsOnResize() throws {
        let coordinator = WindowCoordinator()
        let session = WindowSession(id: WindowID(), coordinator: coordinator)
        coordinator.register(session: session)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        let hosting = NSHostingController(rootView: ContentView(session: session))
        window.contentView = hosting.view
        flushMainQueue()

        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let miniaturizeButton = try XCTUnwrap(window.standardWindowButton(.miniaturizeButton))
        let zoomButton = try XCTUnwrap(window.standardWindowButton(.zoomButton))

        XCTAssertFalse(closeButton.isHidden, "系统关闭按钮必须保持可见")
        XCTAssertFalse(miniaturizeButton.isHidden, "系统最小化按钮必须保持可见")
        XCTAssertFalse(zoomButton.isHidden, "系统缩放按钮必须保持可见")
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)

        let closeInWindow = closeButton.convert(closeButton.bounds, to: nil)
        let zoomInWindow = zoomButton.convert(zoomButton.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(closeInWindow.minX, WindowChromeConfigurator.leadingInset)
        XCTAssertEqual(
            window.frame.height - closeInWindow.midY,
            WindowChromeConfigurator.titleBarHeight / 2,
            accuracy: 1.0,
            "系统红绿灯应垂直居中在 50pt 标题栏内"
        )
        XCTAssertEqual(session.appViewModel.trafficLightTrailingInset, zoomInWindow.maxX.rounded(.up))

        window.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 700), display: false)
        window.layoutIfNeeded()
        flushMainQueue()

        let resizedCloseInWindow = closeButton.convert(closeButton.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(resizedCloseInWindow.minX, WindowChromeConfigurator.leadingInset)
        XCTAssertEqual(
            window.frame.height - resizedCloseInWindow.midY,
            WindowChromeConfigurator.titleBarHeight / 2,
            accuracy: 1.0,
            "窗口调整大小后系统红绿灯仍应垂直居中在 50pt 标题栏内"
        )

        window.contentView = nil
    }

    func testTrafficLightSpacingAdaptsToFullScreenPerWindow() {
        let windowA = AppViewModel()
        let windowB = AppViewModel()

        XCTAssertEqual(windowA.trafficLightLeadingSpace, WindowChromeConfigurator.defaultTrailingInset)
        XCTAssertEqual(windowA.titleBarLeadingPadding, 8)

        windowA.trafficLightTrailingInset = 79
        XCTAssertEqual(windowA.trafficLightLeadingSpace, 79)
        XCTAssertEqual(windowB.trafficLightLeadingSpace, WindowChromeConfigurator.defaultTrailingInset)

        windowA.isFullScreen = true
        XCTAssertEqual(windowA.trafficLightLeadingSpace, 0)
        XCTAssertEqual(windowA.titleBarLeadingPadding, 12)
        XCTAssertEqual(windowB.trafficLightLeadingSpace, WindowChromeConfigurator.defaultTrailingInset)
        XCTAssertEqual(windowB.titleBarLeadingPadding, 8)
    }

    private func flushMainQueue() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }
}

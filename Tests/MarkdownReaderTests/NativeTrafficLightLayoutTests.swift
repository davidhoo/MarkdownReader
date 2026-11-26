import AppKit
import SwiftUI
import XCTest
@testable import MarkdownReader

@MainActor
final class NativeTrafficLightLayoutTests: XCTestCase {

    func testTitlebarContainerFramePlacesBarAtTopForUnflippedAndFlippedThemeFrames() {
        let themeBounds = CGRect(x: 0, y: 0, width: 960, height: 640)

        let unflipped = NativeTrafficLightLayout.titlebarContainerFrame(
            in: themeBounds,
            isFlipped: false
        )
        XCTAssertEqual(unflipped, CGRect(x: 0, y: 590, width: 960, height: 50))

        let flipped = NativeTrafficLightLayout.titlebarContainerFrame(
            in: themeBounds,
            isFlipped: true
        )
        XCTAssertEqual(flipped, CGRect(x: 0, y: 0, width: 960, height: 50))
    }

    func testButtonOriginsCenterMacOS27ButtonsAndPreserveNativeSpacing() {
        let superviewBounds = CGRect(x: 0, y: 0, width: 960, height: 50)
        let compactMacOS27Buttons = [
            CGRect(x: 8, y: 7, width: 14, height: 14),
            CGRect(x: 31, y: 7, width: 14, height: 14),
            CGRect(x: 54, y: 7, width: 14, height: 14)
        ]

        let origins = NativeTrafficLightLayout.buttonOrigins(
            for: compactMacOS27Buttons,
            in: superviewBounds
        )

        XCTAssertEqual(origins, [
            CGPoint(x: 14, y: 18),
            CGPoint(x: 37, y: 18),
            CGPoint(x: 60, y: 18)
        ])
        XCTAssertEqual(origins[1].x - origins[0].x, 23)
        XCTAssertEqual(origins[2].x - origins[1].x, 23)
    }

    func testButtonOriginsPreserveWiderNativeLeadingInsetAndAreIdempotent() {
        let superviewBounds = CGRect(x: 0, y: 0, width: 960, height: 50)
        let macOS27UnifiedButtons = [
            CGRect(x: 19, y: 7, width: 14, height: 14),
            CGRect(x: 42, y: 7, width: 14, height: 14),
            CGRect(x: 65, y: 7, width: 14, height: 14)
        ]

        let firstPass = NativeTrafficLightLayout.buttonOrigins(
            for: macOS27UnifiedButtons,
            in: superviewBounds
        )
        XCTAssertEqual(firstPass, [
            CGPoint(x: 19, y: 18),
            CGPoint(x: 42, y: 18),
            CGPoint(x: 65, y: 18)
        ])

        let repositionedFrames = zip(macOS27UnifiedButtons, firstPass).map { frame, origin in
            CGRect(origin: origin, size: frame.size)
        }
        let secondPass = NativeTrafficLightLayout.buttonOrigins(
            for: repositionedFrames,
            in: superviewBounds
        )
        XCTAssertEqual(secondPass, firstPass)
    }

    func testGroupContainerOriginCentersAndClampsLeadingInsetIdempotently() {
        let parentBounds = CGRect(x: 0, y: 0, width: 960, height: 50)
        let compactGroup = CGRect(x: 8, y: 7, width: 60, height: 14)

        let first = NativeTrafficLightLayout.groupContainerOrigin(
            for: compactGroup,
            in: parentBounds
        )
        XCTAssertEqual(first, CGPoint(x: 14, y: 18))

        let second = NativeTrafficLightLayout.groupContainerOrigin(
            for: CGRect(origin: first, size: compactGroup.size),
            in: parentBounds
        )
        XCTAssertEqual(second, first)

        let wideGroup = CGRect(x: 19, y: 18, width: 60, height: 14)
        XCTAssertEqual(
            NativeTrafficLightLayout.groupContainerOrigin(for: wideGroup, in: parentBounds),
            CGPoint(x: 19, y: 18)
        )
    }

    func testSanitizedTrailingInsetRoundsUpValidValuesAndFallsBackOnInvalidValues() {
        XCTAssertEqual(NativeTrafficLightLayout.sanitizedTrailingInset(zoomButtonMaxX: 78.5), 79)
        XCTAssertEqual(NativeTrafficLightLayout.sanitizedTrailingInset(zoomButtonMaxX: 74), 74)
        XCTAssertEqual(
            NativeTrafficLightLayout.sanitizedTrailingInset(zoomButtonMaxX: 0),
            NativeTrafficLightLayout.defaultTrailingInset
        )
        XCTAssertEqual(
            NativeTrafficLightLayout.sanitizedTrailingInset(zoomButtonMaxX: -12),
            NativeTrafficLightLayout.defaultTrailingInset
        )
        XCTAssertEqual(
            NativeTrafficLightLayout.sanitizedTrailingInset(zoomButtonMaxX: .nan),
            NativeTrafficLightLayout.defaultTrailingInset
        )
        XCTAssertEqual(
            NativeTrafficLightLayout.sanitizedTrailingInset(zoomButtonMaxX: 300),
            NativeTrafficLightLayout.defaultTrailingInset
        )
    }

    func testAppViewModelTrafficLightSpacingAdaptsToFullScreenPerWindow() {
        let windowA = AppViewModel()
        let windowB = AppViewModel()

        XCTAssertEqual(windowA.trafficLightLeadingSpace, NativeTrafficLightLayout.defaultTrailingInset)
        XCTAssertEqual(windowA.titleBarLeadingPadding, 8)

        windowA.trafficLightTrailingInset = 79
        XCTAssertEqual(windowA.trafficLightLeadingSpace, 79)
        XCTAssertEqual(windowB.trafficLightLeadingSpace, NativeTrafficLightLayout.defaultTrailingInset)

        windowA.isFullScreen = true
        XCTAssertEqual(windowA.trafficLightLeadingSpace, 0)
        XCTAssertEqual(windowA.titleBarLeadingPadding, 12)
        XCTAssertEqual(windowB.trafficLightLeadingSpace, NativeTrafficLightLayout.defaultTrailingInset)
        XCTAssertEqual(windowB.titleBarLeadingPadding, 8)
    }

    func testWindowChromeConfiguratorShowsNativeTrafficLightsAndMeasuresTrailingInset() throws {
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

        let expectedInset = NativeTrafficLightLayout.sanitizedTrailingInset(
            zoomButtonMaxX: zoomButton.convert(zoomButton.bounds, to: nil).maxX
        )
        XCTAssertEqual(session.appViewModel.trafficLightTrailingInset, expectedInset)

        let closeInWindow = closeButton.convert(closeButton.bounds, to: nil)
        let centerDistanceFromTop = window.frame.height - closeInWindow.midY
        XCTAssertEqual(
            centerDistanceFromTop,
            NativeTrafficLightLayout.titleBarHeight / 2,
            accuracy: 2.0,
            "系统红绿灯应垂直居中在 50pt 标题栏内"
        )

        window.contentView = nil
    }

    private func flushMainQueue() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }
}

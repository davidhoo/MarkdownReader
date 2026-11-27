import AppKit
import SwiftUI

/// Configures the hosting `NSWindow` for a borderless custom title bar while keeping
/// macOS's native traffic-light buttons visible and vertically centered in the 50pt bar.
struct WindowChromeConfigurator: NSViewRepresentable {
    static let titleBarHeight: CGFloat = 50
    static let leadingInset: CGFloat = 18
    static let defaultTrailingInset: CGFloat = 78

    let bgColor: Color
    let appViewModel: AppViewModel

    func makeNSView(context: Context) -> NSView {
        let view = ObserverView()
        view.bgColor = NSColor(bgColor)
        view.appViewModel = appViewModel
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let observer = nsView as? ObserverView else { return }
        observer.bgColor = NSColor(bgColor)
        observer.appViewModel = appViewModel
        observer.updateWindowBackground()
    }

    private final class ObserverView: NSView {
        var bgColor: NSColor = .windowBackgroundColor
        weak var appViewModel: AppViewModel?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
        private var isApplyingLayout = false
        private var isInFullScreenTransition = false

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeAllObservers()
            isInFullScreenTransition = false
            guard let window else { return }

            configureChrome(for: window)
            installObservers(for: window)
            applyTrafficLightLayout()

            Task { @MainActor [weak self] in
                self?.applyTrafficLightLayout()
            }
        }

        func updateWindowBackground() {
            window?.backgroundColor = bgColor
        }

        private func removeAllObservers() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
        }

        private func configureChrome(for window: NSWindow) {
            window.standardWindowButton(.closeButton)?.isHidden = false
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isHidden = false
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.titleVisibility = .hidden
            updateWindowBackground()
            NSWindow.swizzleUndoManager()
        }

        private func installObservers(for window: NSWindow) {
            let center = NotificationCenter.default

            let resizeToken = center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.applyTrafficLightLayout()
                }
            }
            observers.append(resizeToken)

            if let closeButton = window.standardWindowButton(.closeButton) {
                closeButton.postsFrameChangedNotifications = true
                let frameToken = center.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: closeButton,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        self.applyTrafficLightLayout()
                    }
                }
                observers.append(frameToken)
            }

            let willEnter = center.addObserver(
                forName: NSWindow.willEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.isInFullScreenTransition = true
                }
            }

            let didEnter = center.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.isInFullScreenTransition = false
                }
            }

            let willExit = center.addObserver(
                forName: NSWindow.willExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.isInFullScreenTransition = true
                }
            }

            let didExit = center.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.isInFullScreenTransition = false
                    self.applyTrafficLightLayout()
                    Task { @MainActor [weak self] in
                        self?.applyTrafficLightLayout()
                    }
                }
            }

            observers.append(contentsOf: [willEnter, didEnter, willExit, didExit])
        }

        private func applyTrafficLightLayout() {
            guard !isApplyingLayout,
                  !isInFullScreenTransition,
                  let window,
                  !window.styleMask.contains(.fullScreen),
                  let closeButton = window.standardWindowButton(.closeButton),
                  let miniaturizeButton = window.standardWindowButton(.miniaturizeButton),
                  let zoomButton = window.standardWindowButton(.zoomButton),
                  let superview = closeButton.superview
            else { return }

            isApplyingLayout = true
            defer { isApplyingLayout = false }

            closeButton.isHidden = false
            miniaturizeButton.isHidden = false
            zoomButton.isHidden = false

            let targetMidYInWindow = window.frame.height - WindowChromeConfigurator.titleBarHeight / 2
            let targetMidY = superview.convert(NSPoint(x: 0, y: targetMidYInWindow), from: nil).y
            let deltaX = max(0, WindowChromeConfigurator.leadingInset - closeButton.frame.minX)

            for button in [closeButton, miniaturizeButton, zoomButton] {
                let rawY = (targetMidY - button.frame.height / 2).rounded()
                let maxY = max(0, superview.bounds.height - button.frame.height)
                let clampedY = min(max(0, rawY), maxY)
                let targetOrigin = NSPoint(
                    x: (button.frame.origin.x + deltaX).rounded(),
                    y: clampedY
                )
                if abs(button.frame.origin.x - targetOrigin.x) > 0.5
                    || abs(button.frame.origin.y - targetOrigin.y) > 0.5 {
                    button.setFrameOrigin(targetOrigin)
                }
            }

            let zoomMaxX = zoomButton.convert(zoomButton.bounds, to: nil).maxX
            if zoomMaxX.isFinite, zoomMaxX > 0, zoomMaxX < 200 {
                let inset = zoomMaxX.rounded(.up)
                if let appViewModel, abs(appViewModel.trafficLightTrailingInset - inset) > 0.5 {
                    appViewModel.trafficLightTrailingInset = inset
                }
            }
        }
    }
}

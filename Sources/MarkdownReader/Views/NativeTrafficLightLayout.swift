import AppKit
import SwiftUI

enum NativeTrafficLightLayout: Sendable {
    static let titleBarHeight: CGFloat = 50
    static let minLeadingInset: CGFloat = 14
    static let defaultTrailingInset: CGFloat = 78
    static let maxValidTrailingInset: CGFloat = 200

    static func titlebarContainerFrame(
        in themeFrameBounds: CGRect,
        isFlipped: Bool,
        titleBarHeight: CGFloat = titleBarHeight
    ) -> CGRect {
        let y = isFlipped ? 0 : themeFrameBounds.height - titleBarHeight
        return CGRect(
            x: 0,
            y: y,
            width: themeFrameBounds.width,
            height: titleBarHeight
        )
    }

    static func buttonOrigins(
        for buttonFrames: [CGRect],
        in superviewBounds: CGRect,
        minLeadingInset: CGFloat = minLeadingInset
    ) -> [CGPoint] {
        guard let currentMinX = buttonFrames.map(\.minX).min() else { return [] }
        let deltaX = max(0, minLeadingInset - currentMinX)
        return buttonFrames.map { frame in
            let y = ((superviewBounds.height - frame.height) / 2).rounded()
            return CGPoint(x: frame.origin.x + deltaX, y: y)
        }
    }

    static func groupContainerOrigin(
        for groupFrame: CGRect,
        in parentBounds: CGRect,
        minLeadingInset: CGFloat = minLeadingInset
    ) -> CGPoint {
        let x = max(groupFrame.origin.x, minLeadingInset)
        let y = ((parentBounds.height - groupFrame.height) / 2).rounded()
        return CGPoint(x: x, y: y)
    }

    static func sanitizedTrailingInset(
        zoomButtonMaxX: CGFloat,
        fallback: CGFloat = defaultTrailingInset
    ) -> CGFloat {
        guard zoomButtonMaxX.isFinite,
              zoomButtonMaxX > 0,
              zoomButtonMaxX < maxValidTrailingInset
        else {
            return fallback
        }
        return zoomButtonMaxX.rounded(.up)
    }

    static func leadingSpace(isFullScreen: Bool, trailingInset: CGFloat) -> CGFloat {
        isFullScreen ? 0 : trailingInset
    }

    static func titleBarLeadingPadding(isFullScreen: Bool) -> CGFloat {
        isFullScreen ? 12 : 8
    }

    static func framesDiffer(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) > tolerance
            || abs(lhs.origin.y - rhs.origin.y) > tolerance
            || abs(lhs.size.width - rhs.size.width) > tolerance
            || abs(lhs.size.height - rhs.size.height) > tolerance
    }

    static func pointsDiffer(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs.x - rhs.x) > tolerance || abs(lhs.y - rhs.y) > tolerance
    }
}

struct WindowChromeConfigurator: NSViewRepresentable {
    let bgColor: Color
    let appViewModel: AppViewModel

    func makeNSView(context: Context) -> NSView {
        let view = WindowChromeObserverView()
        view.bgColor = NSColor(bgColor)
        view.appViewModel = appViewModel
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let observer = nsView as? WindowChromeObserverView else { return }
        observer.bgColor = NSColor(bgColor)
        observer.appViewModel = appViewModel
        observer.updateWindowBackground()
    }

    private final class WindowChromeObserverView: NSView {
        var bgColor: NSColor = .windowBackgroundColor
        weak var appViewModel: AppViewModel?
        nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []
        nonisolated(unsafe) private var frameObservers: [NSObjectProtocol] = []
        private weak var observedTitlebarContainer: NSView?
        private weak var observedButtonsSuperview: NSView?
        private var isInFullScreenTransition = false
        private var isApplyingLayout = false

        deinit {
            for observer in windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            for observer in frameObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeAllObservers()
            isInFullScreenTransition = false
            guard let window else { return }

            configureChrome(for: window)
            installWindowObservers(for: window)
            applyTrafficLightLayout()

            Task { @MainActor [weak self] in
                self?.applyTrafficLightLayout()
            }
        }

        func updateWindowBackground() {
            guard let window else { return }
            window.backgroundColor = bgColor
        }

        private func removeAllObservers() {
            for observer in windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            windowObservers.removeAll()
            removeFrameObservers()
        }

        private func removeFrameObservers() {
            for observer in frameObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            frameObservers.removeAll()
            observedTitlebarContainer = nil
            observedButtonsSuperview = nil
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

        private func installWindowObservers(for window: NSWindow) {
            let center = NotificationCenter.default

            let layoutTriggerNotifications: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didChangeScreenNotification,
                NSWindow.didChangeBackingPropertiesNotification
            ]

            for name in layoutTriggerNotifications {
                let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        self.applyTrafficLightLayout()
                    }
                }
                windowObservers.append(token)
            }

            let willEnterFullScreen = center.addObserver(
                forName: NSWindow.willEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.isInFullScreenTransition = true
                }
            }

            let didEnterFullScreen = center.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.isInFullScreenTransition = false
                }
            }

            let willExitFullScreen = center.addObserver(
                forName: NSWindow.willExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.isInFullScreenTransition = true
                }
            }

            let didExitFullScreen = center.addObserver(
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

            windowObservers.append(contentsOf: [
                willEnterFullScreen,
                didEnterFullScreen,
                willExitFullScreen,
                didExitFullScreen
            ])
        }

        private func syncFrameObservers(
            titlebarContainer: NSView,
            closeButton: NSButton,
            buttonsSuperview: NSView?
        ) {
            guard titlebarContainer !== observedTitlebarContainer
                || buttonsSuperview !== observedButtonsSuperview
            else { return }

            removeFrameObservers()
            observedTitlebarContainer = titlebarContainer
            observedButtonsSuperview = buttonsSuperview

            var viewsToObserve: [NSView] = [titlebarContainer, closeButton]
            if let buttonsSuperview,
               buttonsSuperview !== titlebarContainer,
               buttonsSuperview !== closeButton {
                viewsToObserve.append(buttonsSuperview)
            }

            let center = NotificationCenter.default
            for view in viewsToObserve {
                view.postsFrameChangedNotifications = true
                let token = center.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: view,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        self.applyTrafficLightLayout()
                    }
                }
                frameObservers.append(token)
            }
        }

        private func applyTrafficLightLayout() {
            guard !isApplyingLayout,
                  !isInFullScreenTransition,
                  let window,
                  !window.styleMask.contains(.fullScreen),
                  let closeButton = window.standardWindowButton(.closeButton),
                  let miniaturizeButton = window.standardWindowButton(.miniaturizeButton),
                  let zoomButton = window.standardWindowButton(.zoomButton),
                  let themeFrame = window.contentView?.superview,
                  themeFrame.bounds.width > 0,
                  themeFrame.bounds.height >= NativeTrafficLightLayout.titleBarHeight
            else { return }

            isApplyingLayout = true
            defer { isApplyingLayout = false }

            closeButton.isHidden = false
            miniaturizeButton.isHidden = false
            zoomButton.isHidden = false

            var chain: [NSView] = []
            var cursor = closeButton.superview
            while let view = cursor, view !== themeFrame {
                chain.append(view)
                cursor = view.superview
            }

            guard cursor === themeFrame, let titlebarContainerView = chain.last else {
                updateTrailingInset(from: zoomButton)
                return
            }

            syncFrameObservers(
                titlebarContainer: titlebarContainerView,
                closeButton: closeButton,
                buttonsSuperview: closeButton.superview
            )

            let targetContainerFrame = NativeTrafficLightLayout.titlebarContainerFrame(
                in: themeFrame.bounds,
                isFlipped: themeFrame.isFlipped
            )
            if NativeTrafficLightLayout.framesDiffer(titlebarContainerView.frame, targetContainerFrame) {
                titlebarContainerView.frame = targetContainerFrame
            }

            let fullWidthThreshold = targetContainerFrame.width * 0.5

            if chain.count >= 2 {
                for index in stride(from: chain.count - 2, through: 0, by: -1) {
                    let view = chain[index]
                    guard let parent = view.superview else { continue }
                    if view.frame.width >= fullWidthThreshold,
                       NativeTrafficLightLayout.framesDiffer(view.frame, parent.bounds) {
                        view.frame = parent.bounds
                    }
                }
            }

            if let buttonsSuperview = closeButton.superview {
                let sharesSuperview = miniaturizeButton.superview === buttonsSuperview
                    && zoomButton.superview === buttonsSuperview
                if sharesSuperview
                    && buttonsSuperview !== titlebarContainerView
                    && buttonsSuperview.frame.width < fullWidthThreshold,
                   let parent = buttonsSuperview.superview {
                    let targetOrigin = NativeTrafficLightLayout.groupContainerOrigin(
                        for: buttonsSuperview.frame,
                        in: parent.bounds
                    )
                    if NativeTrafficLightLayout.pointsDiffer(buttonsSuperview.frame.origin, targetOrigin) {
                        buttonsSuperview.setFrameOrigin(targetOrigin)
                    }
                } else if sharesSuperview {
                    let buttons = [closeButton, miniaturizeButton, zoomButton]
                    let targetOrigins = NativeTrafficLightLayout.buttonOrigins(
                        for: buttons.map(\.frame),
                        in: buttonsSuperview.bounds
                    )
                    for (button, targetOrigin) in zip(buttons, targetOrigins) {
                        if NativeTrafficLightLayout.pointsDiffer(button.frame.origin, targetOrigin) {
                            button.setFrameOrigin(targetOrigin)
                        }
                    }
                }
            }

            updateTrailingInset(from: zoomButton)
        }

        private func updateTrailingInset(from zoomButton: NSButton) {
            let zoomRectInWindow = zoomButton.convert(zoomButton.bounds, to: nil)
            let inset = NativeTrafficLightLayout.sanitizedTrailingInset(
                zoomButtonMaxX: zoomRectInWindow.maxX
            )
            if let appViewModel, abs(appViewModel.trafficLightTrailingInset - inset) > 0.5 {
                appViewModel.trafficLightTrailingInset = inset
            }
        }
    }
}

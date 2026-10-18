import AppKit
import SwiftUI

/// The main window draws its own sidebar and toolbar under a hidden title bar.
/// This places the traffic lights in the centre of the 52 pt toolbar band, as in
/// the design, and keeps them there across resizing and key-state changes.
struct WindowChrome: NSViewRepresentable {
    var band: CGFloat = 52
    var leading: CGFloat = 16

    func makeNSView(context: Context) -> NSView { ChromeView(band: band, leading: leading) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class ChromeView: NSView {
        private let band: CGFloat
        private let leading: CGFloat
        private var observers: [NSObjectProtocol] = []

        init(band: CGFloat, leading: CGFloat) {
            self.band = band
            self.leading = leading
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didExitFullScreenNotification
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.placeButtons() }
                })
            }
            placeButtons()
            DispatchQueue.main.async { [weak self] in self?.placeButtons() }
        }

        override func layout() {
            super.layout()
            placeButtons()
        }

        private func placeButtons() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let minimize = window.standardWindowButton(.miniaturizeButton),
                  let zoom = window.standardWindowButton(.zoomButton),
                  let container = close.superview?.superview else { return }
            var frame = container.frame
            if frame.height != band || frame.minY != window.frame.height - band {
                frame.size.height = band
                frame.origin.y = window.frame.height - band
                container.frame = frame
            }
            let step = minimize.frame.minX - close.frame.minX
            for (index, button) in [close, minimize, zoom].enumerated() {
                let origin = NSPoint(x: leading + CGFloat(index) * (step > 0 ? step : 23),
                                     y: (band - button.frame.height) / 2)
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }
    }
}

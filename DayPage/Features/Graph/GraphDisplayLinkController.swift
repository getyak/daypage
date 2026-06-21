import UIKit

// MARK: - GraphDisplayLinkController

/// Display-link-driven tick controller for the GraphView force simulation.
///
/// Replaces a fixed-rate `Timer.scheduledTimer(withTimeInterval: 1/30)` with a
/// CADisplayLink that is synchronized to the screen's refresh cycle and
/// honors the system's energy / Low Power Mode policies. The tick rate is
/// pinned to 30fps via `preferredFramesPerSecond` to match the previous
/// simulation cadence.
///
/// Owned by `GraphView` as a `@StateObject` so the link is automatically
/// invalidated when the view disappears from the navigation stack.
@MainActor
final class GraphDisplayLinkController: NSObject, ObservableObject {

    private var link: CADisplayLink?

    /// Callback invoked on each display tick on the main thread.
    var onTick: (() -> Void)?

    /// Starts the display link if it is not already running.
    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFramesPerSecond = 30
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// Invalidates the display link and clears the reference.
    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        onTick?()
    }

    deinit {
        link?.invalidate()
    }
}

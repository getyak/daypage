import SwiftUI

// MARK: - GrainOverlay

/// Full-screen grain texture overlay used on all auth screens.
/// Rendered via Canvas so it never intercepts taps.
struct GrainOverlay: View {

    var dotCount: Int = 800

    var body: some View {
        Canvas { context, size in
            for _ in 0..<dotCount {
                let x = CGFloat.random(in: 0..<size.width)
                let y = CGFloat.random(in: 0..<size.height)
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)),
                    with: .color(.white.opacity(0.04))
                )
            }
        }
        .ignoresSafeArea()
        .blendMode(.overlay)
        .allowsHitTesting(false)
    }
}

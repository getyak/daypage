import SwiftUI

// MARK: - GraphSkeleton

struct GraphSkeleton: View {

    @State private var shimmerPhase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Deterministic node layout: (x%, y%, diameter)
    private static let nodes: [(x: CGFloat, y: CGFloat, d: CGFloat)] = [
        (0.50, 0.40, 40),
        (0.28, 0.28, 28),
        (0.72, 0.30, 32),
        (0.20, 0.58, 24),
        (0.65, 0.62, 20),
        (0.45, 0.72, 16),
        (0.80, 0.52, 22),
    ]

    // Deterministic edges as index pairs into nodes array
    private static let edges: [(Int, Int)] = [
        (0, 1), (0, 2), (0, 4), (1, 3), (2, 6), (4, 5),
    ]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let centers = Self.nodes.map { CGPoint(x: $0.x * w, y: $0.y * h) }

            ZStack {
                // Edge lines drawn behind circles
                edgePaths(centers: centers)
                    .stroke(DSColor.inkFaint.opacity(0.6), lineWidth: 1)

                // Node circles
                ForEach(0..<Self.nodes.count, id: \.self) { i in
                    let d = Self.nodes[i].d
                    Circle()
                        .fill(DSColor.inkFaint)
                        .frame(width: d, height: d)
                        .position(centers[i])
                }

                // Shimmer band swept across the whole composition
                if !reduceMotion {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: DSColor.inkFaint.opacity(0.4), location: 0.45),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: w * 0.55)
                    .offset(x: w * 0.5 + shimmerPhase * w)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: w, height: h)
            .onAppear { startShimmer() }
        }
        .accessibilityHidden(true)
    }

    private func edgePaths(centers: [CGPoint]) -> Path {
        var path = Path()
        for (a, b) in Self.edges {
            path.move(to: centers[a])
            path.addLine(to: centers[b])
        }
        return path
    }

    private func startShimmer() {
        guard !reduceMotion else { return }
        shimmerPhase = -1
        withAnimation(Animation.linear(duration: 1.6).repeatForever(autoreverses: false)) {
            shimmerPhase = 1
        }
    }
}

// MARK: - Preview

#Preview {
    GraphSkeleton()
        .padding(40)
        .frame(width: 360, height: 400)
        .background(DSColor.bgWarm)
}

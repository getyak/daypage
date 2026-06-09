import SwiftUI

// MARK: - MemoListSkeleton

/// Placeholder skeleton shown in TodayView while the initial vault load is in flight.
/// `count` controls how many placeholder cards are rendered (clamped to 1…6) so the
/// skeleton height closely matches the incoming content and avoids a layout shift.
struct MemoListSkeleton: View {
    var count: Int = 3

    private var clampedCount: Int { max(1, min(count, 6)) }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<clampedCount, id: \.self) { idx in
                SkeletonCard(lineCount: lineCount(for: idx), wide: idx % 3 == 1)
            }
        }
        .accessibilityHidden(true)
    }

    private func lineCount(for index: Int) -> Int {
        let pattern = [3, 2, 4, 2, 3, 4]
        return pattern[index % pattern.count]
    }
}

// MARK: - SkeletonCard

private struct SkeletonCard: View {
    let lineCount: Int
    let wide: Bool

    @State private var shimmerPhase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Timestamp pill
            RoundedRectangle(cornerRadius: 3)
                .fill(DSColor.inkFaint)
                .frame(width: 80, height: 8)

            // Body lines
            ForEach(0..<lineCount, id: \.self) { idx in
                RoundedRectangle(cornerRadius: 3)
                    .fill(DSColor.inkFaint)
                    .frame(maxWidth: lineWidth(for: idx), alignment: .leading)
                    .frame(height: 10)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSColor.glassStd)
        .overlay(shimmerOverlay)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(DSColor.glassRim, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { startShimmer() }
    }

    @ViewBuilder
    private var shimmerOverlay: some View {
        if !reduceMotion {
            GeometryReader { geo in
                let w = geo.size.width
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: DSColor.inkFaint.opacity(0.35), location: 0.4),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                // band is 60% of card width; shimmerPhase sweeps -1 → 1
                .frame(width: w * 0.6)
                .offset(x: w * 0.5 + shimmerPhase * w)
                .blendMode(.plusLighter)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .allowsHitTesting(false)
        }
    }

    private func lineWidth(for index: Int) -> CGFloat {
        let widths: [CGFloat] = wide
            ? [.infinity, .infinity, 180, 120, .infinity]
            : [.infinity, 240, 160, .infinity, 200]
        return widths[index % widths.count]
    }

    private func startShimmer() {
        guard !reduceMotion else { return }
        shimmerPhase = -1
        withAnimation(
            Animation.linear(duration: 1.4)
                .repeatForever(autoreverses: false)
        ) {
            shimmerPhase = 1
        }
    }
}

import SwiftUI

// MARK: - MemoListSkeleton

/// Placeholder skeleton shown in TodayView while the initial vault load is in flight.
/// Mirrors the approximate shape of 3 MemoCardView rows so the layout doesn't shift
/// once real content appears. Uses a shimmer animation to signal activity.
struct MemoListSkeleton: View {
    var body: some View {
        VStack(spacing: 8) {
            SkeletonCard(lineCount: 3, wide: false)
            SkeletonCard(lineCount: 2, wide: true)
            SkeletonCard(lineCount: 4, wide: false)
        }
    }
}

// MARK: - SkeletonCard

private struct SkeletonCard: View {
    let lineCount: Int
    let wide: Bool

    @State private var shimmerPhase: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Timestamp pill
            RoundedRectangle(cornerRadius: 3)
                .fill(shimmerColor)
                .frame(width: 80, height: 8)

            // Body lines
            ForEach(0..<lineCount, id: \.self) { idx in
                RoundedRectangle(cornerRadius: 3)
                    .fill(shimmerColor)
                    .frame(maxWidth: lineWidth(for: idx), alignment: .leading)
                    .frame(height: 10)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSColor.glassStd)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(DSColor.glassRim, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { startShimmer() }
    }

    private var shimmerColor: Color {
        DSColor.inkFaint
    }

    private func lineWidth(for index: Int) -> CGFloat {
        let widths: [CGFloat] = wide
            ? [.infinity, .infinity, 180, 120, .infinity]
            : [.infinity, 240, 160, .infinity, 200]
        return widths[index % widths.count]
    }

    private func startShimmer() {
        withAnimation(
            Animation.easeInOut(duration: 1.2)
                .repeatForever(autoreverses: true)
        ) {
            shimmerPhase = 1
        }
    }
}

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

    @State private var shimmerOffset: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseOpacity: Double = 0.5

    var body: some View {
        GeometryReader { geo in
            let cardWidth = geo.size.width
            cardContent(cardWidth: cardWidth)
        }
        .frame(height: cardHeight)
    }

    private var cardHeight: CGFloat {
        // Timestamp pill (8) + lineCount * line (10) + spacing ((lineCount) * 6) + padding (32)
        CGFloat(8 + lineCount * 10 + lineCount * 6 + 32)
    }

    @ViewBuilder
    private func cardContent(cardWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            // Base card shape with placeholder bars
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(DSColor.inkFaint)
                    .frame(width: 80, height: 8)

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
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(DSColor.glassRim, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Shimmer highlight overlay
            if reduceMotion {
                // Gentle opacity pulse instead of horizontal motion
                RoundedRectangle(cornerRadius: 12)
                    .fill(DSColor.bgWarm.opacity(0.25 * pulseOpacity))
                    .allowsHitTesting(false)
                    .onAppear { startPulse() }
            } else {
                // Sweeping linear gradient
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: DSColor.bgWarm.opacity(0.6), location: 0.5),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: cardWidth)
                .offset(x: shimmerOffset * cardWidth)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
                .onAppear { startSweep(cardWidth: cardWidth) }
            }
        }
    }

    private func lineWidth(for index: Int) -> CGFloat {
        let widths: [CGFloat] = wide
            ? [.infinity, .infinity, 180, 120, .infinity]
            : [.infinity, 240, 160, .infinity, 200]
        return widths[index % widths.count]
    }

    private func startSweep(cardWidth: CGFloat) {
        shimmerOffset = -1
        withAnimation(
            Animation.easeInOut(duration: 1.2)
                .repeatForever(autoreverses: false)
        ) {
            shimmerOffset = 1
        }
    }

    private func startPulse() {
        withAnimation(
            Animation.easeInOut(duration: 1.2)
                .repeatForever(autoreverses: true)
        ) {
            pulseOpacity = 1.0
        }
    }
}

// MARK: - Preview

#Preview {
    MemoListSkeleton()
        .padding()
}

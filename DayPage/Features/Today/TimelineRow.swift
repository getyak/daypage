import SwiftUI

// MARK: - Timeline kakejiku spine — shared row scaffold + marker shapes
//
// One continuous museum spine runs through the whole Today timeline. Each row
// is a `52pt nameplate | content` layout; a marker shape centered on the spine
// encodes the granularity (dot → bar → ring → concentric) so the unit reads
// without words. Content floats on `bgWarm` — no card chrome, no rounded
// corners, no shadow.
//
// Design source of truth: .design-handoff/v8/app.jsx:630-720 +
// web/src/app/(app)/today/WeekFeedSpine.tsx (faithful web port).

// Spine x-coordinate inside a row's own coordinate space. Rows are a
// `52pt | gap(24) | content` layout, so the spine sits at the gap-center:
// 52 + 12 = 64 (app.jsx:654 `left: 52 + 12 - …`). The section wrapper places
// the continuous hairline at the same x (sectionPad 22 + 52 + 12 = 86).
private enum Spine {
    static let nameplateWidth: CGFloat = 52
    static let gap: CGFloat = 24
    /// Marker center, measured from the row's leading edge.
    static let x: CGFloat = nameplateWidth + gap / 2  // 64
    /// bg-warm halo that sits the marker on top of the hairline.
    static let halo: CGFloat = 4
}

// MARK: - Marker granularity

/// Shape encodes the time unit. Day = point, Week = span, Month/Year = ring.
enum TimelineMarker {
    /// Solid 7pt accent dot — a single day (app.jsx:654).
    case day
    /// Short 18×3pt accent bar — denotes a span (app.jsx:666).
    case week
    /// Hollow 11pt accent ring (1.6pt border) — a month (app.jsx:678).
    case month
    /// Concentric 15pt ring + 5pt inner dot — a year (app.jsx:691).
    case year
}

// MARK: - SpineMarker

/// A single marker centered on the spine, with a `bgWarm` halo so the hairline
/// reads as passing *behind* it. Self-positions horizontally on the spine; the
/// caller positions it vertically via each marker's design `top` inset.
private struct SpineMarker: View {

    let marker: TimelineMarker

    var body: some View {
        switch marker {
        case .day:
            dot(diameter: 7, top: 11)
        case .week:
            bar(width: 18, height: 3, top: 13)
        case .month:
            ring(diameter: 11, top: 9)
        case .year:
            concentric(diameter: 15, inner: 5, top: 7)
        }
    }

    // MARK: Shapes

    private func dot(diameter: CGFloat, top: CGFloat) -> some View {
        Circle()
            .fill(DSTokens.Colors.accent)
            .frame(width: diameter, height: diameter)
            .background(halo(Circle()))
            .offset(x: Spine.x - diameter / 2, y: top)
    }

    private func bar(width: CGFloat, height: CGFloat, top: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(DSTokens.Colors.accent)
            .frame(width: width, height: height)
            .background(halo(RoundedRectangle(cornerRadius: 2, style: .continuous)))
            .offset(x: Spine.x - width / 2, y: top)
    }

    private func ring(diameter: CGFloat, top: CGFloat) -> some View {
        Circle()
            .fill(DSTokens.Colors.bgWarm)
            .overlay(Circle().strokeBorder(DSTokens.Colors.accent, lineWidth: 1.6))
            .frame(width: diameter, height: diameter)
            .background(halo(Circle(), inset: 3))
            .offset(x: Spine.x - diameter / 2, y: top)
    }

    private func concentric(diameter: CGFloat, inner: CGFloat, top: CGFloat) -> some View {
        Circle()
            .fill(DSTokens.Colors.bgWarm)
            .overlay(Circle().strokeBorder(DSTokens.Colors.accent, lineWidth: 1.6))
            .overlay(Circle().fill(DSTokens.Colors.accent).frame(width: inner, height: inner))
            .frame(width: diameter, height: diameter)
            .background(halo(Circle(), inset: 3))
            .offset(x: Spine.x - diameter / 2, y: top)
    }

    /// bgWarm halo: a `shape` filled with bgWarm, padded outward so it peeks
    /// past the marker edges and masks the hairline running behind it.
    private func halo<S: Shape>(_ shape: S, inset: CGFloat = Spine.halo) -> some View {
        shape
            .fill(DSTokens.Colors.bgWarm)
            .padding(-inset)
    }
}

// MARK: - RowTitle / RowLede / RowMeta

/// Serif (fraunces) title. Size scales with granularity: 20/20/22/24pt for
/// day/week/month/year; letterSpacing tightens as it grows (app.jsx:655-695).
struct TimelineRowTitle: View {
    let text: String
    let size: CGFloat

    var body: some View {
        let tracking: CGFloat = size >= 24 ? -0.6 : (size >= 22 ? -0.5 : -0.4)
        Text(text)
            .font(DSFonts.serif(size: size, weight: .semibold))
            .tracking(tracking)
            .lineSpacing(size >= 24 ? 4 : 3)
            .foregroundColor(DSTokens.Colors.fgPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Body lede in inter at 0.85 opacity, clamped to 3 lines (app.jsx:656).
struct TimelineRowLede: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DSFonts.inter(size: 14))
            .tracking(0.1)
            .lineSpacing(4)
            .foregroundColor(DSTokens.Colors.fgPrimary.opacity(0.85))
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
    }
}

/// Footer: mono tags separated by `·`, then a right-aligned trailing slot
/// (word / entry counts). Mirrors `RowMeta` (app.jsx:702-719).
struct TimelineRowMeta<Trailing: View>: View {
    let tags: [String]
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                if index > 0 {
                    Text("·")
                        .font(DSFonts.jetBrainsMono(size: 9.5, weight: .bold))
                        .foregroundColor(DSTokens.Colors.fgSubtle.opacity(0.55))
                }
                Text(tag)
                    .font(DSFonts.jetBrainsMono(size: 9.5, weight: .bold))
                    .tracking(1.6)
                    .foregroundColor(DSTokens.Colors.fgSubtle)
            }
            Spacer(minLength: 12)
            trailing()
                .font(DSFonts.jetBrainsMono(size: 9.5, weight: .bold))
                .foregroundColor(DSTokens.Colors.fgMuted)
        }
        .padding(.top, 14)
    }
}

// MARK: - TimelineRow

/// Shared row scaffold: right-aligned nameplate column | spine marker | content.
/// `leftTop` is a mono granularity label (e.g. `MON`, `W·21`, `APR`, `YEAR`);
/// `leftBot` is a display/serif date or year. The marker overlays the gap
/// between nameplate and content, centered on the continuous spine.
///
/// Named `TimelineRowScaffold` to avoid colliding with the pre-existing
/// `TimelineRow` in TodayView.swift (a different, still-used view).
struct TimelineRowScaffold<Content: View>: View {

    let leftTop: String
    let leftBot: String?
    /// Serif for YEAR's big year label; display (Space Grotesk) otherwise.
    let leftBotSerif: Bool
    let marker: TimelineMarker
    let first: Bool
    let last: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: Spine.gap) {
            nameplate
                .frame(width: Spine.nameplateWidth, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
        }
        .padding(.top, first ? 0 : 26)
        .padding(.bottom, last ? 6 : 26)
        .overlay(alignment: .topLeading) {
            SpineMarker(marker: marker)
        }
    }

    // MARK: Nameplate (left column)

    private var nameplate: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(leftTop)
                .font(DSFonts.jetBrainsMono(size: 9.5, weight: .bold))
                .tracking(1.8)
                .foregroundColor(DSTokens.Colors.fgSubtle)
            if let leftBot {
                Text(leftBot)
                    .font(leftBotSerif
                        ? DSFonts.serif(size: 13, weight: .semibold)
                        : DSFonts.spaceGrotesk(size: 13, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundColor(DSTokens.Colors.fgPrimary)
            }
        }
        .padding(.top, 6)
    }
}

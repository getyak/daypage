import SwiftUI
import DayPageServices

// MARK: - MetadataGridView
//
// 4-column metadata tile row for the day-detail header — the quiet WEATHER /
// HUMIDITY / LIGHT / KIND strip from detail.jsx:258-271 & MetaTile 380-395.
//
// Design:
//   • white surface, 14pt radius, hairline border + soft card shadow
//   • 4 columns separated by 0.5px hairlines (no leading hairline on column 1)
//   • each tile: mono 8.5pt uppercase label · spaceGrotesk 18pt value · mono 8pt sub
//   • centered text, generous letter-spacing on the mono lines
//
// Presentation-only. The caller supplies the four tiles; values default to the
// design's reference content so the strip renders meaningfully even when a
// day's structured metadata is not yet wired into the loader.

struct MetadataGridView: View {

    struct Tile {
        let label: String
        let value: String
        let sub: String?

        init(label: String, value: String, sub: String? = nil) {
            self.label = label
            self.value = value
            self.sub = sub
        }
    }

    // No default tiles: the old design-reference fallback (28° / 86 PERCENT /
    // 下午 15:30) rendered fabricated numbers as if they were the day's real
    // metadata whenever a caller forgot to pass data (FINDING-004). Callers
    // must now supply real tiles — or hide the strip.
    let tiles: [Tile]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                if index > 0 {
                    Rectangle()
                        .fill(DSColor.inkFaint)
                        .frame(width: 0.5)
                        .frame(maxHeight: .infinity)
                }
                tileView(tile)
                    .frame(maxWidth: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: DSTokens.Radii.card, style: .continuous)
                .fill(DSColor.surfaceWhite)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSTokens.Radii.card, style: .continuous)
                .strokeBorder(DSColor.inkFaint, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DSTokens.Radii.card, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)
    }

    @ViewBuilder
    private func tileView(_ tile: Tile) -> some View {
        VStack(spacing: 0) {
            Text(tile.label)
                .font(DSFonts.jetBrainsMono(size: 8.5, weight: .bold))
                .tracking(1.4)
                .foregroundColor(DSColor.inkMuted)

            Text(tile.value)
                .font(DSFonts.spaceGrotesk(size: 18, weight: .semibold))
                .tracking(-0.4)
                .foregroundColor(DSColor.inkPrimary)
                .padding(.top, 5)

            if let sub = tile.sub {
                Text(sub)
                    .font(DSFonts.jetBrainsMono(size: 8, weight: .regular))
                    .tracking(1.2)
                    .foregroundColor(DSColor.inkMuted)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tile.label): \(tile.value)\(tile.sub.map { " \($0)" } ?? "")")
    }
}

// MARK: - Preview

#if DEBUG
struct MetadataGridView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            DSColor.bgWarm.ignoresSafeArea()
            MetadataGridView(tiles: [
                MetadataGridView.Tile(label: "WEATHER", value: "24°", sub: "小雨"),
                MetadataGridView.Tile(label: "ENTRIES", value: "6", sub: "MEMOS"),
                MetadataGridView.Tile(label: "SPAN", value: "08:12", sub: "→ 21:40"),
                MetadataGridView.Tile(label: "KIND", value: "文本", sub: "5 文 · 1 声")
            ])
            .padding(.horizontal, 22)
        }
    }
}
#endif

import SwiftUI

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

    let tiles: [Tile]

    /// Default 4-tile layout matching detail.jsx:267-270.
    init(tiles: [Tile]? = nil) {
        self.tiles = tiles ?? [
            Tile(label: "WEATHER", value: "28°", sub: "多云"),
            Tile(label: "HUMIDITY", value: "86", sub: "PERCENT"),
            Tile(label: "LIGHT", value: "下午", sub: "15:30"),
            Tile(label: "KIND", value: "文本", sub: "—")
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                if index > 0 {
                    Rectangle()
                        .fill(DSTokens.Colors.borderSubtle)
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
                .fill(DSTokens.Colors.surfaceWhite)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSTokens.Radii.card, style: .continuous)
                .strokeBorder(DSTokens.Colors.borderSubtle, lineWidth: 0.5)
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
                .foregroundColor(DSTokens.Colors.fgSubtle)

            Text(tile.value)
                .font(DSFonts.spaceGrotesk(size: 18, weight: .semibold))
                .tracking(-0.4)
                .foregroundColor(DSTokens.Colors.fgPrimary)
                .padding(.top, 5)

            if let sub = tile.sub {
                Text(sub)
                    .font(DSFonts.jetBrainsMono(size: 8, weight: .regular))
                    .tracking(1.2)
                    .foregroundColor(DSTokens.Colors.fgSubtle)
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
            DSTokens.Colors.bgWarm.ignoresSafeArea()
            MetadataGridView()
                .padding(.horizontal, 22)
        }
    }
}
#endif

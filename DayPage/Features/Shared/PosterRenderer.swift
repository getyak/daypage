import UIKit

// MARK: - PosterRenderer
//
// Renders a brand share-card using CoreGraphics directly.
// Avoids ImageRenderer / UIHostingController which both fail on iOS 26 simulator
// when custom fonts are involved.

enum PosterRenderer {

    static func render(
        monthTitle: String,
        totalEntries: Int,
        totalPhotos: Int,
        totalVoiceMinutes: Int,
        totalLocations: Int
    ) -> UIImage {
        let width: CGFloat = 390
        let scale: CGFloat = 3

        // --- Layout constants ---
        let hPad: CGFloat = 24
        let topPad: CGFloat = 28
        let dividerH: CGFloat = 1
        let rowPad: CGFloat = 20

        // Colors
        let bgColor = UIColor(red: 0.976, green: 0.976, blue: 0.976, alpha: 1)
        let textColor = UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
        let mutedColor = UIColor(red: 0.53, green: 0.53, blue: 0.53, alpha: 1)
        let accentColor = UIColor(red: 0.545, green: 0.435, blue: 0.306, alpha: 1)
        let dividerColor = UIColor(red: 0.878, green: 0.878, blue: 0.878, alpha: 1)
        let watermarkColor = UIColor(red: 0.733, green: 0.733, blue: 0.733, alpha: 1)

        // Fonts
        let brandFont = UIFont.systemFont(ofSize: 18, weight: .bold)
        let monoSmFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let labelFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let numFont = UIFont.systemFont(ofSize: 40, weight: .bold)
        let unitFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let waterFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        // --- First pass: measure height ---
        let headerH: CGFloat = 56   // top+bottom padding + one line
        let statsH: CGFloat = rowPad * 2 + 56 * 2 + 28 * 2  // 2 rows × (num+label)
        let footerH: CGFloat = 16 * 2 + 14  // padding + line
        let totalH = topPad + headerH + dividerH + 28 + statsH + 28 + dividerH + footerH

        let size = CGSize(width: width, height: totalH)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let image = renderer.image { ctx in
            let context = ctx.cgContext

            // Background
            bgColor.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            var y: CGFloat = topPad

            // --- DAYPAGE brand ---
            let brandAttrs: [NSAttributedString.Key: Any] = [
                .font: brandFont,
                .foregroundColor: textColor,
                .kern: 2
            ]
            let brandStr = NSAttributedString(string: "DAYPAGE", attributes: brandAttrs)
            brandStr.draw(at: CGPoint(x: hPad, y: y))

            // Month title (right aligned)
            let monoAttrs: [NSAttributedString.Key: Any] = [
                .font: monoSmFont,
                .foregroundColor: mutedColor
            ]
            let monthStr = NSAttributedString(string: monthTitle, attributes: monoAttrs)
            let monthSize = monthStr.size()
            monthStr.draw(at: CGPoint(x: width - hPad - monthSize.width, y: y + 4))

            y += headerH - 8

            // --- Top divider ---
            dividerColor.setFill()
            context.fill(CGRect(x: hPad, y: y, width: width - hPad * 2, height: dividerH))
            y += dividerH + 28

            // --- Stats grid: 2×2 ---
            let stats: [(label: String, value: String, unit: String?)] = [
                ("ENTRIES", "\(totalEntries)", nil),
                ("PHOTOS", "\(totalPhotos)", nil),
                ("VOICE", "\(totalVoiceMinutes)", "MIN"),
                ("LOCATIONS", "\(totalLocations)", nil)
            ]
            let colW = (width - hPad * 2) / 2

            for row in 0..<2 {
                let rowY = y + CGFloat(row) * (rowPad * 2 + 56)
                for col in 0..<2 {
                    let idx = row * 2 + col
                    let cellX = hPad + CGFloat(col) * colW
                    var cellY = rowY

                    // Label
                    let labelAttrs: [NSAttributedString.Key: Any] = [
                        .font: labelFont,
                        .foregroundColor: mutedColor,
                        .kern: 0.5
                    ]
                    let labelStr = NSAttributedString(string: stats[idx].label, attributes: labelAttrs)
                    labelStr.draw(at: CGPoint(x: cellX, y: cellY))
                    cellY += labelFont.lineHeight + 6

                    // Value
                    let numAttrs: [NSAttributedString.Key: Any] = [
                        .font: numFont,
                        .foregroundColor: accentColor
                    ]
                    let numStr = NSAttributedString(string: stats[idx].value, attributes: numAttrs)
                    numStr.draw(at: CGPoint(x: cellX, y: cellY))

                    // Unit (if any)
                    if let unit = stats[idx].unit {
                        let numW = numStr.size().width
                        let unitAttrs: [NSAttributedString.Key: Any] = [
                            .font: unitFont,
                            .foregroundColor: mutedColor
                        ]
                        let unitStr = NSAttributedString(string: unit, attributes: unitAttrs)
                        unitStr.draw(at: CGPoint(x: cellX + numW + 4, y: cellY + numFont.lineHeight - unitFont.lineHeight))
                    }
                }
            }

            y += rowPad * 2 + 56 * 2 + 28

            // --- Bottom divider ---
            dividerColor.setFill()
            context.fill(CGRect(x: hPad, y: y, width: width - hPad * 2, height: dividerH))
            y += dividerH + 16

            // --- Watermark ---
            let wmAttrs: [NSAttributedString.Key: Any] = [
                .font: waterFont,
                .foregroundColor: watermarkColor,
                .kern: 1
            ]
            let wmStr = NSAttributedString(string: "daypage.app", attributes: wmAttrs)
            let wmSize = wmStr.size()
            wmStr.draw(at: CGPoint(x: (width - wmSize.width) / 2, y: y))
        }

        return image
    }
}

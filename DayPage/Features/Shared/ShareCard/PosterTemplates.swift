import UIKit

// MARK: - PosterTemplates
//
// Concrete renderers for each (PosterStyle, SharePayload) pair. Eight templates
// total: 2 styles × 4 content types. Each template is a pure function that
// takes a typed snapshot and returns a UIImage.
//
// Notes that apply to every template:
//
// • Width fixed at 1080pt — the de-facto standard for portrait share images on
//   小红书 / Twitter / 微信. Wider gets downsampled; 1080 keeps text crisp.
// • Height is computed AFTER laying out the body text so cards always fit
//   their content. Each template clamps a minimum.
// • Fonts: `UIFont.systemFont` and `UIFont.monospacedSystemFont` ONLY. Custom
//   TTFs fail in off-screen graphics contexts on iOS 26 simulator
//   (documented in the original `PosterRenderer.swift` header). System fonts
//   render reliably across simulator + device.
// • Contrast: ink-on-bg pairs are checked for ≥ WCAG AA (4.5:1) at body
//   weight, ≥ 3:1 at title weight.

// MARK: - Palettes

private enum MinimalPalette {
    static let bg          = UIColor(red: 0.980, green: 0.969, blue: 0.949, alpha: 1)
    static let ink         = UIColor(red: 0.141, green: 0.106, blue: 0.063, alpha: 1)
    static let inkMuted    = UIColor(red: 0.141, green: 0.106, blue: 0.063, alpha: 0.62)
    static let inkFaint    = UIColor(red: 0.141, green: 0.106, blue: 0.063, alpha: 0.18)
    static let accent      = UIColor(red: 0.659, green: 0.329, blue: 0.106, alpha: 1)
    static let accentDeep  = UIColor(red: 0.365, green: 0.188, blue: 0.000, alpha: 1)
}

private enum PolaroidPalette {
    static let paper         = UIColor(red: 0.992, green: 0.985, blue: 0.970, alpha: 1)
    static let paperShadow   = UIColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 0.08)
    static let frame         = UIColor.white
    static let ink           = UIColor(red: 0.106, green: 0.090, blue: 0.067, alpha: 1)
    static let pencil        = UIColor(red: 0.247, green: 0.220, blue: 0.196, alpha: 1)
    static let inkMuted      = UIColor(red: 0.106, green: 0.090, blue: 0.067, alpha: 0.55)
    static let accent        = UIColor(red: 0.745, green: 0.420, blue: 0.165, alpha: 1)
    static let placeholderBg = UIColor(red: 0.910, green: 0.890, blue: 0.855, alpha: 1)
}

private enum CardGeom {
    static let width: CGFloat = 1080
    static let inset: CGFloat = 72
    static let scale: CGFloat = 1
}

// MARK: - Helpers

private extension NSAttributedString {
    func measure(width: CGFloat) -> CGRect {
        boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
    }
}

private extension UIFont {
    static func editorialTitle(size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: .heavy)
        if let desc = base.fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: desc, size: size)
        }
        return base
    }
}

private func truncate(_ s: String, to n: Int) -> String {
    guard s.count > n else { return s }
    let end = s.index(s.startIndex, offsetBy: n)
    return String(s[..<end]) + "\u{2026}"
}

private func fillRoundedRect(_ rect: CGRect, radius: CGFloat, color: UIColor, in ctx: CGContext) {
    ctx.saveGState()
    color.setFill()
    UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
    ctx.restoreGState()
}

private func drawAspectFill(_ image: UIImage, in rect: CGRect, ctx: CGContext) {
    ctx.saveGState()
    UIBezierPath(rect: rect).addClip()
    let imgRatio = image.size.width / image.size.height
    let rectRatio = rect.width / rect.height
    var drawRect = rect
    if imgRatio > rectRatio {
        let w = rect.height * imgRatio
        drawRect = CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: rect.height)
    } else {
        let h = rect.width / imgRatio
        drawRect = CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
    }
    image.draw(in: drawRect)
    ctx.restoreGState()
}

private func headerDate(from date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy·MM·dd"
    return f.string(from: date)
}

private func headerTime(from date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: date)
}

private func handwrittenDate(from date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "MMM d, yyyy"
    return f.string(from: date)
}

private func parseDailyDate(_ s: String) -> Date {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: s) ?? Date()
}

private func imageFormat1x() -> UIGraphicsImageRendererFormat {
    let f = UIGraphicsImageRendererFormat()
    f.scale = CardGeom.scale
    f.opaque = true
    return f
}

// MARK: - Minimal shared chrome

private func drawMinimalHeader(at origin: CGPoint, width: CGFloat, rightText: String, ctx: CGContext) {
    let brand = NSAttributedString(string: "DAYPAGE", attributes: [
        .font: UIFont.systemFont(ofSize: 38, weight: .heavy),
        .foregroundColor: MinimalPalette.ink,
        .kern: 6
    ])
    brand.draw(at: origin)

    let right = NSAttributedString(string: rightText, attributes: [
        .font: UIFont.monospacedSystemFont(ofSize: 24, weight: .regular),
        .foregroundColor: MinimalPalette.inkMuted,
        .kern: 1.5
    ])
    let rsize = right.size()
    right.draw(at: CGPoint(x: origin.x + width - rsize.width, y: origin.y + 12))

    MinimalPalette.inkFaint.setFill()
    ctx.fill(CGRect(x: origin.x, y: origin.y + 80, width: width, height: 2))
}

private func drawMinimalFooter(in size: CGSize, ctx: CGContext) {
    let inset = CardGeom.inset
    let y = size.height - inset - 40
    MinimalPalette.inkFaint.setFill()
    ctx.fill(CGRect(x: inset, y: y - 32, width: size.width - inset * 2, height: 2))
    let wm = NSAttributedString(string: "daypage.app", attributes: [
        .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
        .foregroundColor: MinimalPalette.inkMuted,
        .kern: 3
    ])
    let wmSize = wm.size()
    wm.draw(at: CGPoint(x: (size.width - wmSize.width) / 2, y: y))
}

private func drawMinimalMetaRow(at origin: CGPoint, width: CGFloat,
                                 location: String?, weather: String?, time: String,
                                 ctx: CGContext) {
    var parts: [String] = []
    if let l = location, !l.isEmpty { parts.append(l) }
    if let w = weather, !w.isEmpty { parts.append(w) }
    parts.append(time)
    let text = parts.joined(separator: "  ·  ").uppercased()
    let attr = NSAttributedString(string: truncate(text, to: 80), attributes: [
        .font: UIFont.monospacedSystemFont(ofSize: 24, weight: .regular),
        .foregroundColor: MinimalPalette.inkMuted,
        .kern: 1.5
    ])
    attr.draw(at: origin)
}

private func drawVoicePill(at origin: CGPoint, seconds: Double, ctx: CGContext) {
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    let text = String(format: "▶ VOICE %d:%02d", mins, secs)
    let attr = NSAttributedString(string: text, attributes: [
        .font: UIFont.monospacedSystemFont(ofSize: 24, weight: .medium),
        .foregroundColor: MinimalPalette.accentDeep,
        .kern: 1.5
    ])
    let size = attr.size()
    let pillRect = CGRect(x: origin.x, y: origin.y, width: size.width + 56, height: 56)
    fillRoundedRect(pillRect, radius: 28, color: MinimalPalette.accent.withAlphaComponent(0.10), in: ctx)
    attr.draw(at: CGPoint(x: pillRect.minX + 28, y: pillRect.minY + 14))
}

// MARK: - MinimalMemoTemplate

enum MinimalMemoTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .memo(let s) = payload else { return UIImage() }
        return draw(s)
    }

    private static func draw(_ s: MemoSnapshot) -> UIImage {
        let W = CardGeom.width
        let inset = CardGeom.inset

        let body = truncate(s.body.trimmingCharacters(in: .whitespacesAndNewlines), to: 360)
        let bodyFont = UIFont.systemFont(ofSize: 46, weight: .regular)
        let bodyPara = NSMutableParagraphStyle()
        bodyPara.lineHeightMultiple = 1.32
        let bodyAttr = NSAttributedString(string: body, attributes: [
            .font: bodyFont,
            .foregroundColor: MinimalPalette.ink,
            .paragraphStyle: bodyPara
        ])
        let bodyMeasure = bodyAttr.measure(width: W - inset * 2)

        let coverH: CGFloat = s.coverImage != nil ? 540 : 0
        let coverGap: CGFloat = coverH > 0 ? 56 : 0
        let hasVoice = (s.voiceDurationSeconds ?? 0) > 0
        let voiceH: CGFloat = hasVoice ? 96 : 0
        let voiceGap: CGFloat = hasVoice ? 32 : 0

        let totalH =
            inset + 96 + 64 +
            coverH + coverGap +
            ceil(bodyMeasure.height) +
            voiceGap + voiceH +
            80 + 80 +
            96 + 80

        let size = CGSize(width: W, height: max(1200, totalH))
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat1x())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            MinimalPalette.bg.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            var y = inset

            drawMinimalHeader(at: CGPoint(x: inset, y: y),
                               width: W - inset * 2,
                               rightText: headerDate(from: s.createdAt),
                               ctx: cg)
            y += 96 + 64

            if let cover = s.coverImage {
                let coverRect = CGRect(x: inset, y: y, width: W - inset * 2, height: coverH)
                drawAspectFill(cover, in: coverRect, ctx: cg)
                cg.setStrokeColor(MinimalPalette.inkFaint.cgColor)
                cg.setLineWidth(2)
                cg.stroke(coverRect)
                y += coverH + coverGap
            }

            bodyAttr.draw(with: CGRect(x: inset, y: y, width: W - inset * 2, height: bodyMeasure.height),
                          options: [.usesLineFragmentOrigin], context: nil)
            y += ceil(bodyMeasure.height)

            if hasVoice, let dur = s.voiceDurationSeconds {
                y += voiceGap
                drawVoicePill(at: CGPoint(x: inset, y: y), seconds: dur, ctx: cg)
                y += voiceH
            }

            y += 80
            drawMinimalMetaRow(at: CGPoint(x: inset, y: y),
                                width: W - inset * 2,
                                location: s.locationName,
                                weather: s.weather,
                                time: headerTime(from: s.createdAt),
                                ctx: cg)

            drawMinimalFooter(in: size, ctx: cg)
        }
    }
}

// MARK: - MinimalDailyTemplate

enum MinimalDailyTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .daily(let s) = payload else { return UIImage() }
        return draw(s)
    }

    private static func draw(_ s: DailySnapshot) -> UIImage {
        let W = CardGeom.width
        let inset = CardGeom.inset

        let dateAttr = NSAttributedString(
            string: s.dateString,
            attributes: [
                .font: UIFont.editorialTitle(size: 140),
                .foregroundColor: MinimalPalette.ink,
                .kern: -2
            ])
        let weekdayAttr = NSAttributedString(
            string: s.weekday,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 28, weight: .regular),
                .foregroundColor: MinimalPalette.inkMuted,
                .kern: 4
            ])

        let summaryText = truncate(s.summary, to: 220)
        let summaryFont = UIFont.systemFont(ofSize: 40, weight: .regular)
        let summaryPara = NSMutableParagraphStyle()
        summaryPara.lineHeightMultiple = 1.35
        let summaryAttr = NSAttributedString(string: summaryText, attributes: [
            .font: summaryFont,
            .foregroundColor: MinimalPalette.ink,
            .paragraphStyle: summaryPara
        ])
        let summaryMeasure = summaryAttr.measure(width: W - inset * 2)
        let highlightsBlockH: CGFloat = s.highlights.isEmpty ? 0 : CGFloat(s.highlights.count) * 76 + 48

        let baseH = inset + 320 + 64 +
                    ceil(summaryMeasure.height) + 80 +
                    highlightsBlockH + 80 +
                    80 + 96 + 80

        let size = CGSize(width: W, height: max(1400, baseH))
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat1x())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            MinimalPalette.bg.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            var y = inset

            drawMinimalHeader(at: CGPoint(x: inset, y: y),
                               width: W - inset * 2,
                               rightText: "DAILY PAGE",
                               ctx: cg)
            y += 96 + 56

            weekdayAttr.draw(at: CGPoint(x: inset, y: y))
            y += 48
            dateAttr.draw(at: CGPoint(x: inset, y: y))
            y += 168

            MinimalPalette.inkFaint.setFill()
            cg.fill(CGRect(x: inset, y: y, width: W - inset * 2, height: 2))
            y += 56

            summaryAttr.draw(with: CGRect(x: inset, y: y, width: W - inset * 2, height: summaryMeasure.height),
                             options: [.usesLineFragmentOrigin], context: nil)
            y += ceil(summaryMeasure.height) + 56

            if !s.highlights.isEmpty {
                for (idx, item) in s.highlights.enumerated() {
                    let num = NSAttributedString(
                        string: String(format: "%02d", idx + 1),
                        attributes: [
                            .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                            .foregroundColor: MinimalPalette.accent,
                            .kern: 1
                        ])
                    num.draw(at: CGPoint(x: inset, y: y + 6))

                    let title = NSAttributedString(
                        string: truncate(item, to: 60),
                        attributes: [
                            .font: UIFont.systemFont(ofSize: 30, weight: .medium),
                            .foregroundColor: MinimalPalette.ink
                        ])
                    title.draw(at: CGPoint(x: inset + 70, y: y))
                    y += 60

                    if idx < s.highlights.count - 1 {
                        MinimalPalette.inkFaint.setFill()
                        cg.fill(CGRect(x: inset + 70, y: y, width: W - inset * 2 - 70, height: 1))
                        y += 16
                    }
                }
                y += 48
            }

            let statsLineY = y + 16
            let countAttr = NSAttributedString(
                string: "\(s.memoCount) ENTRIES",
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                    .foregroundColor: MinimalPalette.inkMuted,
                    .kern: 1.5
                ])
            countAttr.draw(at: CGPoint(x: inset, y: statsLineY))

            if !s.locationPrimary.isEmpty {
                let locAttr = NSAttributedString(
                    string: truncate(s.locationPrimary.uppercased(), to: 26),
                    attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                        .foregroundColor: MinimalPalette.inkMuted,
                        .kern: 1.5
                    ])
                let lw = locAttr.size().width
                locAttr.draw(at: CGPoint(x: W - inset - lw, y: statsLineY))
            }

            drawMinimalFooter(in: size, ctx: cg)
        }
    }
}

// MARK: - MinimalMonthlyTemplate

enum MinimalMonthlyTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .monthly(let s) = payload else { return UIImage() }
        return draw(s)
    }

    private static func draw(_ s: MonthlySnapshot) -> UIImage {
        let W = CardGeom.width
        let inset = CardGeom.inset

        let size = CGSize(width: W, height: 1400)
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat1x())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            MinimalPalette.bg.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            var y = inset

            drawMinimalHeader(at: CGPoint(x: inset, y: y),
                               width: W - inset * 2,
                               rightText: s.monthTitle,
                               ctx: cg)
            y += 96 + 88

            let titleStr = NSMutableAttributedString(string: "THE\nMONTH\nIN\nREVIEW", attributes: [
                .font: UIFont.editorialTitle(size: 110),
                .foregroundColor: MinimalPalette.ink,
                .kern: -1
            ])
            let para = NSMutableParagraphStyle()
            para.lineHeightMultiple = 0.95
            titleStr.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: titleStr.length))
            titleStr.draw(with: CGRect(x: inset, y: y, width: W - inset * 2, height: 500),
                          options: [.usesLineFragmentOrigin], context: nil)
            y += 480

            MinimalPalette.inkFaint.setFill()
            cg.fill(CGRect(x: inset, y: y, width: W - inset * 2, height: 2))
            y += 72

            let cellW = (W - inset * 2) / 2
            let stats: [(String, String, String?)] = [
                ("ENTRIES",  "\(s.totalEntries)",  nil),
                ("PHOTOS",   "\(s.totalPhotos)",   nil),
                ("VOICE",    "\(s.totalVoiceMinutes)", "MIN"),
                ("LOCATIONS","\(s.totalLocations)", nil)
            ]
            for (i, stat) in stats.enumerated() {
                let row = i / 2
                let col = i % 2
                let cx = inset + CGFloat(col) * cellW
                let cy = y + CGFloat(row) * 220

                let label = NSAttributedString(string: stat.0, attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                    .foregroundColor: MinimalPalette.inkMuted,
                    .kern: 2
                ])
                label.draw(at: CGPoint(x: cx, y: cy))

                let value = NSAttributedString(string: stat.1, attributes: [
                    .font: UIFont.systemFont(ofSize: 110, weight: .bold),
                    .foregroundColor: MinimalPalette.accentDeep
                ])
                value.draw(at: CGPoint(x: cx, y: cy + 44))

                if let unit = stat.2 {
                    let valW = value.size().width
                    let unitAttr = NSAttributedString(string: unit, attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                        .foregroundColor: MinimalPalette.inkMuted,
                        .kern: 1.5
                    ])
                    unitAttr.draw(at: CGPoint(x: cx + valW + 16, y: cy + 130))
                }
            }

            drawMinimalFooter(in: size, ctx: cg)
        }
    }
}

// MARK: - MinimalQuoteTemplate

enum MinimalQuoteTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .quote(let s) = payload else { return UIImage() }
        return draw(s)
    }

    private static func draw(_ s: QuoteSnapshot) -> UIImage {
        let W = CardGeom.width
        let inset = CardGeom.inset

        let bodyText = truncate(s.text.trimmingCharacters(in: .whitespacesAndNewlines), to: 240)
        let quoteFontSize: CGFloat
        switch bodyText.count {
        case 0..<80:    quoteFontSize = 64
        case 80..<160:  quoteFontSize = 52
        default:        quoteFontSize = 44
        }
        let quoteFont = UIFont.systemFont(ofSize: quoteFontSize, weight: .regular)
        let quotePara = NSMutableParagraphStyle()
        quotePara.lineHeightMultiple = 1.35
        let quoteAttr = NSAttributedString(string: bodyText, attributes: [
            .font: quoteFont,
            .foregroundColor: MinimalPalette.ink,
            .paragraphStyle: quotePara
        ])
        let quoteMeasure = quoteAttr.measure(width: W - inset * 2)

        let totalH = inset + 96 + 88 + 160 + ceil(quoteMeasure.height) + 88 + 120 + inset
        let size = CGSize(width: W, height: max(1100, totalH))
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat1x())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            MinimalPalette.bg.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            var y = inset

            drawMinimalHeader(at: CGPoint(x: inset, y: y),
                               width: W - inset * 2,
                               rightText: "QUOTE",
                               ctx: cg)
            y += 96 + 64

            let openQuote = NSAttributedString(string: "\u{201C}", attributes: [
                .font: UIFont.editorialTitle(size: 220),
                .foregroundColor: MinimalPalette.accent
            ])
            openQuote.draw(at: CGPoint(x: inset - 10, y: y - 40))
            y += 140

            quoteAttr.draw(with: CGRect(x: inset, y: y, width: W - inset * 2, height: quoteMeasure.height),
                           options: [.usesLineFragmentOrigin], context: nil)
            y += ceil(quoteMeasure.height) + 64

            let ruleW: CGFloat = 80
            MinimalPalette.inkMuted.setFill()
            cg.fill(CGRect(x: inset, y: y + 18, width: ruleW, height: 2))

            let attribAttr = NSAttributedString(
                string: truncate(s.attribution, to: 70),
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                    .foregroundColor: MinimalPalette.inkMuted,
                    .kern: 1.5
                ])
            attribAttr.draw(at: CGPoint(x: inset + ruleW + 24, y: y + 6))

            drawMinimalFooter(in: size, ctx: cg)
        }
    }
}

// MARK: - PolaroidMemoTemplate

enum PolaroidMemoTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .memo(let s) = payload else { return UIImage() }
        return draw(s)
    }

    private static func draw(_ s: MemoSnapshot) -> UIImage {
        let W = CardGeom.width
        let outerInset: CGFloat = 64
        let frameLeft: CGFloat = outerInset
        let frameRight: CGFloat = W - outerInset
        let frameWidth = frameRight - frameLeft

        let photoTop: CGFloat = outerInset + 80
        let photoSide: CGFloat = 64
        let photoX = frameLeft + photoSide
        let photoW = frameWidth - photoSide * 2
        let photoH = photoW   // square photo

        let captionText = truncate(s.body.trimmingCharacters(in: .whitespacesAndNewlines), to: 180)
        let captionFont = UIFont.systemFont(ofSize: 40, weight: .regular)
        let captionPara = NSMutableParagraphStyle()
        captionPara.lineHeightMultiple = 1.32
        let captionAttr = NSAttributedString(string: captionText, attributes: [
            .font: captionFont,
            .foregroundColor: PolaroidPalette.ink,
            .paragraphStyle: captionPara
        ])
        let captionMeasure = captionAttr.measure(width: photoW)

        let captionBlock = ceil(captionMeasure.height) + 24
        let metaBlock: CGFloat = 96
        let dateBlock: CGFloat = 100
        let frameBottomPad: CGFloat = 88
        let frameHeight = (photoTop - frameLeft) + photoH + 56 + captionBlock + 32 + metaBlock + dateBlock + frameBottomPad
        let totalH = photoTop + photoH + 56 + captionBlock + 32 + metaBlock + dateBlock + frameBottomPad + outerInset

        let size = CGSize(width: W, height: totalH)
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat1x())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            PolaroidPalette.paper.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            // Subtle paper grain — horizontal stripes
            cg.saveGState()
            PolaroidPalette.frame.withAlphaComponent(0.025).setFill()
            for i in stride(from: -W, to: size.height + W, by: 14) {
                cg.fill(CGRect(x: 0, y: i, width: size.width, height: 2))
            }
            cg.restoreGState()

            // Polaroid frame with shadow
            let frameRect = CGRect(x: frameLeft, y: outerInset, width: frameWidth, height: frameHeight)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 20), blur: 40, color: PolaroidPalette.paperShadow.cgColor)
            fillRoundedRect(frameRect, radius: 8, color: PolaroidPalette.frame, in: cg)
            cg.restoreGState()

            // Photo
            let photoRect = CGRect(x: photoX, y: photoTop, width: photoW, height: photoH)
            if let cover = s.coverImage {
                drawAspectFill(cover, in: photoRect, ctx: cg)
            } else {
                PolaroidPalette.placeholderBg.setFill()
                cg.fill(photoRect)
                let initial = s.body.first.map { String($0) } ?? "·"
                let initAttr = NSAttributedString(string: initial, attributes: [
                    .font: UIFont.editorialTitle(size: 320),
                    .foregroundColor: PolaroidPalette.ink.withAlphaComponent(0.20)
                ])
                let isz = initAttr.size()
                initAttr.draw(at: CGPoint(x: photoRect.midX - isz.width / 2,
                                           y: photoRect.midY - isz.height / 2))
            }

            var y = photoRect.maxY + 56

            // Italic caption
            let italicFont: UIFont = {
                let desc = UIFontDescriptor(name: captionFont.fontName, size: captionFont.pointSize)
                    .withSymbolicTraits(.traitItalic)
                return desc.flatMap { UIFont(descriptor: $0, size: captionFont.pointSize) } ?? captionFont
            }()
            let italicCaption = NSAttributedString(string: captionText, attributes: [
                .font: italicFont,
                .foregroundColor: PolaroidPalette.ink,
                .paragraphStyle: captionPara
            ])
            italicCaption.draw(with: CGRect(x: photoX, y: y, width: photoW, height: captionMeasure.height),
                               options: [.usesLineFragmentOrigin], context: nil)
            y += ceil(captionMeasure.height) + 32

            // Meta
            var metaParts: [String] = []
            if let l = s.locationName, !l.isEmpty { metaParts.append(l) }
            if let w = s.weather, !w.isEmpty { metaParts.append(w) }
            if (s.voiceDurationSeconds ?? 0) > 0 {
                metaParts.append("VOICE \(Int((s.voiceDurationSeconds ?? 0) / 60))′")
            }
            let metaText = metaParts.joined(separator: " · ").uppercased()
            let metaAttr = NSAttributedString(string: truncate(metaText, to: 60), attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                .foregroundColor: PolaroidPalette.inkMuted,
                .kern: 2
            ])
            metaAttr.draw(at: CGPoint(x: photoX, y: y))
            y += 56

            // Big handwritten date
            let dateAttr = NSAttributedString(
                string: handwrittenDate(from: s.createdAt),
                attributes: [
                    .font: UIFont.editorialTitle(size: 56),
                    .foregroundColor: PolaroidPalette.pencil
                ])
            dateAttr.draw(at: CGPoint(x: photoX, y: y + 16))

            // Watermark
            let wm = NSAttributedString(string: "daypage.app", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 20, weight: .regular),
                .foregroundColor: PolaroidPalette.inkMuted.withAlphaComponent(0.7),
                .kern: 1.5
            ])
            let wmSize = wm.size()
            wm.draw(at: CGPoint(x: frameRect.maxX - photoSide - wmSize.width, y: y + 40))
        }
    }
}

// MARK: - PolaroidDailyTemplate

enum PolaroidDailyTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .daily(let s) = payload else { return UIImage() }
        return draw(s)
    }

    private static func draw(_ s: DailySnapshot) -> UIImage {
        let W = CardGeom.width
        let outerInset: CGFloat = 64
        let frameLeft = outerInset
        let frameWidth = W - outerInset * 2
        let frameTop = outerInset
        let photoSide: CGFloat = 64
        let photoX = frameLeft + photoSide
        let photoW = frameWidth - photoSide * 2
        let photoH: CGFloat = 620
        let photoTop = frameTop + 80

        let summaryText = truncate(s.summary, to: 160)
        let summaryFont = UIFont.systemFont(ofSize: 38, weight: .regular)
        let summaryPara = NSMutableParagraphStyle()
        summaryPara.lineHeightMultiple = 1.30
        let italicFont: UIFont = {
            let d = UIFontDescriptor(name: summaryFont.fontName, size: summaryFont.pointSize)
                .withSymbolicTraits(.traitItalic)
            return d.flatMap { UIFont(descriptor: $0, size: summaryFont.pointSize) } ?? summaryFont
        }()
        let summaryAttr = NSAttributedString(string: summaryText, attributes: [
            .font: italicFont,
            .foregroundColor: PolaroidPalette.ink,
            .paragraphStyle: summaryPara
        ])
        let summaryMeasure = summaryAttr.measure(width: photoW)

        let captionBlock = ceil(summaryMeasure.height) + 24
        let highlightsBlock: CGFloat = s.highlights.isEmpty ? 0 : CGFloat(s.highlights.count) * 60 + 24
        let dateBlock: CGFloat = 110
        let frameBottomPad: CGFloat = 96
        let frameHeight = 80 + photoH + 56 + captionBlock + 32 + highlightsBlock + 32 + dateBlock + frameBottomPad
        let totalH = frameTop + frameHeight + outerInset

        let size = CGSize(width: W, height: totalH)
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat1x())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            PolaroidPalette.paper.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            let frameRect = CGRect(x: frameLeft, y: frameTop, width: frameWidth, height: frameHeight)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 24), blur: 48, color: PolaroidPalette.paperShadow.cgColor)
            fillRoundedRect(frameRect, radius: 8, color: PolaroidPalette.frame, in: cg)
            cg.restoreGState()

            let photoRect = CGRect(x: photoX, y: photoTop, width: photoW, height: photoH)
            if let cover = s.coverImage {
                drawAspectFill(cover, in: photoRect, ctx: cg)
            } else {
                PolaroidPalette.placeholderBg.setFill()
                cg.fill(photoRect)

                let dateHero = NSAttributedString(string: s.dateString, attributes: [
                    .font: UIFont.editorialTitle(size: 120),
                    .foregroundColor: PolaroidPalette.ink.withAlphaComponent(0.85)
                ])
                let dsize = dateHero.size()
                dateHero.draw(at: CGPoint(x: photoRect.midX - dsize.width / 2,
                                           y: photoRect.midY - dsize.height / 2 - 40))

                let weekday = NSAttributedString(string: s.weekday, attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 28, weight: .regular),
                    .foregroundColor: PolaroidPalette.ink.withAlphaComponent(0.6),
                    .kern: 4
                ])
                let wsize = weekday.size()
                weekday.draw(at: CGPoint(x: photoRect.midX - wsize.width / 2,
                                          y: photoRect.midY + 40))
            }

            var y = photoRect.maxY + 56
            summaryAttr.draw(with: CGRect(x: photoX, y: y, width: photoW, height: summaryMeasure.height),
                             options: [.usesLineFragmentOrigin], context: nil)
            y += ceil(summaryMeasure.height) + 32

            for h in s.highlights {
                PolaroidPalette.accent.setFill()
                cg.fill(CGRect(x: photoX, y: y + 18, width: 12, height: 12))
                let attr = NSAttributedString(string: truncate(h, to: 56), attributes: [
                    .font: UIFont.systemFont(ofSize: 28, weight: .regular),
                    .foregroundColor: PolaroidPalette.ink
                ])
                attr.draw(at: CGPoint(x: photoX + 36, y: y))
                y += 60
            }
            y += 32

            let dateAttr = NSAttributedString(
                string: handwrittenDate(from: parseDailyDate(s.dateString)),
                attributes: [
                    .font: UIFont.editorialTitle(size: 60),
                    .foregroundColor: PolaroidPalette.pencil
                ])
            dateAttr.draw(at: CGPoint(x: photoX, y: y))

            let entriesAttr = NSAttributedString(
                string: "\(s.memoCount) ENTRIES · DAYPAGE.APP",
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 20, weight: .regular),
                    .foregroundColor: PolaroidPalette.inkMuted.withAlphaComponent(0.75),
                    .kern: 1.5
                ])
            let esz = entriesAttr.size()
            entriesAttr.draw(at: CGPoint(x: frameRect.maxX - photoSide - esz.width, y: y + 30))
        }
    }
}

// MARK: - PolaroidMonthlyTemplate

enum PolaroidMonthlyTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .monthly(let s) = payload else { return UIImage() }
        return draw(s)
    }

    private static func draw(_ s: MonthlySnapshot) -> UIImage {
        let W = CardGeom.width
        let outerInset: CGFloat = 64
        let frameLeft = outerInset
        let frameWidth = W - outerInset * 2
        let frameTop = outerInset
        let photoSide: CGFloat = 64
        let photoX = frameLeft + photoSide
        let photoW = frameWidth - photoSide * 2

        let photoH: CGFloat = 720
        let frameHeight: CGFloat = 80 + photoH + 56 + 80 + 110 + 96
        let totalH = frameTop + frameHeight + outerInset
        let size = CGSize(width: W, height: totalH)
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat1x())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            PolaroidPalette.paper.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            let frameRect = CGRect(x: frameLeft, y: frameTop, width: frameWidth, height: frameHeight)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 24), blur: 48, color: PolaroidPalette.paperShadow.cgColor)
            fillRoundedRect(frameRect, radius: 8, color: PolaroidPalette.frame, in: cg)
            cg.restoreGState()

            let photoRect = CGRect(x: photoX, y: frameTop + 80, width: photoW, height: photoH)
            PolaroidPalette.placeholderBg.setFill()
            cg.fill(photoRect)

            let title = NSAttributedString(string: s.monthTitle, attributes: [
                .font: UIFont.editorialTitle(size: 96),
                .foregroundColor: PolaroidPalette.ink
            ])
            let tsize = title.size()
            title.draw(at: CGPoint(x: photoRect.midX - tsize.width / 2, y: photoRect.minY + 80))

            let cellW = photoRect.width / 2
            let cellH: CGFloat = 220
            let gridTop = photoRect.minY + 260
            let stats: [(String, String, String?)] = [
                ("ENTRIES",   "\(s.totalEntries)",  nil),
                ("PHOTOS",    "\(s.totalPhotos)",   nil),
                ("VOICE",     "\(s.totalVoiceMinutes)", "MIN"),
                ("LOCATIONS", "\(s.totalLocations)", nil)
            ]
            for (i, stat) in stats.enumerated() {
                let row = i / 2
                let col = i % 2
                let cx = photoRect.minX + CGFloat(col) * cellW
                let cy = gridTop + CGFloat(row) * cellH

                let value = NSAttributedString(string: stat.1, attributes: [
                    .font: UIFont.systemFont(ofSize: 110, weight: .bold),
                    .foregroundColor: PolaroidPalette.accent
                ])
                let vsize = value.size()
                value.draw(at: CGPoint(x: cx + cellW / 2 - vsize.width / 2, y: cy))

                let label = NSAttributedString(
                    string: stat.0 + (stat.2.map { " (\($0))" } ?? ""),
                    attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                        .foregroundColor: PolaroidPalette.inkMuted,
                        .kern: 1.5
                    ])
                let lsize = label.size()
                label.draw(at: CGPoint(x: cx + cellW / 2 - lsize.width / 2, y: cy + 140))
            }

            let footerY = photoRect.maxY + 56
            let caption = NSAttributedString(string: "\u{2014}\u{2014} THIS MONTH IN REVIEW", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 24, weight: .regular),
                .foregroundColor: PolaroidPalette.pencil,
                .kern: 2
            ])
            caption.draw(at: CGPoint(x: photoX, y: footerY))

            let wm = NSAttributedString(string: "daypage.app", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 20, weight: .regular),
                .foregroundColor: PolaroidPalette.inkMuted.withAlphaComponent(0.75),
                .kern: 1.5
            ])
            let wmsz = wm.size()
            wm.draw(at: CGPoint(x: frameRect.maxX - photoSide - wmsz.width, y: footerY + 60))
        }
    }
}

// MARK: - PolaroidQuoteTemplate

enum PolaroidQuoteTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .quote(let s) = payload else { return UIImage() }
        return draw(s)
    }

    private static func draw(_ s: QuoteSnapshot) -> UIImage {
        let W = CardGeom.width
        let outerInset: CGFloat = 64
        let frameLeft = outerInset
        let frameWidth = W - outerInset * 2
        let frameTop = outerInset
        let photoSide: CGFloat = 64
        let photoX = frameLeft + photoSide
        let photoW = frameWidth - photoSide * 2

        let bodyText = truncate(s.text.trimmingCharacters(in: .whitespacesAndNewlines), to: 200)
        let quoteFontSize: CGFloat = bodyText.count < 100 ? 60 : 48
        let quoteFont = UIFont.systemFont(ofSize: quoteFontSize, weight: .regular)
        let italicQuote: UIFont = {
            let d = UIFontDescriptor(name: quoteFont.fontName, size: quoteFont.pointSize)
                .withSymbolicTraits(.traitItalic)
            return d.flatMap { UIFont(descriptor: $0, size: quoteFont.pointSize) } ?? quoteFont
        }()
        let quotePara = NSMutableParagraphStyle()
        quotePara.lineHeightMultiple = 1.35
        let quoteAttr = NSAttributedString(string: bodyText, attributes: [
            .font: italicQuote,
            .foregroundColor: PolaroidPalette.ink,
            .paragraphStyle: quotePara
        ])
        let quoteMeasure = quoteAttr.measure(width: photoW - 80)

        let photoH: CGFloat = max(620, ceil(quoteMeasure.height) + 320)
        let frameHeight: CGFloat = 80 + photoH + 56 + 110 + 96
        let totalH = frameTop + frameHeight + outerInset
        let size = CGSize(width: W, height: totalH)
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat1x())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            PolaroidPalette.paper.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            let frameRect = CGRect(x: frameLeft, y: frameTop, width: frameWidth, height: frameHeight)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 24), blur: 48, color: PolaroidPalette.paperShadow.cgColor)
            fillRoundedRect(frameRect, radius: 8, color: PolaroidPalette.frame, in: cg)
            cg.restoreGState()

            let photoRect = CGRect(x: photoX, y: frameTop + 80, width: photoW, height: photoH)
            PolaroidPalette.placeholderBg.setFill()
            cg.fill(photoRect)

            let openQuote = NSAttributedString(string: "\u{201C}", attributes: [
                .font: UIFont.editorialTitle(size: 200),
                .foregroundColor: PolaroidPalette.accent.withAlphaComponent(0.55)
            ])
            openQuote.draw(at: CGPoint(x: photoRect.minX + 40, y: photoRect.minY + 24))

            let quoteY = photoRect.minY + 200
            quoteAttr.draw(
                with: CGRect(x: photoRect.minX + 40, y: quoteY, width: photoW - 80, height: quoteMeasure.height),
                options: [.usesLineFragmentOrigin], context: nil
            )

            let attrib = NSAttributedString(string: "\u{2014} " + truncate(s.attribution, to: 50), attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                .foregroundColor: PolaroidPalette.pencil,
                .kern: 1.5
            ])
            attrib.draw(at: CGPoint(x: photoRect.minX + 40, y: photoRect.maxY - 80))

            let footerY = photoRect.maxY + 56
            let caption = NSAttributedString(string: "\u{2014}\u{2014} QUOTED FROM DAYPAGE", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 24, weight: .regular),
                .foregroundColor: PolaroidPalette.pencil,
                .kern: 2
            ])
            caption.draw(at: CGPoint(x: photoX, y: footerY))

            let wm = NSAttributedString(string: "daypage.app", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 20, weight: .regular),
                .foregroundColor: PolaroidPalette.inkMuted.withAlphaComponent(0.75),
                .kern: 1.5
            ])
            let wmsz = wm.size()
            wm.draw(at: CGPoint(x: frameRect.maxX - photoSide - wmsz.width, y: footerY + 60))
        }
    }
}

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

// Film palette — dark "film gate" (detail.jsx:861-887).
// #0d0a07 bg, #f5ede3 perforation/ink, #e36b4a Kodak orange, #a39f99 mono grey,
// #e8dccc serif body. Hex values transcribed directly from FilmTemplate.tsx.
private enum FilmPalette {
    static let bg        = UIColor(red: 0.051, green: 0.039, blue: 0.027, alpha: 1) // #0d0a07
    static let perf      = UIColor(red: 0.961, green: 0.929, blue: 0.890, alpha: 1) // #f5ede3
    static let photoBg   = UIColor(red: 0.102, green: 0.082, blue: 0.059, alpha: 1) // #1A150F
    static let orange    = UIColor(red: 0.890, green: 0.420, blue: 0.290, alpha: 1) // #e36b4a
    static let mutedGrey = UIColor(red: 0.639, green: 0.624, blue: 0.600, alpha: 1) // #a39f99
    static let serifInk  = UIColor(red: 0.910, green: 0.863, blue: 0.800, alpha: 1) // #e8dccc
    static let iconStroke = UIColor(red: 0.290, green: 0.267, blue: 0.235, alpha: 1) // #4a443c
}

// Journal palette — ruled cream paper + washi tape (detail.jsx:904-933).
private enum JournalPalette {
    static let bg          = UIColor(red: 0.984, green: 0.965, blue: 0.910, alpha: 1) // #FBF6E8
    static let rule        = UIColor(red: 0.706, green: 0.588, blue: 0.353, alpha: 0.18) // rgba(180,150,90,.18)
    static let marginLine  = UIColor(red: 0.890, green: 0.420, blue: 0.290, alpha: 0.30) // rgba(227,107,74,.3)
    static let washiOrange = UIColor(red: 0.890, green: 0.420, blue: 0.290, alpha: 0.55) // rgba(227,107,74,.55)
    static let washiGreen  = UIColor(red: 0.416, green: 0.525, blue: 0.267, alpha: 0.50) // rgba(106,134,68,.5)
    static let titleInk    = UIColor(red: 0.227, green: 0.165, blue: 0.094, alpha: 1) // #3a2a18
    static let subInk      = UIColor(red: 0.541, green: 0.416, blue: 0.227, alpha: 1) // #8a6a3a
    static let divider     = UIColor(red: 0.788, green: 0.651, blue: 0.467, alpha: 0.70) // #c9a677 @ .7
    static let redDot      = UIColor(red: 0.890, green: 0.420, blue: 0.290, alpha: 1) // #E36B4A
    static let photoBg     = UIColor(red: 0.910, green: 0.890, blue: 0.855, alpha: 1)
}

// Postcard palette — clean white card + dashed stamp (detail.jsx:935-965).
private enum PostcardPalette {
    static let bg        = UIColor.white
    static let photoBg   = UIColor(red: 0.847, green: 0.812, blue: 0.768, alpha: 1) // #D8CFC4
    static let border    = UIColor(red: 0.839, green: 0.808, blue: 0.753, alpha: 1) // #D6CEC0
    static let serifInk  = UIColor(red: 0.169, green: 0.157, blue: 0.133, alpha: 1) // #2B2822
    static let muted     = UIColor(red: 0.420, green: 0.396, blue: 0.376, alpha: 1) // #6B6560
    static let subtle    = UIColor(red: 0.639, green: 0.624, blue: 0.600, alpha: 1) // #A39F99
    static let accent    = UIColor(red: 0.365, green: 0.188, blue: 0.000, alpha: 1) // #5D3000
    static let iconStroke = UIColor(red: 0.659, green: 0.596, blue: 0.502, alpha: 1) // #A89880
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

// All DateFormatters use en_US_POSIX so the rendered card layout is
// locale-stable — RTL locales (Arabic / Hebrew) would otherwise break the
// left-aligned typography on Polaroid footers. (#302 Evaluator MEDIUM)
private let posixLocale = Locale(identifier: "en_US_POSIX")

private func headerDate(from date: Date) -> String {
    let f = DateFormatter()
    f.locale = posixLocale
    f.dateFormat = "yyyy·MM·dd"
    return f.string(from: date)
}

private func headerTime(from date: Date) -> String {
    let f = DateFormatter()
    f.locale = posixLocale
    f.dateFormat = "HH:mm"
    return f.string(from: date)
}

private func handwrittenDate(from date: Date) -> String {
    let f = DateFormatter()
    f.locale = posixLocale
    f.dateFormat = "MMM d, yyyy"
    return f.string(from: date)
}

private func parseDailyDate(_ s: String) -> Date {
    let f = DateFormatter()
    f.locale = posixLocale
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: s) ?? Date()
}

// Film header date — "28 / MAY / 2026" (FilmTemplate.tsx:4-9).
private func filmDate(from date: Date) -> String {
    let f = DateFormatter()
    f.locale = posixLocale
    f.dateFormat = "dd / MMM / yyyy"
    return f.string(from: date).uppercased()
}

// Postcard date — "28 · MAY · 2026" (PostcardTemplate.tsx:3-9).
private func postcardDate(from date: Date) -> String {
    let f = DateFormatter()
    f.locale = posixLocale
    f.dateFormat = "dd · MMM · yyyy"
    return f.string(from: date).uppercased()
}

// Journal title — full weekday e.g. "Thursday" (JournalTemplate.tsx:3-5).
private func journalWeekday(from date: Date) -> String {
    let f = DateFormatter()
    f.locale = posixLocale
    f.dateFormat = "EEEE"
    return f.string(from: date)
}

// Journal subtitle — lowercase "may 28" (JournalTemplate.tsx:7-11).
private func journalMonthDay(from date: Date) -> String {
    let f = DateFormatter()
    f.locale = posixLocale
    f.dateFormat = "MMMM d"
    return f.string(from: date).lowercased()
}

// Serif italic — Film body uses Fraunces italic; system serif italic is the
// reliable off-screen-context equivalent (PosterTemplates header note on TTFs).
private extension UIFont {
    static func serifItalic(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        var traits: UIFontDescriptor.SymbolicTraits = [.traitItalic]
        if let serif = base.fontDescriptor.withDesign(.serif) {
            traits.formUnion(serif.symbolicTraits)
            if let italic = serif.withSymbolicTraits(traits) {
                return UIFont(descriptor: italic, size: size)
            }
            return UIFont(descriptor: serif, size: size)
        }
        if let italic = base.fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: italic, size: size)
        }
        return base
    }
}

// Draws a repeating horizontal dashed strip (35mm perforations) across `rect`.
// Mirrors the CSS `repeating-linear-gradient(90deg, perf 0 8px, transparent 8px 14px)`
// from FilmTemplate.tsx:12 — scaled ×3 to the 1080 canvas (dash 24, gap 18).
private func drawPerforations(in rect: CGRect, color: UIColor, ctx: CGContext) {
    ctx.saveGState()
    color.setFill()
    let dash: CGFloat = 24
    let period: CGFloat = 42 // 24 dash + 18 transparent
    var x = rect.minX
    while x < rect.maxX {
        let w = min(dash, rect.maxX - x)
        ctx.fill(CGRect(x: x, y: rect.minY, width: w, height: rect.height))
        x += period
    }
    ctx.restoreGState()
}

// Stroke a rounded rect with a dashed border (postcard stamp + divider).
private func strokeDashedRoundedRect(_ rect: CGRect, radius: CGFloat, lineWidth: CGFloat,
                                     dash: [CGFloat], color: UIColor, in ctx: CGContext) {
    ctx.saveGState()
    color.setStroke()
    let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
    path.lineWidth = lineWidth
    path.setLineDash(dash, count: dash.count, phase: 0)
    path.stroke()
    ctx.restoreGState()
}

// Horizontal dashed hairline (postcard header divider, JournalTemplate margin).
private func drawDashedHLine(from start: CGPoint, length: CGFloat, lineWidth: CGFloat,
                            dash: [CGFloat], color: UIColor, in ctx: CGContext) {
    ctx.saveGState()
    color.setStroke()
    let path = UIBezierPath()
    path.move(to: start)
    path.addLine(to: CGPoint(x: start.x + length, y: start.y))
    path.lineWidth = lineWidth
    path.setLineDash(dash, count: dash.count, phase: 0)
    path.stroke()
    ctx.restoreGState()
}

// Draws a rotated solid washi-tape strip with a soft shadow.
private func drawWashiTape(center: CGPoint, width: CGFloat, height: CGFloat,
                          rotation: CGFloat, color: UIColor, in ctx: CGContext) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: rotation)
    ctx.setShadow(offset: CGSize(width: 0, height: 4),
                  blur: 6,
                  color: UIColor(red: 0.235, green: 0.157, blue: 0.059, alpha: 0.15).cgColor)
    color.setFill()
    ctx.fill(CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
    ctx.restoreGState()
}

// Faux-coordinate footer for film cards. The design hardcodes Vientiane coords
// (FilmTemplate.tsx:127) as flavour; we keep that string only when no real
// location/coords exist, otherwise show the memo's actual place name.
private func filmFooter(location: String?) -> String {
    if let l = location, !l.isEmpty {
        return l.uppercased()
    }
    return "VIENTIANE · 18.04°N 102.64°E"
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
        // 52pt at 1080-wide canvas = ~4.8% of width. Smaller fonts (46pt) tested
        // illegible at 1x thumbnail scale during Evaluator review. (#302)
        let bodyFont = UIFont.systemFont(ofSize: 52, weight: .regular)
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
        let bodyW = W - inset * 2

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

        // Summary: 400 chars at 38pt to leave room for section bodies
        let summaryText = truncate(s.summary, to: 400)
        let summaryFont = UIFont.systemFont(ofSize: 38, weight: .regular)
        let summaryPara = NSMutableParagraphStyle()
        summaryPara.lineHeightMultiple = 1.35
        let summaryAttr = NSAttributedString(string: summaryText, attributes: [
            .font: summaryFont,
            .foregroundColor: MinimalPalette.ink,
            .paragraphStyle: summaryPara
        ])
        let summaryMeasure = summaryAttr.measure(width: bodyW)

        // Section blocks: title + body preview, 32px inter-section gap
        let sectionFont = UIFont.systemFont(ofSize: 30, weight: .medium)
        let bodyPreviewFont = UIFont.systemFont(ofSize: 24, weight: .regular)
        let bodyPreviewPara = NSMutableParagraphStyle()
        bodyPreviewPara.lineHeightMultiple = 1.32
        let numColW: CGFloat = 70

        var sectionBlockH: CGFloat = 0
        let sections = Array(s.sections.prefix(3))
        var sectionMeasures: [CGFloat] = []
        for sec in sections {
            let preview = sec.bodyPreview.isEmpty ? "" : truncate(sec.bodyPreview, to: 120)
            if preview.isEmpty {
                sectionMeasures.append(0)
            } else {
                let attr = NSAttributedString(string: preview, attributes: [
                    .font: bodyPreviewFont,
                    .foregroundColor: MinimalPalette.inkMuted,
                    .paragraphStyle: bodyPreviewPara
                ])
                sectionMeasures.append(ceil(attr.measure(width: bodyW - numColW).height))
            }
        }
        if !sections.isEmpty {
            sectionBlockH += 48 + 2 // top divider gap + line
            for (i, _) in sections.enumerated() {
                sectionBlockH += 40 // title row
                let ph = sectionMeasures[i]
                if ph > 0 { sectionBlockH += 8 + ph }
                if i < sections.count - 1 { sectionBlockH += 32 }
            }
            sectionBlockH += 48 // bottom divider gap
        }

        let baseH = inset + 320 + 64 +
                    ceil(summaryMeasure.height) + 48 +
                    sectionBlockH +
                    80 + 96 + 80

        let size = CGSize(width: W, height: max(1400, baseH))
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat1x())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            MinimalPalette.bg.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            var y = inset

            drawMinimalHeader(at: CGPoint(x: inset, y: y),
                               width: bodyW,
                               rightText: "DAILY PAGE",
                               ctx: cg)
            y += 96 + 56

            weekdayAttr.draw(at: CGPoint(x: inset, y: y))
            y += 48
            dateAttr.draw(at: CGPoint(x: inset, y: y))
            y += 168

            MinimalPalette.inkFaint.setFill()
            cg.fill(CGRect(x: inset, y: y, width: bodyW, height: 2))
            y += 56

            summaryAttr.draw(with: CGRect(x: inset, y: y, width: bodyW, height: summaryMeasure.height),
                             options: [.usesLineFragmentOrigin], context: nil)
            y += ceil(summaryMeasure.height) + 32

            // Compact location line below summary
            if !s.locationPrimary.isEmpty {
                let locLine = NSAttributedString(string: "📍 " + truncate(s.locationPrimary, to: 40), attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                    .foregroundColor: MinimalPalette.inkMuted,
                    .kern: 1
                ])
                locLine.draw(at: CGPoint(x: inset, y: y))
                y += 40
            }
            y += 16

            if !sections.isEmpty {
                // Section divider
                MinimalPalette.inkFaint.setFill()
                cg.fill(CGRect(x: inset, y: y, width: bodyW, height: 2))
                y += 24

                for (idx, sec) in sections.enumerated() {
                    let num = NSAttributedString(
                        string: String(format: "%02d", idx + 1),
                        attributes: [
                            .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                            .foregroundColor: MinimalPalette.accent,
                            .kern: 1
                        ])
                    num.draw(at: CGPoint(x: inset, y: y + 5))

                    let title = NSAttributedString(
                        string: truncate(sec.title, to: 56),
                        attributes: [
                            .font: sectionFont,
                            .foregroundColor: MinimalPalette.ink
                        ])
                    title.draw(at: CGPoint(x: inset + numColW, y: y))
                    y += 40

                    let preview = sec.bodyPreview.isEmpty ? "" : truncate(sec.bodyPreview, to: 120)
                    if !preview.isEmpty {
                        let bodyAttr = NSAttributedString(string: preview, attributes: [
                            .font: bodyPreviewFont,
                            .foregroundColor: MinimalPalette.inkMuted,
                            .paragraphStyle: bodyPreviewPara
                        ])
                        let bh = sectionMeasures[idx]
                        bodyAttr.draw(
                            with: CGRect(x: inset + numColW, y: y + 8, width: bodyW - numColW, height: bh),
                            options: [.usesLineFragmentOrigin], context: nil
                        )
                        y += 8 + bh
                    }

                    if idx < sections.count - 1 { y += 32 }
                }

                y += 24
                MinimalPalette.inkFaint.setFill()
                cg.fill(CGRect(x: inset, y: y, width: bodyW, height: 2))
                y += 48
            }

            // Richer stats line
            var statParts = ["\(s.memoCount) entries"]
            if s.photoCount > 0 { statParts.append("\(s.photoCount) photos") }
            if s.voiceCount > 0 { statParts.append("\(s.voiceCount) voice") }
            if !s.locationPrimary.isEmpty { statParts.append(truncate(s.locationPrimary, to: 20)) }
            let statsText = statParts.joined(separator: " · ")
            let statsAttr = NSAttributedString(string: statsText.uppercased(), attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                .foregroundColor: MinimalPalette.inkMuted,
                .kern: 1.5
            ])
            statsAttr.draw(at: CGPoint(x: inset, y: y + 16))

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

            // truncate(to: 24) covers e.g. "SEPTEMBER 2025"; longer locale variants
            // get an ellipsis instead of overlapping the brand mark. (#302)
            drawMinimalHeader(at: CGPoint(x: inset, y: y),
                               width: W - inset * 2,
                               rightText: truncate(s.monthTitle, to: 24),
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

            // Photo (or text-only fallback when memo has no photo attachment)
            let photoRect = CGRect(x: photoX, y: photoTop, width: photoW, height: photoH)
            if let cover = s.coverImage {
                drawAspectFill(cover, in: photoRect, ctx: cg)
            } else {
                // Issue #309 W1-③: instead of a grey placeholder with just an
                // initial letter, give text-only memos a real visual hook —
                // soft accent wash + giant first letter (kept as anchor) +
                // an emphasised first sentence so the card carries content,
                // not emptiness. Polaroid still reads as "frame + caption"
                // below, this just makes the "photo" area meaningful.
                let wash = PolaroidPalette.accent.withAlphaComponent(0.08)
                wash.setFill()
                cg.fill(photoRect)

                let trimmed = s.body.trimmingCharacters(in: .whitespacesAndNewlines)
                let initial = trimmed.first.map { String($0) } ?? "·"
                let initAttr = NSAttributedString(string: initial, attributes: [
                    .font: UIFont.editorialTitle(size: 360),
                    .foregroundColor: PolaroidPalette.accent.withAlphaComponent(0.22)
                ])
                let isz = initAttr.size()
                initAttr.draw(at: CGPoint(x: photoRect.midX - isz.width / 2,
                                           y: photoRect.midY - isz.height / 2 - 40))

                // First sentence, centred under the initial. Truncated to fit
                // one line so we never blow out the square photo region.
                let firstSentence = trimmed
                    .components(separatedBy: CharacterSet(charactersIn: "。.!?！？\n"))
                    .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
                let quoteText = truncate(firstSentence.trimmingCharacters(in: .whitespaces), to: 28)
                if !quoteText.isEmpty {
                    let quotePara = NSMutableParagraphStyle()
                    quotePara.alignment = .center
                    let quoteAttr = NSAttributedString(string: "\u{201C}\(quoteText)\u{201D}", attributes: [
                        .font: UIFont.systemFont(ofSize: 38, weight: .medium),
                        .foregroundColor: PolaroidPalette.ink.withAlphaComponent(0.62),
                        .paragraphStyle: quotePara
                    ])
                    let qrect = CGRect(x: photoRect.minX + 24,
                                       y: photoRect.maxY - 120,
                                       width: photoRect.width - 48,
                                       height: 80)
                    quoteAttr.draw(with: qrect, options: [.usesLineFragmentOrigin], context: nil)
                }
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

        let summaryText = truncate(s.summary, to: 260)
        let summaryFont = UIFont.systemFont(ofSize: 36, weight: .regular)
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

        let bodyPreviewFont = UIFont.systemFont(ofSize: 24, weight: .regular)
        let bodyPreviewPara = NSMutableParagraphStyle()
        bodyPreviewPara.lineHeightMultiple = 1.30
        let sections = Array(s.sections.prefix(3))
        var sectionMeasures: [CGFloat] = []
        for sec in sections {
            let preview = sec.bodyPreview.isEmpty ? "" : truncate(sec.bodyPreview, to: 120)
            if preview.isEmpty {
                sectionMeasures.append(0)
            } else {
                let attr = NSAttributedString(string: preview, attributes: [
                    .font: bodyPreviewFont,
                    .foregroundColor: PolaroidPalette.inkMuted,
                    .paragraphStyle: bodyPreviewPara
                ])
                sectionMeasures.append(ceil(attr.measure(width: photoW - 28).height))
            }
        }

        var sectionsH: CGFloat = 0
        if !sections.isEmpty {
            for (i, _) in sections.enumerated() {
                sectionsH += 44
                let ph = sectionMeasures[i]
                if ph > 0 { sectionsH += 8 + ph }
                if i < sections.count - 1 { sectionsH += 24 }
            }
            sectionsH += 16
        }

        let captionBlock = ceil(summaryMeasure.height) + 24
        let dateBlock: CGFloat = 110
        let frameBottomPad: CGFloat = 96
        let frameHeight = 80 + photoH + 56 + captionBlock + 32 + sectionsH + 32 + dateBlock + frameBottomPad
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

            for (idx, sec) in sections.enumerated() {
                PolaroidPalette.accent.setFill()
                cg.fill(CGRect(x: photoX, y: y + 16, width: 8, height: 8))
                let titleAttr = NSAttributedString(string: truncate(sec.title, to: 50), attributes: [
                    .font: UIFont.systemFont(ofSize: 28, weight: .medium),
                    .foregroundColor: PolaroidPalette.ink
                ])
                titleAttr.draw(at: CGPoint(x: photoX + 28, y: y))
                y += 44

                let preview = sec.bodyPreview.isEmpty ? "" : truncate(sec.bodyPreview, to: 120)
                if !preview.isEmpty {
                    let bodyAttr = NSAttributedString(string: preview, attributes: [
                        .font: bodyPreviewFont,
                        .foregroundColor: PolaroidPalette.inkMuted,
                        .paragraphStyle: bodyPreviewPara
                    ])
                    let bh = sectionMeasures[idx]
                    bodyAttr.draw(
                        with: CGRect(x: photoX + 28, y: y + 8, width: photoW - 28, height: bh),
                        options: [.usesLineFragmentOrigin], context: nil
                    )
                    y += 8 + bh
                }

                if idx < sections.count - 1 { y += 24 }
            }
            y += 32

            let dateAttr = NSAttributedString(
                string: handwrittenDate(from: parseDailyDate(s.dateString)),
                attributes: [
                    .font: UIFont.editorialTitle(size: 60),
                    .foregroundColor: PolaroidPalette.pencil
                ])
            dateAttr.draw(at: CGPoint(x: photoX, y: y))

            var statParts = ["\(s.memoCount) entries"]
            if s.photoCount > 0 { statParts.append("\(s.photoCount) photos") }
            if s.voiceCount > 0 { statParts.append("\(s.voiceCount) voice") }
            let statsAttr = NSAttributedString(
                string: statParts.joined(separator: " · ").uppercased(),
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 20, weight: .regular),
                    .foregroundColor: PolaroidPalette.inkMuted.withAlphaComponent(0.75),
                    .kern: 1.5
                ])
            let esz = statsAttr.size()
            statsAttr.draw(at: CGPoint(x: frameRect.maxX - photoSide - esz.width, y: y + 30))

            // Brand watermark — left side, mirrors the stats line on the right
            // so a shared Daily card is unambiguously DayPage (issue #309 W1-④).
            // The other 11 templates already render this; Daily was the gap.
            let wm = NSAttributedString(string: "daypage.app", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 20, weight: .regular),
                .foregroundColor: PolaroidPalette.inkMuted.withAlphaComponent(0.7),
                .kern: 1.5
            ])
            wm.draw(at: CGPoint(x: photoX, y: y + 30))
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

// MARK: - MinimalPhotoTemplate

enum MinimalPhotoTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .photo(let s) = payload else { return UIImage() }
        return draw(s)
    }

    private static func draw(_ s: PhotoSnapshot) -> UIImage {
        let W = CardGeom.width
        let inset = CardGeom.inset
        let bodyW = W - inset * 2

        let photoH: CGFloat = W * 0.6
        let captionText = truncate(s.caption.trimmingCharacters(in: .whitespacesAndNewlines), to: 240)
        let captionFont = UIFont.systemFont(ofSize: 44, weight: .regular)
        let captionPara = NSMutableParagraphStyle()
        captionPara.lineHeightMultiple = 1.32
        let captionAttr = NSAttributedString(string: captionText, attributes: [
            .font: captionFont,
            .foregroundColor: MinimalPalette.ink,
            .paragraphStyle: captionPara
        ])
        let captionMeasure = captionAttr.measure(width: bodyW)

        let totalH = inset + 96 + 64 + photoH + 64 + ceil(captionMeasure.height) + 48 + 60 + 80 + 96 + 80
        let size = CGSize(width: W, height: max(1400, totalH))
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat1x())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            MinimalPalette.bg.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            var y = inset
            drawMinimalHeader(at: CGPoint(x: inset, y: y), width: bodyW, rightText: s.time, ctx: cg)
            y += 96 + 64

            let photoRect = CGRect(x: inset, y: y, width: bodyW, height: photoH)
            drawAspectFill(s.image, in: photoRect, ctx: cg)
            cg.setStrokeColor(MinimalPalette.inkFaint.cgColor)
            cg.setLineWidth(2)
            cg.stroke(photoRect)
            y += photoH + 64

            if !captionText.isEmpty {
                captionAttr.draw(
                    with: CGRect(x: inset, y: y, width: bodyW, height: captionMeasure.height),
                    options: [.usesLineFragmentOrigin], context: nil
                )
                y += ceil(captionMeasure.height) + 48
            }

            var metaParts: [String] = []
            if let exif = s.exif, !exif.isEmpty { metaParts.append(exif) }
            if let loc = s.location, !loc.isEmpty { metaParts.append(loc) }
            if !metaParts.isEmpty {
                let metaAttr = NSAttributedString(
                    string: truncate(metaParts.joined(separator: "  ·  ").uppercased(), to: 80),
                    attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                        .foregroundColor: MinimalPalette.inkMuted,
                        .kern: 1.5
                    ])
                metaAttr.draw(at: CGPoint(x: inset, y: y))
            }

            drawMinimalFooter(in: size, ctx: cg)
        }
    }
}

// MARK: - PolaroidPhotoTemplate

enum PolaroidPhotoTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .photo(let s) = payload else { return UIImage() }
        return draw(s)
    }

    private static func draw(_ s: PhotoSnapshot) -> UIImage {
        let W = CardGeom.width
        let outerInset: CGFloat = 64
        let frameLeft = outerInset
        let frameWidth = W - outerInset * 2
        let frameTop = outerInset
        let photoSide: CGFloat = 64
        let photoX = frameLeft + photoSide
        let photoW = frameWidth - photoSide * 2
        let photoH = photoW

        let captionText = truncate(s.caption.trimmingCharacters(in: .whitespacesAndNewlines), to: 160)
        let captionFont = UIFont.systemFont(ofSize: 38, weight: .regular)
        let captionPara = NSMutableParagraphStyle()
        captionPara.lineHeightMultiple = 1.30
        let italicFont: UIFont = {
            let d = UIFontDescriptor(name: captionFont.fontName, size: captionFont.pointSize)
                .withSymbolicTraits(.traitItalic)
            return d.flatMap { UIFont(descriptor: $0, size: captionFont.pointSize) } ?? captionFont
        }()
        let captionAttr = NSAttributedString(string: captionText, attributes: [
            .font: italicFont,
            .foregroundColor: PolaroidPalette.ink,
            .paragraphStyle: captionPara
        ])
        let captionMeasure = captionAttr.measure(width: photoW)
        let captionBlock = captionText.isEmpty ? 0 : ceil(captionMeasure.height) + 32

        let photoTop = frameTop + 80
        let frameHeight = 80 + photoH + 56 + captionBlock + 80 + 100 + 88
        let totalH = frameTop + frameHeight + outerInset
        let size = CGSize(width: W, height: totalH)
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat1x())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            PolaroidPalette.paper.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            let frameRect = CGRect(x: frameLeft, y: frameTop, width: frameWidth, height: frameHeight)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 20), blur: 40, color: PolaroidPalette.paperShadow.cgColor)
            fillRoundedRect(frameRect, radius: 8, color: PolaroidPalette.frame, in: cg)
            cg.restoreGState()

            let photoRect = CGRect(x: photoX, y: photoTop, width: photoW, height: photoH)
            drawAspectFill(s.image, in: photoRect, ctx: cg)

            var y = photoRect.maxY + 56

            if !captionText.isEmpty {
                captionAttr.draw(
                    with: CGRect(x: photoX, y: y, width: photoW, height: captionMeasure.height),
                    options: [.usesLineFragmentOrigin], context: nil
                )
                y += ceil(captionMeasure.height) + 32
            }

            var metaParts: [String] = []
            if let loc = s.location, !loc.isEmpty { metaParts.append(loc) }
            if let exif = s.exif, !exif.isEmpty { metaParts.append(exif) }
            if !metaParts.isEmpty {
                let metaAttr = NSAttributedString(
                    string: truncate(metaParts.joined(separator: " · "), to: 60).uppercased(),
                    attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                        .foregroundColor: PolaroidPalette.inkMuted,
                        .kern: 2
                    ])
                metaAttr.draw(at: CGPoint(x: photoX, y: y))
                y += 56
            }

            let timeAttr = NSAttributedString(
                string: s.time,
                attributes: [
                    .font: UIFont.editorialTitle(size: 56),
                    .foregroundColor: PolaroidPalette.pencil
                ])
            timeAttr.draw(at: CGPoint(x: photoX, y: y + 16))

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

// MARK: - MinimalVoiceTemplate

enum MinimalVoiceTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .voice(let s) = payload else { return UIImage() }
        return draw(s)
    }

    private static func draw(_ s: VoiceSnapshot) -> UIImage {
        let W = CardGeom.width
        let inset = CardGeom.inset
        let bodyW = W - inset * 2

        let transcriptText = s.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcriptFont = UIFont.systemFont(ofSize: 44, weight: .regular)
        let transcriptPara = NSMutableParagraphStyle()
        transcriptPara.lineHeightMultiple = 1.35
        let transcriptAttr = NSAttributedString(string: transcriptText, attributes: [
            .font: transcriptFont,
            .foregroundColor: MinimalPalette.ink,
            .paragraphStyle: transcriptPara
        ])
        let transcriptMeasure = transcriptAttr.measure(width: bodyW)

        let totalH = inset + 96 + 64 + 220 + 64 + ceil(transcriptMeasure.height) + 80 + 80 + 96 + 80
        let size = CGSize(width: W, height: max(1300, totalH))
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat1x())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            UIColor(red: 0.965, green: 0.949, blue: 0.925, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            var y = inset
            drawMinimalHeader(at: CGPoint(x: inset, y: y), width: bodyW, rightText: s.time, ctx: cg)
            y += 96 + 64

            // Icon + duration row
            let waveAttr = NSAttributedString(string: "◉", attributes: [
                .font: UIFont.systemFont(ofSize: 120, weight: .ultraLight),
                .foregroundColor: MinimalPalette.accent
            ])
            waveAttr.draw(at: CGPoint(x: inset, y: y))

            let durAttr = NSAttributedString(string: s.duration, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 96, weight: .bold),
                .foregroundColor: MinimalPalette.ink,
                .kern: 2
            ])
            durAttr.draw(at: CGPoint(x: inset + 160, y: y + 20))
            y += 160

            // Waveform decoration
            let dashHeights: [CGFloat] = [24, 40, 56, 32, 64, 28, 48, 36, 60, 20]
            let dashAlphas: [CGFloat] = [0.6, 0.4, 0.8, 0.3, 0.9, 0.5, 0.7, 0.45, 0.85, 0.35]
            let dashW: CGFloat = 12
            let dashGap: CGFloat = 10
            for i in 0..<10 {
                let h = dashHeights[i]
                let dx = inset + CGFloat(i) * (dashW + dashGap)
                let dy = y + (64 - h) / 2
                fillRoundedRect(CGRect(x: dx, y: dy, width: dashW, height: h), radius: 6,
                                color: MinimalPalette.accent.withAlphaComponent(dashAlphas[i]), in: cg)
            }
            y += 64 + 48

            MinimalPalette.inkFaint.setFill()
            cg.fill(CGRect(x: inset, y: y, width: bodyW, height: 2))
            y += 40

            if !transcriptText.isEmpty {
                transcriptAttr.draw(
                    with: CGRect(x: inset, y: y, width: bodyW, height: transcriptMeasure.height),
                    options: [.usesLineFragmentOrigin], context: nil
                )
                y += ceil(transcriptMeasure.height) + 56
            }

            var metaParts: [String] = ["VOICE MEMO"]
            if let loc = s.location, !loc.isEmpty { metaParts.append(loc) }
            let metaAttr = NSAttributedString(
                string: metaParts.joined(separator: "  ·  ").uppercased(),
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                    .foregroundColor: MinimalPalette.inkMuted,
                    .kern: 1.5
                ])
            metaAttr.draw(at: CGPoint(x: inset, y: y))

            drawMinimalFooter(in: size, ctx: cg)
        }
    }
}

// MARK: - PolaroidVoiceTemplate

enum PolaroidVoiceTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .voice(let s) = payload else { return UIImage() }
        return draw(s)
    }

    private static func draw(_ s: VoiceSnapshot) -> UIImage {
        let W = CardGeom.width
        let outerInset: CGFloat = 64
        let frameLeft = outerInset
        let frameWidth = W - outerInset * 2
        let frameTop = outerInset
        let photoSide: CGFloat = 64
        let photoX = frameLeft + photoSide
        let photoW = frameWidth - photoSide * 2
        let photoH: CGFloat = 520

        let transcriptText = s.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let captionFont = UIFont.systemFont(ofSize: 36, weight: .regular)
        let captionPara = NSMutableParagraphStyle()
        captionPara.lineHeightMultiple = 1.32
        let italicFont: UIFont = {
            let d = UIFontDescriptor(name: captionFont.fontName, size: captionFont.pointSize)
                .withSymbolicTraits(.traitItalic)
            return d.flatMap { UIFont(descriptor: $0, size: captionFont.pointSize) } ?? captionFont
        }()
        let captionAttr = NSAttributedString(string: transcriptText, attributes: [
            .font: italicFont,
            .foregroundColor: PolaroidPalette.ink,
            .paragraphStyle: captionPara
        ])
        let captionMeasure = captionAttr.measure(width: photoW)
        let captionBlock = transcriptText.isEmpty ? 0 : ceil(captionMeasure.height) + 32

        let frameHeight = 80 + photoH + 56 + captionBlock + 80 + 100 + 88
        let totalH = frameTop + frameHeight + outerInset
        let size = CGSize(width: W, height: totalH)
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat1x())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            PolaroidPalette.paper.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            let frameRect = CGRect(x: frameLeft, y: frameTop, width: frameWidth, height: frameHeight)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 20), blur: 40, color: PolaroidPalette.paperShadow.cgColor)
            fillRoundedRect(frameRect, radius: 8, color: PolaroidPalette.frame, in: cg)
            cg.restoreGState()

            let photoTop = frameTop + 80
            let photoRect = CGRect(x: photoX, y: photoTop, width: photoW, height: photoH)
            PolaroidPalette.placeholderBg.setFill()
            cg.fill(photoRect)

            let playAttr = NSAttributedString(string: "▶", attributes: [
                .font: UIFont.systemFont(ofSize: 140, weight: .ultraLight),
                .foregroundColor: PolaroidPalette.accent.withAlphaComponent(0.45)
            ])
            let psz = playAttr.size()
            playAttr.draw(at: CGPoint(x: photoRect.midX - psz.width / 2, y: photoRect.minY + 60))

            let durAttr = NSAttributedString(string: s.duration, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 96, weight: .bold),
                .foregroundColor: PolaroidPalette.ink
            ])
            let dsz = durAttr.size()
            durAttr.draw(at: CGPoint(x: photoRect.midX - dsz.width / 2, y: photoRect.minY + 260))

            let labelAttr = NSAttributedString(string: "VOICE MEMO", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                .foregroundColor: PolaroidPalette.inkMuted,
                .kern: 4
            ])
            let lsz = labelAttr.size()
            labelAttr.draw(at: CGPoint(x: photoRect.midX - lsz.width / 2, y: photoRect.minY + 400))

            var y = photoRect.maxY + 56

            if !transcriptText.isEmpty {
                captionAttr.draw(
                    with: CGRect(x: photoX, y: y, width: photoW, height: captionMeasure.height),
                    options: [.usesLineFragmentOrigin], context: nil
                )
                y += ceil(captionMeasure.height) + 32
            }

            if let loc = s.location, !loc.isEmpty {
                let locAttr = NSAttributedString(string: loc.uppercased(), attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                    .foregroundColor: PolaroidPalette.inkMuted,
                    .kern: 2
                ])
                locAttr.draw(at: CGPoint(x: photoX, y: y))
                y += 56
            }

            let timeAttr = NSAttributedString(
                string: s.time,
                attributes: [
                    .font: UIFont.editorialTitle(size: 56),
                    .foregroundColor: PolaroidPalette.pencil
                ])
            timeAttr.draw(at: CGPoint(x: photoX, y: y + 16))

            let wm = NSAttributedString(string: "daypage.app", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 20, weight: .regular),
                .foregroundColor: PolaroidPalette.inkMuted.withAlphaComponent(0.7),
                .kern: 1.5
            ])
            let wmSz = wm.size()
            wm.draw(at: CGPoint(x: frameRect.maxX - photoSide - wmSz.width, y: y + 40))
        }
    }
}

// MARK: - MinimalCollageTemplate
//
// Multi-memo collage in IG-Story aspect (1080 × 1920). One template covers
// both PosterStyle.minimal and .polaroid because the IG-tall canvas can't
// accommodate Polaroid frame chrome around 6 stacked items without dropping
// each thumbnail below useful size — PosterDispatcher routes both styles
// here.

enum MinimalCollageTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .collage(let s) = payload else { return UIImage() }
        return draw(s)
    }

    private static func draw(_ s: CollageSnapshot) -> UIImage {
        let W: CGFloat = 1080
        let H: CGFloat = 1920
        let inset: CGFloat = 72
        let bodyW = W - inset * 2

        let size = CGSize(width: W, height: H)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { ctx in
            let cg = ctx.cgContext

            MinimalPalette.bg.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            var y: CGFloat = inset

            let brand = NSAttributedString(string: "DAYPAGE", attributes: [
                .font: UIFont.systemFont(ofSize: 42, weight: .heavy),
                .foregroundColor: MinimalPalette.ink,
                .kern: 7
            ])
            brand.draw(at: CGPoint(x: inset, y: y))

            let countText = "\(s.items.count) MEMOS"
            let count = NSAttributedString(string: countText, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 26, weight: .regular),
                .foregroundColor: MinimalPalette.inkMuted,
                .kern: 2
            ])
            let cSize = count.size()
            count.draw(at: CGPoint(x: inset + bodyW - cSize.width, y: y + 12))

            y += 70

            let date = NSAttributedString(string: s.dateLabel, attributes: [
                .font: UIFont.editorialTitle(size: 110),
                .foregroundColor: MinimalPalette.ink,
                .kern: -1
            ])
            date.draw(at: CGPoint(x: inset, y: y))
            y += 130

            var subParts: [String] = [s.weekday]
            if let loc = s.primaryLocation, !loc.isEmpty {
                subParts.append(loc.uppercased())
            }
            let sub = NSAttributedString(string: subParts.joined(separator: "  ·  "), attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 24, weight: .regular),
                .foregroundColor: MinimalPalette.inkMuted,
                .kern: 2
            ])
            sub.draw(at: CGPoint(x: inset, y: y))
            y += 50

            MinimalPalette.inkFaint.setFill()
            cg.fill(CGRect(x: inset, y: y, width: bodyW, height: 2))
            y += 56

            let bodyTop = y
            let footerHeight: CGFloat = 200
            let bodyBottom = H - footerHeight
            let availableH = bodyBottom - bodyTop
            let interGap: CGFloat = 28
            let n = CGFloat(s.items.count)
            let rowH = max(180, (availableH - interGap * (n - 1)) / n)

            for (idx, item) in s.items.enumerated() {
                let rowY = bodyTop + CGFloat(idx) * (rowH + interGap)
                drawCollageRow(item: item,
                                rect: CGRect(x: inset, y: rowY, width: bodyW, height: rowH),
                                ctx: cg)
            }

            let wmY = H - inset - 40
            MinimalPalette.inkFaint.setFill()
            cg.fill(CGRect(x: inset, y: wmY - 32, width: bodyW, height: 2))
            let wm = NSAttributedString(string: "daypage.app", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                .foregroundColor: MinimalPalette.inkMuted,
                .kern: 3
            ])
            let wmSize = wm.size()
            wm.draw(at: CGPoint(x: (W - wmSize.width) / 2, y: wmY))
        }
    }

    private static func drawCollageRow(item: CollageSnapshot.Item,
                                        rect: CGRect,
                                        ctx cg: CGContext) {
        let thumbSide: CGFloat = min(200, rect.height)
        let thumbRect = CGRect(x: rect.minX, y: rect.minY, width: thumbSide, height: thumbSide)
        let textX = thumbRect.maxX + 32
        let textW = rect.maxX - textX

        if let img = item.thumbnail {
            drawAspectFill(img, in: thumbRect, ctx: cg)
            cg.setStrokeColor(MinimalPalette.inkFaint.cgColor)
            cg.setLineWidth(2)
            cg.stroke(thumbRect)
        } else {
            let bg = MinimalPalette.accent.withAlphaComponent(0.08)
            fillRoundedRect(thumbRect, radius: 12, color: bg, in: cg)
            let glyph: String
            switch item.kind {
            case .text:  glyph = "\u{201C}"
            case .photo: glyph = "\u{25A2}"
            case .voice: glyph = "\u{25B6}"
            case .mixed: glyph = "\u{2756}"
            }
            let glyphAttr = NSAttributedString(string: glyph, attributes: [
                .font: UIFont.systemFont(ofSize: 120, weight: .medium),
                .foregroundColor: MinimalPalette.accent.withAlphaComponent(0.35)
            ])
            let gSize = glyphAttr.size()
            glyphAttr.draw(at: CGPoint(
                x: thumbRect.midX - gSize.width / 2,
                y: thumbRect.midY - gSize.height / 2
            ))
        }

        let kindLabel: String = {
            switch item.kind {
            case .text:  return "TEXT"
            case .photo: return "PHOTO"
            case .voice: return "VOICE"
            case .mixed: return "MIXED"
            }
        }()
        let meta = NSAttributedString(string: "\(item.time)  ·  \(kindLabel)", attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
            .foregroundColor: MinimalPalette.inkMuted,
            .kern: 2
        ])
        meta.draw(at: CGPoint(x: textX, y: rect.minY + 4))

        let bodyFont = UIFont.systemFont(ofSize: 30, weight: .regular)
        let bodyPara = NSMutableParagraphStyle()
        bodyPara.lineHeightMultiple = 1.28
        bodyPara.lineBreakMode = .byTruncatingTail
        let bodyAttr = NSAttributedString(
            string: item.preview.isEmpty ? "(no text)" : item.preview,
            attributes: [
                .font: bodyFont,
                .foregroundColor: item.preview.isEmpty ? MinimalPalette.inkFaint : MinimalPalette.ink,
                .paragraphStyle: bodyPara
            ]
        )
        let bodyRect = CGRect(x: textX,
                              y: rect.minY + 40,
                              width: textW,
                              height: rect.height - 40)
        bodyAttr.draw(with: bodyRect,
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                      context: nil)
    }
}

// MARK: - Film shared chrome
//
// FILM (detail.jsx:861-887 / FilmTemplate.tsx). Dark gate #0d0a07, a mono
// "● 35 mm · Kodak 400" header opposite the date, a 4:5 photo flanked top and
// bottom by 35mm perforation strips, a serif-italic body, and a mono coords
// footer. Canvas width is the standard 1080; geometry is scaled ~3× from the
// 320pt web mock.

private enum FilmGeom {
    static let inset: CGFloat = 54          // 18pt × 3
    static let perfHeight: CGFloat = 18     // 6pt × 3
    static let headerH: CGFloat = 30
}

private func drawFilmHeader(at origin: CGPoint, width: CGFloat, date: Date, ctx: CGContext) {
    let left = NSAttributedString(string: "\u{25CF} 35 mm \u{00B7} Kodak 400", attributes: [
        .font: UIFont.monospacedSystemFont(ofSize: 30, weight: .regular),
        .foregroundColor: FilmPalette.orange,
        .kern: 0.5
    ])
    left.draw(at: origin)

    let right = NSAttributedString(string: filmDate(from: date), attributes: [
        .font: UIFont.monospacedSystemFont(ofSize: 30, weight: .regular),
        .foregroundColor: FilmPalette.mutedGrey,
        .kern: 0.5
    ])
    let rsize = right.size()
    right.draw(at: CGPoint(x: origin.x + width - rsize.width, y: origin.y))
}

// 4:5 photo (or placeholder) with perforation strips above + below.
private func drawFilmPhoto(in rect: CGRect, image: UIImage?, ctx cg: CGContext) {
    if let image = image {
        drawAspectFill(image, in: rect, ctx: cg)
    } else {
        FilmPalette.photoBg.setFill()
        cg.fill(rect)
        // Simple "image" glyph centred, matching the web SVG placeholder.
        let glyph = NSAttributedString(string: "\u{25A2}", attributes: [
            .font: UIFont.systemFont(ofSize: 140, weight: .ultraLight),
            .foregroundColor: FilmPalette.iconStroke
        ])
        let gsz = glyph.size()
        glyph.draw(at: CGPoint(x: rect.midX - gsz.width / 2, y: rect.midY - gsz.height / 2))
    }
    let topStrip = CGRect(x: rect.minX, y: rect.minY - FilmGeom.perfHeight,
                          width: rect.width, height: FilmGeom.perfHeight)
    let botStrip = CGRect(x: rect.minX, y: rect.maxY,
                          width: rect.width, height: FilmGeom.perfHeight)
    drawPerforations(in: topStrip, color: FilmPalette.perf, ctx: cg)
    drawPerforations(in: botStrip, color: FilmPalette.perf, ctx: cg)
}

// MARK: - FilmMemoTemplate

enum FilmMemoTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .memo(let s) = payload else { return UIImage() }
        return draw(body: s.body, date: s.createdAt, location: s.locationName, image: s.coverImage)
    }

    static func draw(body rawBody: String, date: Date, location: String?, image: UIImage?) -> UIImage {
        let W = CardGeom.width
        let inset = FilmGeom.inset
        let bodyW = W - inset * 2

        // 4:5 photo fills the column width.
        let photoW = bodyW
        let photoH = photoW * 5.0 / 4.0

        let body = truncate(rawBody.trimmingCharacters(in: .whitespacesAndNewlines), to: 130)
        let bodyPara = NSMutableParagraphStyle()
        bodyPara.lineHeightMultiple = 1.6
        let bodyAttr = NSAttributedString(string: body, attributes: [
            .font: UIFont.serifItalic(size: 40),
            .foregroundColor: FilmPalette.serifInk,
            .paragraphStyle: bodyPara
        ])
        let bodyMeasure = bodyAttr.measure(width: bodyW)

        let totalH = inset + FilmGeom.headerH + 30 + FilmGeom.perfHeight
            + photoH + FilmGeom.perfHeight + 48
            + ceil(bodyMeasure.height) + 42 + 36 + inset
        let size = CGSize(width: W, height: max(1200, totalH))
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat1x())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            FilmPalette.bg.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            var y = inset
            drawFilmHeader(at: CGPoint(x: inset, y: y), width: bodyW, date: date, ctx: cg)
            y += FilmGeom.headerH + 30 + FilmGeom.perfHeight

            let photoRect = CGRect(x: inset, y: y, width: photoW, height: photoH)
            drawFilmPhoto(in: photoRect, image: image, ctx: cg)
            y += photoH + FilmGeom.perfHeight + 48

            bodyAttr.draw(with: CGRect(x: inset, y: y, width: bodyW, height: bodyMeasure.height),
                          options: [.usesLineFragmentOrigin], context: nil)
            y += ceil(bodyMeasure.height) + 42

            let footer = NSAttributedString(string: truncate(filmFooter(location: location), to: 60), attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 30, weight: .regular),
                .foregroundColor: FilmPalette.mutedGrey,
                .kern: 1.2
            ])
            footer.draw(at: CGPoint(x: inset, y: y))
        }
    }
}

// MARK: - FilmDailyTemplate
//
// Reuses the film gate but leads with the daily summary as the serif-italic
// body and the daily cover as the 4:5 photo. (Sections are intentionally not
// listed — the film aesthetic is a single contemplative frame.)

enum FilmDailyTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .daily(let s) = payload else { return UIImage() }
        let date = parseDailyDate(s.dateString)
        let loc = s.locationPrimary.isEmpty ? nil : s.locationPrimary
        return FilmMemoTemplate.draw(body: s.summary, date: date, location: loc, image: s.coverImage)
    }
}

// MARK: - FilmPhotoTemplate

enum FilmPhotoTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .photo(let s) = payload else { return UIImage() }
        let f = DateFormatter()
        f.locale = posixLocale
        f.dateFormat = "HH:mm"
        // PhotoSnapshot has no Date; use today's date for the header day stamp
        // and keep its captured time inside the EXIF/location footer.
        let footer: String = {
            var parts: [String] = []
            if let l = s.location, !l.isEmpty { parts.append(l.uppercased()) }
            if let e = s.exif, !e.isEmpty { parts.append(e) }
            if parts.isEmpty { return filmFooter(location: nil) }
            return parts.joined(separator: " \u{00B7} ")
        }()
        return drawPhoto(image: s.image, caption: s.caption, footer: footer)
    }

    private static func drawPhoto(image: UIImage, caption: String, footer: String) -> UIImage {
        let W = CardGeom.width
        let inset = FilmGeom.inset
        let bodyW = W - inset * 2
        let photoW = bodyW
        let photoH = photoW * 5.0 / 4.0

        let body = truncate(caption.trimmingCharacters(in: .whitespacesAndNewlines), to: 130)
        let bodyPara = NSMutableParagraphStyle()
        bodyPara.lineHeightMultiple = 1.6
        let bodyAttr = NSAttributedString(string: body, attributes: [
            .font: UIFont.serifItalic(size: 40),
            .foregroundColor: FilmPalette.serifInk,
            .paragraphStyle: bodyPara
        ])
        let bodyBlock = body.isEmpty ? 0 : ceil(bodyAttr.measure(width: bodyW).height) + 48

        let totalH = inset + FilmGeom.headerH + 30 + FilmGeom.perfHeight
            + photoH + FilmGeom.perfHeight + bodyBlock + 42 + 36 + inset
        let size = CGSize(width: W, height: max(1200, totalH))
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat1x())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            FilmPalette.bg.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            var y = inset
            drawFilmHeader(at: CGPoint(x: inset, y: y), width: bodyW, date: Date(), ctx: cg)
            y += FilmGeom.headerH + 30 + FilmGeom.perfHeight

            let photoRect = CGRect(x: inset, y: y, width: photoW, height: photoH)
            drawFilmPhoto(in: photoRect, image: image, ctx: cg)
            y += photoH + FilmGeom.perfHeight + 48

            if !body.isEmpty {
                let m = bodyAttr.measure(width: bodyW)
                bodyAttr.draw(with: CGRect(x: inset, y: y, width: bodyW, height: m.height),
                              options: [.usesLineFragmentOrigin], context: nil)
                y += ceil(m.height) + 42
            }

            let foot = NSAttributedString(string: truncate(footer, to: 70), attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 30, weight: .regular),
                .foregroundColor: FilmPalette.mutedGrey,
                .kern: 1.2
            ])
            foot.draw(at: CGPoint(x: inset, y: y))
        }
    }
}

// MARK: - Journal shared chrome
//
// JOURNAL (detail.jsx:904-933 / JournalTemplate.tsx). Cream #FBF6E8 paper with
// repeating 28pt ruled hairlines, a faint red left-margin line, two rotated
// washi-tape strips peeking over the top edge, a serif weekday title with a
// muted "· month day" subtitle, a 5:4 photo, the body, and a red-dot footer
// chip. Scaled ~3× from the 320pt web mock (20pt padding → 60pt inset).

private enum JournalGeom {
    static let inset: CGFloat = 60          // 20pt × 3
    static let rulePeriod: CGFloat = 84     // 28pt × 3
    static let marginX: CGFloat = 132       // 44pt × 3
}

private func drawJournalBackground(in size: CGSize, ctx cg: CGContext) {
    JournalPalette.bg.setFill()
    cg.fill(CGRect(origin: .zero, size: size))

    // Ruled lines: a 1.5pt hairline every 84pt (CSS 27/28 → ~28 period ×3).
    JournalPalette.rule.setFill()
    var ly: CGFloat = JournalGeom.rulePeriod
    while ly < size.height {
        cg.fill(CGRect(x: 0, y: ly, width: size.width, height: 3))
        ly += JournalGeom.rulePeriod
    }

    // Red left-margin line (CSS left:44px ×3).
    JournalPalette.marginLine.setFill()
    cg.fill(CGRect(x: JournalGeom.marginX, y: 0, width: 3, height: size.height))
}

private func drawJournalWashiTape(width: CGFloat, in cg: CGContext) {
    // Orange strip top-left, rotated -5° (CSS top:-6,left:30,90×18 ×3).
    drawWashiTape(center: CGPoint(x: 90 + 135, y: 6),
                  width: 270, height: 54,
                  rotation: -5 * .pi / 180,
                  color: JournalPalette.washiOrange, in: cg)
    // Green strip top-right, rotated +8° (CSS top:-4,right:24,64×14 ×3).
    drawWashiTape(center: CGPoint(x: width - 72 - 96, y: 12),
                  width: 192, height: 42,
                  rotation: 8 * .pi / 180,
                  color: JournalPalette.washiGreen, in: cg)
}

// MARK: - JournalMemoTemplate

enum JournalMemoTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .memo(let s) = payload else { return UIImage() }
        let temp = s.weather ?? ""
        return draw(body: s.body, date: s.createdAt, location: s.locationName,
                    temp: temp, image: s.coverImage)
    }

    static func draw(body rawBody: String, date: Date, location: String?,
                     temp: String, image: UIImage?) -> UIImage {
        let W = CardGeom.width
        let inset = JournalGeom.inset
        let bodyW = W - inset * 2

        let body = truncate(rawBody.trimmingCharacters(in: .whitespacesAndNewlines), to: 160)
        let bodyPara = NSMutableParagraphStyle()
        bodyPara.lineHeightMultiple = 1.7
        let bodyAttr = NSAttributedString(string: body, attributes: [
            .font: UIFont.systemFont(ofSize: 38, weight: .regular),
            .foregroundColor: JournalPalette.titleInk,
            .paragraphStyle: bodyPara
        ])
        let bodyMeasure = bodyAttr.measure(width: bodyW)

        let hasPhoto = image != nil
        let photoH: CGFloat = hasPhoto ? bodyW * 4.0 / 5.0 : 0   // 5:4 aspect
        let photoGap: CGFloat = hasPhoto ? 42 : 0

        let totalH = inset + 30 + 64 + 14 + 42      // top pad + title + divider
            + photoH + photoGap
            + ceil(bodyMeasure.height) + 42
            + 54 + inset                            // footer chip
        let size = CGSize(width: W, height: max(1200, totalH))
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat1x())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            drawJournalBackground(in: size, ctx: cg)
            drawJournalWashiTape(width: W, in: cg)

            var y = inset + 30

            // Serif title: weekday + muted "· month day"
            let title = NSAttributedString(string: journalWeekday(from: date), attributes: [
                .font: UIFont.editorialTitle(size: 64),
                .foregroundColor: JournalPalette.titleInk
            ])
            title.draw(at: CGPoint(x: inset, y: y))
            let tWidth = title.size().width
            let sub = NSAttributedString(string: "  \u{00B7} " + journalMonthDay(from: date), attributes: [
                .font: UIFont.systemFont(ofSize: 40, weight: .medium),
                .foregroundColor: JournalPalette.subInk
            ])
            sub.draw(at: CGPoint(x: inset + tWidth, y: y + 22))
            y += 64 + 14

            // Divider
            JournalPalette.divider.setFill()
            cg.fill(CGRect(x: inset, y: y, width: bodyW, height: 3))
            y += 42

            if let image = image {
                let photoRect = CGRect(x: inset, y: y, width: bodyW, height: photoH)
                cg.saveGState()
                UIBezierPath(roundedRect: photoRect, cornerRadius: 24).addClip()
                drawAspectFill(image, in: photoRect, ctx: cg)
                cg.restoreGState()
                y += photoH + photoGap
            }

            bodyAttr.draw(with: CGRect(x: inset, y: y, width: bodyW, height: bodyMeasure.height),
                          options: [.usesLineFragmentOrigin], context: nil)
            y += ceil(bodyMeasure.height) + 42

            // Footer: red dot + LOCATION · TEMP
            let dotSize: CGFloat = 30
            JournalPalette.redDot.setFill()
            cg.fillEllipse(in: CGRect(x: inset, y: y, width: dotSize, height: dotSize))
            var footParts: [String] = []
            if let l = location, !l.isEmpty { footParts.append(l.uppercased()) }
            if !temp.isEmpty { footParts.append(temp) }
            if footParts.isEmpty { footParts.append("VIENTIANE") }
            let foot = NSAttributedString(string: truncate(footParts.joined(separator: " \u{00B7} "), to: 50), attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 28, weight: .regular),
                .foregroundColor: JournalPalette.subInk,
                .kern: 1.2
            ])
            foot.draw(at: CGPoint(x: inset + dotSize + 16, y: y + 1))
        }
    }
}

// MARK: - JournalDailyTemplate

enum JournalDailyTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .daily(let s) = payload else { return UIImage() }
        let date = parseDailyDate(s.dateString)
        let loc = s.locationPrimary.isEmpty ? nil : s.locationPrimary
        return JournalMemoTemplate.draw(body: s.summary, date: date, location: loc,
                                        temp: "", image: s.coverImage)
    }
}

// MARK: - JournalPhotoTemplate

enum JournalPhotoTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .photo(let s) = payload else { return UIImage() }
        // PhotoSnapshot has no Date — use today's date for the title stamp; its
        // captured HH:mm/EXIF flavour lives in the footer location instead.
        return JournalMemoTemplate.draw(body: s.caption, date: Date(),
                                        location: s.location, temp: s.exif ?? "",
                                        image: s.image)
    }
}

// MARK: - Postcard shared chrome
//
// POSTCARD (detail.jsx:935-965 / PostcardTemplate.tsx). White card, 3:2 photo
// spanning the top, then a padded body section: a serif place name opposite a
// mono date over a dashed divider, then the body text beside a dashed stamp box
// (DAYPAGE / time / hairline / LAOS). Scaled ~3× from the 320pt web mock.

private enum PostcardGeom {
    static let pad: CGFloat = 54            // 18pt × 3
    static let stampW: CGFloat = 168        // 56pt × 3
    static let stampH: CGFloat = 192        // 64pt × 3
}

private func drawPostcardStamp(at origin: CGPoint, time: String, place: String, ctx cg: CGContext) {
    let rect = CGRect(x: origin.x, y: origin.y, width: PostcardGeom.stampW, height: PostcardGeom.stampH)
    strokeDashedRoundedRect(rect, radius: 12, lineWidth: 4.5,
                            dash: [12, 8], color: PostcardPalette.border, in: cg)

    // DAYPAGE (display, accent)
    let brand = NSAttributedString(string: "DAYPAGE", attributes: [
        .font: UIFont.systemFont(ofSize: 27, weight: .heavy),
        .foregroundColor: PostcardPalette.accent,
        .kern: 1
    ])
    let bsz = brand.size()
    brand.draw(at: CGPoint(x: rect.midX - bsz.width / 2, y: rect.minY + 36))

    // time (mono, muted)
    let timeAttr = NSAttributedString(string: time, attributes: [
        .font: UIFont.monospacedSystemFont(ofSize: 24, weight: .regular),
        .foregroundColor: PostcardPalette.muted
    ])
    let tsz = timeAttr.size()
    timeAttr.draw(at: CGPoint(x: rect.midX - tsz.width / 2, y: rect.minY + 78))

    // hairline (30pt ×3 = 90)
    PostcardPalette.border.setFill()
    cg.fill(CGRect(x: rect.midX - 45, y: rect.minY + 116, width: 90, height: 3))

    // place (mono, subtle)
    let placeAttr = NSAttributedString(string: place.uppercased(), attributes: [
        .font: UIFont.monospacedSystemFont(ofSize: 21, weight: .regular),
        .foregroundColor: PostcardPalette.subtle
    ])
    let psz = placeAttr.size()
    placeAttr.draw(at: CGPoint(x: rect.midX - psz.width / 2, y: rect.minY + 132))
}

// MARK: - PostcardMemoTemplate

enum PostcardMemoTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .memo(let s) = payload else { return UIImage() }
        let place = (s.locationName?.isEmpty == false ? s.locationName! : "Vientiane")
        let country = (s.locationName?.isEmpty == false) ? "" : "LAOS"
        return draw(body: s.body, date: s.createdAt, place: place,
                    country: country, image: s.coverImage)
    }

    static func draw(body rawBody: String, date: Date, place: String,
                     country: String, image: UIImage?) -> UIImage {
        let W = CardGeom.width
        let pad = PostcardGeom.pad

        // 3:2 photo across the full width.
        let photoH = W * 2.0 / 3.0
        let bodyW = W - pad * 2

        // Body sits left of the stamp; text column is bodyW - stamp - gap.
        let stampGap: CGFloat = 42
        let textColW = bodyW - PostcardGeom.stampW - stampGap

        let body = truncate(rawBody.trimmingCharacters(in: .whitespacesAndNewlines), to: 120)
        let bodyPara = NSMutableParagraphStyle()
        bodyPara.lineHeightMultiple = 1.6
        let bodyAttr = NSAttributedString(string: body, attributes: [
            .font: UIFont.systemFont(ofSize: 36, weight: .regular),
            .foregroundColor: PostcardPalette.serifInk,
            .paragraphStyle: bodyPara
        ])
        let bodyMeasure = bodyAttr.measure(width: textColW)

        // The text/stamp row height is the taller of the two columns.
        let rowH = max(ceil(bodyMeasure.height), PostcardGeom.stampH)
        let headerH: CGFloat = 64 + 30     // place/date row + dashed divider gap
        let totalH = photoH + pad + headerH + 42 + rowH + pad
        let size = CGSize(width: W, height: max(1100, totalH))
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat1x())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            PostcardPalette.bg.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            // 3:2 photo across the top
            let photoRect = CGRect(x: 0, y: 0, width: W, height: photoH)
            if let image = image {
                drawAspectFill(image, in: photoRect, ctx: cg)
            } else {
                PostcardPalette.photoBg.setFill()
                cg.fill(photoRect)
                let glyph = NSAttributedString(string: "\u{25A2}", attributes: [
                    .font: UIFont.systemFont(ofSize: 160, weight: .ultraLight),
                    .foregroundColor: PostcardPalette.iconStroke
                ])
                let gsz = glyph.size()
                glyph.draw(at: CGPoint(x: photoRect.midX - gsz.width / 2,
                                       y: photoRect.midY - gsz.height / 2))
            }

            var y = photoH + pad

            // Header: serif place name + mono date
            let placeAttr = NSAttributedString(string: truncate(place, to: 24), attributes: [
                .font: UIFont.editorialTitle(size: 60),
                .foregroundColor: PostcardPalette.serifInk
            ])
            placeAttr.draw(at: CGPoint(x: pad, y: y))

            let dateAttr = NSAttributedString(string: postcardDate(from: date), attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 28, weight: .regular),
                .foregroundColor: PostcardPalette.muted
            ])
            let dsz = dateAttr.size()
            dateAttr.draw(at: CGPoint(x: W - pad - dsz.width, y: y + 24))
            y += 64

            // Dashed divider
            drawDashedHLine(from: CGPoint(x: pad, y: y + 16), length: bodyW,
                            lineWidth: 3, dash: [9, 9], color: PostcardPalette.border, in: cg)
            y += 30 + 42

            // Body text (left) + stamp (right)
            bodyAttr.draw(with: CGRect(x: pad, y: y, width: textColW, height: bodyMeasure.height),
                          options: [.usesLineFragmentOrigin], context: nil)

            let stampX = pad + textColW + stampGap
            drawPostcardStamp(at: CGPoint(x: stampX, y: y),
                              time: headerTime(from: date),
                              place: country.isEmpty ? "LAOS" : country, ctx: cg)
        }
    }
}

// MARK: - PostcardDailyTemplate

enum PostcardDailyTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .daily(let s) = payload else { return UIImage() }
        let date = parseDailyDate(s.dateString)
        let place = s.locationPrimary.isEmpty ? "Vientiane" : s.locationPrimary
        let country = s.locationPrimary.isEmpty ? "LAOS" : ""
        return PostcardMemoTemplate.draw(body: s.summary, date: date, place: place,
                                         country: country, image: s.coverImage)
    }
}

// MARK: - PostcardPhotoTemplate

enum PostcardPhotoTemplate: PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage {
        guard case .photo(let s) = payload else { return UIImage() }
        let place = (s.location?.isEmpty == false ? s.location! : "Vientiane")
        let country = (s.location?.isEmpty == false) ? "" : "LAOS"
        // PhotoSnapshot has no Date; use today's date for the postcard stamp.
        return PostcardMemoTemplate.draw(body: s.caption, date: Date(), place: place,
                                         country: country, image: s.image)
    }
}

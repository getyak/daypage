import SwiftUI
import UIKit
import Photos
import ImageIO

// MARK: - SharePayload
//
// Payload describes WHAT is shared. PosterStyle describes HOW it is rendered.
// PosterTemplate is the (payload, style) -> UIImage renderer. ShareCardSheet
// is the SwiftUI host that previews + delivers the image to share/save targets.

enum SharePayload: Identifiable, Equatable {

    case memo(MemoSnapshot)
    case daily(DailySnapshot)
    case monthly(MonthlySnapshot)
    case quote(QuoteSnapshot)
    case photo(PhotoSnapshot)
    case voice(VoiceSnapshot)
    // Multi-memo collage: 2–6 memos rendered as a vertical IG-Story-style
    // stack with a shared header (date · location · count). Triggered by
    // the Today multi-select toolbar's "分享 N 项". Issue #309 W2.
    case collage(CollageSnapshot)

    var id: String {
        switch self {
        case .memo(let s):    return "memo-\(s.id.uuidString)"
        case .daily(let s):   return "daily-\(s.dateString)"
        case .monthly(let s): return "monthly-\(s.monthTitle)"
        case .quote(let s):   return "quote-\(s.id.uuidString)"
        case .photo(let s):   return "photo-\(s.id.uuidString)"
        case .voice(let s):   return "voice-\(s.id.uuidString)"
        case .collage(let s): return "collage-\(s.id.uuidString)"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .memo(let s):
            let where_ = s.locationName.map { " in \($0)" } ?? ""
            return "Memo card: \(s.body.prefix(80))\(where_)"
        case .daily(let s):
            return "Daily page card for \(s.dateString), \(s.memoCount) entries"
        case .monthly(let s):
            return "Monthly summary card: \(s.monthTitle), \(s.totalEntries) entries"
        case .quote(let s):
            return "Quote card: \(s.text.prefix(80))"
        case .photo(let s):
            return "Photo card: \(s.caption.prefix(80))"
        case .voice(let s):
            return "Voice memo card, duration \(s.duration)"
        case .collage(let s):
            return "Collage card with \(s.items.count) memos from \(s.dateLabel)"
        }
    }

    // MARK: - Smart dispatch
    //
    // Pick the most visually compelling default template for a memo, ranked
    // by sharability: photo > voice > plain text. Falls back to .memo if
    // the richer snapshots can't be built (missing files, decode failures).
    //
    // Users can still switch poster style inside ShareCardSheet — this only
    // chooses the *initial* payload so a tap stops forcing a content-type
    // decision before the sheet opens (issue #309 W1-②).
    static func auto(from memo: Memo) -> SharePayload {
        let hasPhoto = memo.attachments.contains { $0.kind == "photo" }
        let hasVoice = memo.attachments.contains { $0.kind == "audio" }

        if hasPhoto, let snap = PhotoSnapshot.from(memo) {
            return .photo(snap)
        }
        if hasVoice, let snap = VoiceSnapshot.from(memo) {
            return .voice(snap)
        }
        return .memo(MemoSnapshot.from(memo))
    }
}

// MARK: - Snapshots

struct MemoSnapshot: Equatable {
    let id: UUID
    let body: String
    let createdAt: Date
    let locationName: String?
    let weather: String?
    let coverImage: UIImage?
    let voiceDurationSeconds: Double?
    let memoType: String

    /// Build a snapshot, eagerly loading the first photo attachment so the
    /// Polaroid template renders an actual image — Evaluator HIGH must-fix:
    /// before this, both call sites passed coverImage:nil and Polaroid memos
    /// only ever showed a grey placeholder.
    static func from(_ memo: Memo) -> MemoSnapshot {
        let voiceDuration = memo.attachments
            .first(where: { $0.kind == "audio" })?
            .duration
        let cover = ShareCardImageLoader.firstPhoto(in: memo)
        return MemoSnapshot(
            id: memo.id,
            body: memo.body,
            createdAt: memo.created,
            locationName: memo.location?.name,
            weather: memo.weather,
            coverImage: cover,
            voiceDurationSeconds: voiceDuration,
            memoType: memo.type.rawValue.uppercased()
        )
    }
}

struct DailySnapshot: Equatable {
    let dateString: String
    let weekday: String
    let summary: String
    let locationPrimary: String
    let memoCount: Int
    let coverImage: UIImage?
    let highlights: [String]
    let sections: [SectionPreview]
    let photoCount: Int
    let voiceCount: Int
    let locationEntries: [String]

    struct SectionPreview: Equatable {
        let title: String
        let bodyPreview: String
    }

    static func from(_ model: DailyPageModel, rawMemos: [Memo] = []) -> DailySnapshot {
        let highlights = Array(model.sections.prefix(3).map { $0.title })
        let cover = ShareCardImageLoader.daily(model: model)
        let sections = model.sections.map {
            SectionPreview(title: $0.title, bodyPreview: String($0.body.prefix(120)))
        }
        let locEntries = model.locations.map { "\($0.time) · \($0.name)" }
        let photoCount = rawMemos.reduce(0) { $0 + $1.attachments.filter { $0.kind == "photo" }.count }
        let voiceCount = rawMemos.reduce(0) { $0 + $1.attachments.filter { $0.kind == "audio" }.count }
        return DailySnapshot(
            dateString: model.dateString,
            weekday: model.weekday.uppercased(),
            summary: model.summary,
            locationPrimary: model.locationPrimary,
            memoCount: model.memoCount,
            coverImage: cover,
            highlights: highlights,
            sections: sections,
            photoCount: photoCount,
            voiceCount: voiceCount,
            locationEntries: locEntries
        )
    }
}

// MARK: - ShareCardImageLoader
//
// Centralised, downsampled image loading from the vault. Returns `nil` on any
// failure (missing file, decode error) so renderers fall back to placeholder.
// Downsamples to ≤ 1500px on the long edge — bigger than the 1080 canvas to
// allow aspect-fill cropping without blur, smaller than full-res so memory
// stays under ~10MB per share-sheet open.

enum ShareCardImageLoader {

    private static let maxDimension: CGFloat = 1500

    static func firstPhoto(in memo: Memo) -> UIImage? {
        guard let att = memo.attachments.first(where: { $0.kind == "photo" }) else { return nil }
        return loadDownsampled(relativePath: att.file)
    }

    static func daily(model: DailyPageModel) -> UIImage? {
        guard let rel = model.coverAssetPath, !rel.isEmpty else { return nil }
        return loadDownsampled(relativePath: rel)
    }

    private static func loadDownsampled(relativePath: String) -> UIImage? {
        let url = VaultInitializer.vaultURL.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard
            let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct MonthlySnapshot: Equatable {
    let monthTitle: String
    let totalEntries: Int
    let totalPhotos: Int
    let totalVoiceMinutes: Int
    let totalLocations: Int
}

struct QuoteSnapshot: Equatable {
    let id: UUID
    let text: String
    let attribution: String

    init(id: UUID = UUID(), text: String, attribution: String) {
        self.id = id
        self.text = text
        self.attribution = attribution
    }
}

struct PhotoSnapshot: Equatable {
    let id: UUID
    let image: UIImage
    let caption: String
    let location: String?
    let time: String
    let exif: String?

    static func ==(lhs: PhotoSnapshot, rhs: PhotoSnapshot) -> Bool {
        lhs.id == rhs.id
    }

    static func from(_ memo: Memo) -> PhotoSnapshot? {
        guard memo.attachments.first(where: { $0.kind == "photo" }) != nil,
              let img = ShareCardImageLoader.firstPhoto(in: memo) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        let exif = buildExif(memo)
        return PhotoSnapshot(
            id: memo.id,
            image: img,
            caption: memo.body,
            location: memo.location?.name,
            time: f.string(from: memo.created),
            exif: exif
        )
    }

    private static func buildExif(_ memo: Memo) -> String? {
        guard let att = memo.attachments.first(where: { $0.kind == "photo" }) else { return nil }
        let url = VaultInitializer.vaultURL.appendingPathComponent(att.file)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        else { return nil }
        var parts: [String] = []
        if let f = exif[kCGImagePropertyExifFNumber as String] as? Double { parts.append("f/\(f)") }
        if let e = exif[kCGImagePropertyExifExposureTime as String] as? Double, e > 0, e.isFinite {
            let denom = Int((1.0 / e).rounded())
            parts.append("1/\(denom)s")
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first { parts.append("ISO \(iso)") }
        if let fl = exif[kCGImagePropertyExifFocalLength as String] as? Double { parts.append("\(Int(fl))mm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct VoiceSnapshot: Equatable {
    let id: UUID
    let duration: String
    let transcript: String
    let time: String
    let location: String?

    static func from(_ memo: Memo) -> VoiceSnapshot? {
        guard let att = memo.attachments.first(where: { $0.kind == "audio" }),
              let dur = att.duration else { return nil }
        let mins = Int(dur) / 60
        let secs = Int(dur) % 60
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        let transcript = att.transcript.map { String($0.prefix(200)) } ?? String(memo.body.prefix(200))
        return VoiceSnapshot(
            id: memo.id,
            duration: "\(mins):\(String(format: "%02d", secs))",
            transcript: transcript,
            time: f.string(from: memo.created),
            location: memo.location?.name
        )
    }
}

// MARK: - CollageSnapshot
//
// One CollageSnapshot bundles 2–6 memos plus a shared header (date / primary
// location / total count) so a renderer can produce a single composite share
// image instead of N separate cards.
//
// Each item is a thin preview: 80-char body excerpt, optional thumbnail
// (first photo, downsampled), short type label, time. The full MemoSnapshot
// is intentionally NOT carried — Collage cards are designed for at-a-glance
// readability at IG-Story size, not for reproducing every byte of every memo.

struct CollageSnapshot: Equatable {
    let id: UUID
    let dateLabel: String      // e.g. "2026·05·20"
    let weekday: String        // e.g. "WEDNESDAY"
    let primaryLocation: String?
    let items: [Item]

    struct Item: Equatable {
        let id: UUID
        let preview: String     // 80-char excerpt of memo body / transcript
        let kind: Kind          // text / photo / voice / mixed
        let time: String        // HH:mm
        let thumbnail: UIImage? // first photo if any, downsampled

        enum Kind: String, Equatable {
            case text, photo, voice, mixed
        }
    }

    /// Maximum number of memos a single collage can hold. Beyond this the
    /// IG-story canvas runs out of vertical room before the watermark and
    /// individual items shrink below readable thumbnail size. The caller
    /// (Today multi-select toolbar) gates the share button on `.items.count
    /// >= 2 && .items.count <= maxItems`.
    static let maxItems = 6

    static func from(_ memos: [Memo]) -> CollageSnapshot {
        // Sort by created date ascending so the collage reads chronologically
        // top-to-bottom — matches the timeline order users see in Today.
        let sorted = memos.sorted { $0.created < $1.created }

        let primary = sorted
            .compactMap { $0.location?.name }
            .first { !$0.isEmpty }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy·MM·dd"
        let weekdayDF = DateFormatter()
        weekdayDF.locale = Locale(identifier: "en_US_POSIX")
        weekdayDF.dateFormat = "EEEE"
        let timeDF = DateFormatter()
        timeDF.locale = Locale(identifier: "en_US_POSIX")
        timeDF.dateFormat = "HH:mm"

        let firstDate = sorted.first?.created ?? Date()

        let items: [Item] = sorted.prefix(maxItems).map { memo in
            let hasPhoto = memo.attachments.contains { $0.kind == "photo" }
            let hasAudio = memo.attachments.contains { $0.kind == "audio" }
            let kind: Item.Kind = {
                if hasPhoto && hasAudio { return .mixed }
                if hasPhoto { return .photo }
                if hasAudio { return .voice }
                return .text
            }()

            // For voice memos prefer transcript over body if transcript exists
            // and body is empty (the typical capture shape).
            let rawText: String = {
                if hasAudio, memo.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let t = memo.attachments.first(where: { $0.kind == "audio" })?.transcript {
                    return t
                }
                return memo.body
            }()
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = trimmed.count > 80
                ? String(trimmed.prefix(80)) + "\u{2026}"
                : trimmed

            return Item(
                id: memo.id,
                preview: preview,
                kind: kind,
                time: timeDF.string(from: memo.created),
                thumbnail: hasPhoto ? ShareCardImageLoader.firstPhoto(in: memo) : nil
            )
        }

        return CollageSnapshot(
            id: UUID(),
            dateLabel: df.string(from: firstDate),
            weekday: weekdayDF.string(from: firstDate).uppercased(),
            primaryLocation: primary,
            items: items
        )
    }
}

// MARK: - PosterStyle

enum PosterStyle: String, CaseIterable, Identifiable {
    case minimal  = "minimal"   // 极简编辑器风
    case polaroid = "polaroid"  // 拍立得风
    case film     = "film"      // 35mm 胶片风（暗场 + 齿孔）
    case journal  = "journal"   // 手账风（横线 + 和纸胶带）
    case postcard = "postcard"  // 明信片风（上图 + 邮票框）

    var id: String { rawValue }

    // Picker order mirrors detail.jsx:760 SHARE_TEMPLATES
    // (minimal, film, polaroid, journal, postcard).
    static var pickerOrder: [PosterStyle] { [.minimal, .film, .polaroid, .journal, .postcard] }

    var displayName: String {
        switch self {
        case .minimal:  return "极简"   // detail.jsx:761
        case .polaroid: return "拍立得"  // detail.jsx:761
        case .film:     return "胶片"   // detail.jsx:761
        case .journal:  return "手账"   // detail.jsx:761
        case .postcard: return "明信片"  // detail.jsx:761
        }
    }
}

// MARK: - PosterTemplate

protocol PosterTemplate {
    static func render(_ payload: SharePayload) -> UIImage
}

// MARK: - PosterDispatcher

enum PosterDispatcher {

    /// Routes (payload, style) → concrete `PosterTemplate.render`. Adding a new
    /// style means: extend `PosterStyle`, add template enums, add rows in this
    /// switch. Every (style × payload) pair MUST return a valid UIImage — no
    /// case may be left unhandled or crash.
    ///
    /// Collage currently only has one template (Minimal). Selecting any other
    /// style from the picker on a collage payload falls back to the Minimal
    /// renderer — the IG-Story-tall canvas doesn't have room for decorative
    /// frame chrome around 6 stacked items, and honouring the style would
    /// shrink each item below readable thumbnail size.
    ///
    /// The film / journal / postcard styles (detail.jsx:861-965) are designed
    /// around a single photo/text card, so dedicated renderers exist for the
    /// CORE share types — memo, daily, photo. For monthly / quote / voice the
    /// new styles fall back to the closest existing renderer (Minimal for the
    /// editorial film/postcard look, Polaroid for the warm journal look) so a
    /// shared card is still on-brand without 12 extra rarely-used templates.
    /// `colorScheme` is threaded through to `PosterRenderTrait` so the
    /// dynamic-provider UIColors in the palettes resolve to their dark
    /// variants when the sheet is rendered in dark mode. Default `.light`
    /// keeps existing call sites that don't pass a scheme source-compatible.
    static func render(
        payload: SharePayload,
        style: PosterStyle,
        colorScheme: PosterColorScheme = .light
    ) -> UIImage {
        return PosterRenderTrait.with(colorScheme: colorScheme) {
            renderInner(payload: payload, style: style)
        }
    }

    private static func renderInner(payload: SharePayload, style: PosterStyle) -> UIImage {
        switch (style, payload) {
        // MARK: Minimal
        case (.minimal,  .memo):    return MinimalMemoTemplate.render(payload)
        case (.minimal,  .daily):   return MinimalDailyTemplate.render(payload)
        case (.minimal,  .monthly): return MinimalMonthlyTemplate.render(payload)
        case (.minimal,  .quote):   return MinimalQuoteTemplate.render(payload)
        case (.minimal,  .photo):   return MinimalPhotoTemplate.render(payload)
        case (.minimal,  .voice):   return MinimalVoiceTemplate.render(payload)
        case (.minimal,  .collage): return MinimalCollageTemplate.render(payload)

        // MARK: Polaroid
        case (.polaroid, .memo):    return PolaroidMemoTemplate.render(payload)
        case (.polaroid, .daily):   return PolaroidDailyTemplate.render(payload)
        case (.polaroid, .monthly): return PolaroidMonthlyTemplate.render(payload)
        case (.polaroid, .quote):   return PolaroidQuoteTemplate.render(payload)
        case (.polaroid, .photo):   return PolaroidPhotoTemplate.render(payload)
        case (.polaroid, .voice):   return PolaroidVoiceTemplate.render(payload)
        case (.polaroid, .collage): return MinimalCollageTemplate.render(payload)

        // MARK: Film (dark gate, 35mm perforations)
        case (.film, .memo):     return FilmMemoTemplate.render(payload)
        case (.film, .daily):    return FilmDailyTemplate.render(payload)
        case (.film, .photo):    return FilmPhotoTemplate.render(payload)
        // Fallbacks: Minimal carries the editorial/quote/stat look closest to film.
        case (.film, .monthly):  return MinimalMonthlyTemplate.render(payload)
        case (.film, .quote):    return MinimalQuoteTemplate.render(payload)
        case (.film, .voice):    return MinimalVoiceTemplate.render(payload)
        case (.film, .collage):  return MinimalCollageTemplate.render(payload)

        // MARK: Journal (ruled paper, washi tape)
        case (.journal, .memo):     return JournalMemoTemplate.render(payload)
        case (.journal, .daily):    return JournalDailyTemplate.render(payload)
        case (.journal, .photo):    return JournalPhotoTemplate.render(payload)
        // Fallbacks: Polaroid's warm paper aesthetic is the nearest journal cousin.
        case (.journal, .monthly):  return PolaroidMonthlyTemplate.render(payload)
        case (.journal, .quote):    return PolaroidQuoteTemplate.render(payload)
        case (.journal, .voice):    return PolaroidVoiceTemplate.render(payload)
        case (.journal, .collage):  return MinimalCollageTemplate.render(payload)

        // MARK: Postcard (photo top, stamp box)
        case (.postcard, .memo):     return PostcardMemoTemplate.render(payload)
        case (.postcard, .daily):    return PostcardDailyTemplate.render(payload)
        case (.postcard, .photo):    return PostcardPhotoTemplate.render(payload)
        // Fallbacks: Minimal keeps the clean white postcard tone for the rest.
        case (.postcard, .monthly):  return MinimalMonthlyTemplate.render(payload)
        case (.postcard, .quote):    return MinimalQuoteTemplate.render(payload)
        case (.postcard, .voice):    return MinimalVoiceTemplate.render(payload)
        case (.postcard, .collage):  return MinimalCollageTemplate.render(payload)
        }
    }
}

// MARK: - ShareCardSheet

struct ShareCardSheet: View {

    let payload: SharePayload

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var style: PosterStyle = .minimal
    @State private var renderedImage: UIImage?
    @State private var showSystemShare = false
    @State private var savedToast: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {

                Group {
                    if let img = renderedImage {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: Color.black.opacity(0.10), radius: 12, x: 0, y: 4)
                            .accessibilityLabel(payload.accessibilityDescription)
                    } else {
                        ProgressView()
                            .frame(height: 460)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                stylePicker

                Spacer(minLength: 0)

                actionBar
            }
            .padding(.bottom, 16)
            .background(DSColor.bgWarm.ignoresSafeArea())
            .navigationTitle("分享卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(DSColor.inkPrimary)
                }
            }
            .overlay(alignment: .bottom) {
                if let toast = savedToast {
                    Text(toast)
                        .monoLabelStyle(size: 12)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        // #771: on-screen "saved" toast → glass engine
                        // (.toast). This overlay is screen-only, not part of
                        // the off-screen ImageRenderer export path.
                        .dpGlass(.toast, in: Capsule())
                        .padding(.bottom, 100)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: savedToast)
        }
        .task {
            await rerender()
        }
        .onChange(of: style) { _ in
            Task { await rerender() }
        }
        .onChange(of: colorScheme) { _ in
            // Re-render when the system flips light/dark so the off-screen
            // canvas picks up the new palette (#R2-CRITICAL).
            Task { await rerender() }
        }
        .sheet(isPresented: $showSystemShare) {
            if let img = renderedImage {
                ShareSheetView(activityItems: [img])
            }
        }
    }

    // Five style chips now exceed the screen width, so the picker scrolls
    // horizontally — mirrors the `overflowX:'auto'` row in detail.jsx:790.
    private var stylePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(PosterStyle.pickerOrder) { s in
                    Button {
                        Haptics.soft()
                        style = s
                    } label: {
                        Text(s.displayName)
                            .monoLabelStyle(size: 12)
                            .foregroundColor(style == s ? DSColor.glassHi : DSColor.inkPrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                style == s ? DSColor.amberDeep : DSColor.glassLo,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(s.displayName) 风格")
                    .accessibilityAddTraits(style == s ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                Haptics.tapConfirm()
                saveToPhotos()
            } label: {
                Label("保存到相册", systemImage: "square.and.arrow.down")
                    .monoLabelStyle(size: 12)
                    .foregroundColor(DSColor.inkPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .liquidGlassCard(cornerRadius: 10)
            }
            .buttonStyle(.plain)
            .disabled(renderedImage == nil)

            Button {
                Haptics.tapConfirm()
                showSystemShare = true
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
                    .monoLabelStyle(size: 12)
                    .foregroundColor(DSColor.glassHi)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        DSColor.amberDeep,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .disabled(renderedImage == nil)
        }
        .padding(.horizontal, 24)
    }

    @MainActor
    private func rerender() async {
        // Off-main rendering keeps the UI responsive on long memos. Rendering at
        // 1080 width is ~10-30ms but CJK + many highlights can spike it.
        let snapshot = (payload, style)
        // Capture the SwiftUI colorScheme on the main actor and translate it
        // for the renderer — UITraitCollection.current is per-thread, so the
        // detached Task needs an explicit value to set it from.
        let scheme: PosterColorScheme = colorScheme == .dark ? .dark : .light
        let img = await Task.detached(priority: .userInitiated) {
            PosterDispatcher.render(payload: snapshot.0, style: snapshot.1, colorScheme: scheme)
        }.value
        renderedImage = img
        Haptics.soft()
    }

    private func saveToPhotos() {
        guard let image = renderedImage else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in showToast("无相册权限") }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { ok, _ in
                Task { @MainActor in
                    showToast(ok ? "已保存到相册" : "保存失败")
                }
            }
        }
    }

    @MainActor
    private func showToast(_ text: String) {
        savedToast = text
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run { savedToast = nil }
        }
    }
}

// MARK: - ShareSheetView (lifted from ArchiveView)

struct ShareSheetView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

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

    var id: String {
        switch self {
        case .memo(let s):    return "memo-\(s.id.uuidString)"
        case .daily(let s):   return "daily-\(s.dateString)"
        case .monthly(let s): return "monthly-\(s.monthTitle)"
        case .quote(let s):   return "quote-\(s.id.uuidString)"
        case .photo(let s):   return "photo-\(s.id.uuidString)"
        case .voice(let s):   return "voice-\(s.id.uuidString)"
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

// MARK: - PosterStyle

enum PosterStyle: String, CaseIterable, Identifiable {
    case minimal  = "minimal"   // 极简编辑器风
    case polaroid = "polaroid"  // 拍立得/胶片风

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimal:  return "极简"
        case .polaroid: return "胶片"
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
    /// style means: extend `PosterStyle`, add 4 new template enums, add a row
    /// in this switch.
    static func render(payload: SharePayload, style: PosterStyle) -> UIImage {
        switch (style, payload) {
        case (.minimal,  .memo):    return MinimalMemoTemplate.render(payload)
        case (.minimal,  .daily):   return MinimalDailyTemplate.render(payload)
        case (.minimal,  .monthly): return MinimalMonthlyTemplate.render(payload)
        case (.minimal,  .quote):   return MinimalQuoteTemplate.render(payload)
        case (.minimal,  .photo):   return MinimalPhotoTemplate.render(payload)
        case (.minimal,  .voice):   return MinimalVoiceTemplate.render(payload)
        case (.polaroid, .memo):    return PolaroidMemoTemplate.render(payload)
        case (.polaroid, .daily):   return PolaroidDailyTemplate.render(payload)
        case (.polaroid, .monthly): return PolaroidMonthlyTemplate.render(payload)
        case (.polaroid, .quote):   return PolaroidQuoteTemplate.render(payload)
        case (.polaroid, .photo):   return PolaroidPhotoTemplate.render(payload)
        case (.polaroid, .voice):   return PolaroidVoiceTemplate.render(payload)
        }
    }
}

// MARK: - ShareCardSheet

struct ShareCardSheet: View {

    let payload: SharePayload

    @Environment(\.dismiss) private var dismiss
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
                        .background(.ultraThinMaterial, in: Capsule())
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
        .sheet(isPresented: $showSystemShare) {
            if let img = renderedImage {
                ShareSheetView(activityItems: [img])
            }
        }
    }

    private var stylePicker: some View {
        HStack(spacing: 12) {
            ForEach(PosterStyle.allCases) { s in
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
        let img = await Task.detached(priority: .userInitiated) {
            PosterDispatcher.render(payload: snapshot.0, style: snapshot.1)
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

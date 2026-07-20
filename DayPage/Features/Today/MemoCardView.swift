import SwiftUI
import ImageIO
import AVFoundation
import MapKit
import DayPageModels
import DayPageStorage
import DayPageServices

// MARK: - iCloud Download State

enum AttachmentDownloadState: Equatable {
    case notDownloaded
    case downloading
    case current
    case failed
}

// MARK: - MemoCardView

/// A single Memo rendered as a Liquid Glass card in the Today timeline.
struct MemoCardView: View {

    let memo: Memo
    var onDelete: (() -> Void)? = nil
    // US-014: called when user retries transcription for a failed voice attachment
    var onRetranscribe: ((Memo, Memo.Attachment) -> Void)? = nil

    @State private var showLocationSheet: Bool = false
    /// Which photo attachment the full-screen viewer is showing (nil = closed).
    /// item-based so each photo in a multi-photo memo opens its own viewer.
    struct PhotoViewerTarget: Identifiable {
        let file: String
        var id: String { file }
    }
    @State private var viewerPhoto: PhotoViewerTarget?
    @State private var downloadStates: [URL: AttachmentDownloadState] = [:]
    @State private var downloadTask: Task<Void, Never>? = nil

    /// Hero zoom (iOS 18+): shared between the in-card photo thumbnail
    /// (`matchedTransitionSource`) and the full-screen viewer
    /// (`navigationTransition(.zoom)`). The cover is presented from this
    /// view, so the namespace lives here. Inert on iOS 16–17.
    @Namespace private var photoZoomNamespace

    /// Precise 24h time for the content-first card meta line (rendered as "15·23").
    private static let cardTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = AppSettings.currentTimeZone()
        return f
    }()

    // MARK: - iCloud helpers

    private func attachmentDownloadState(for url: URL) -> AttachmentDownloadState {
        guard VaultInitializer.shared.isUsingiCloud else { return .current }
        if let state = downloadStates[url] { return state }
        guard let values = try? url.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey
        ]),
              let status = values.ubiquitousItemDownloadingStatus else { return .current }
        if values.ubiquitousItemIsDownloading == true { return .downloading }
        if status == .notDownloaded { return .notDownloaded }
        return .current
    }

    private func startDownload(_ url: URL) {
        guard VaultInitializer.shared.isUsingiCloud else { return }
        guard attachmentDownloadState(for: url) == .notDownloaded else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        downloadStates[url] = .downloading
        pollDownloadStatus(for: url)
    }

    // MARK: - Photo gallery

    /// Fixed thumbnail edge for the flomo-style gallery. Photos are footnotes
    /// to the prose, not the museum's main exhibit: a solo photo used to take
    /// a full-width 4:5 crop that swallowed the whole first screen. Now every
    /// photo is a small square chip that sits under the text, so a memo reads
    /// text-first and the timeline packs 2–3 memos per screen. Tapping any
    /// chip still hero-zooms to the full-screen viewer, where the original
    /// composition (and EXIF) lives.
    private static let thumbEdge: CGFloat = 112
    /// Edge for the 3-up strip — a touch smaller than the solo chip so three
    /// photos read as a set, not three solo photos in a row.
    private static let thumbEdgeSmall: CGFloat = 84
    /// Grid cell edge for 4+ photos — smaller still, so a multi-photo memo
    /// stays a compact contact sheet rather than towering over a 3-up memo.
    private static let thumbEdgeGrid: CGFloat = 74
    /// 4+ photos fold into a three-column grid of small squares; the last
    /// visible cell carries a "+N" scrim when the memo has more than 6.
    private static let gridMax = 6
    private static let galleryColumns = [
        GridItem(.fixed(Self.thumbEdgeGrid), spacing: 6),
        GridItem(.fixed(Self.thumbEdgeGrid), spacing: 6),
        GridItem(.fixed(Self.thumbEdgeGrid), spacing: 6)
    ]

    /// Count-aware photo layout. Every photo is a fixed-size 1:1 chip so the
    /// gallery never dictates card height — a solo photo is one small square,
    /// multiples tile into left-aligned rows / a 3-column grid.
    @ViewBuilder
    private func photoGallery(_ atts: [Memo.Attachment]) -> some View {
        switch atts.count {
        case 1:
            HStack(spacing: 0) {
                photoCell(atts[0], edge: Self.thumbEdge)
                Spacer(minLength: 0)
            }
        case 2:
            // Two photos use the mid (3-up) edge, not the solo 112: a pair of
            // full 112 chips runs nearly the card's width and reads as loud as
            // a single hero. The smaller edge keeps the diptych a footnote.
            HStack(spacing: 6) {
                photoCell(atts[0], edge: Self.thumbEdgeSmall)
                photoCell(atts[1], edge: Self.thumbEdgeSmall)
                Spacer(minLength: 0)
            }
        case 3:
            HStack(spacing: 6) {
                ForEach(atts, id: \.file) { att in
                    photoCell(att, edge: Self.thumbEdgeSmall)
                }
                Spacer(minLength: 0)
            }
        default:
            // Show up to `gridMax` chips; the last carries a "+N" overflow
            // scrim so the full count is never silently dropped.
            let shown = Array(atts.prefix(Self.gridMax))
            let overflow = atts.count - shown.count
            LazyVGrid(columns: Self.galleryColumns, alignment: .leading, spacing: 6) {
                ForEach(Array(shown.enumerated()), id: \.element.file) { idx, att in
                    let isLast = idx == shown.count - 1
                    photoCell(att,
                              edge: Self.thumbEdgeGrid,
                              overflowCount: (isLast && overflow > 0) ? overflow : 0)
                }
            }
        }
    }

    /// One photo cell: a fixed square thumbnail when the asset is local, a
    /// download placeholder otherwise. Hero-zoom identity stays the attachment
    /// relative path so every cell zooms from its own frame regardless of
    /// layout. `overflowCount > 0` draws a "+N" scrim (last grid cell only).
    @ViewBuilder
    private func photoCell(_ att: Memo.Attachment, edge: CGFloat, overflowCount: Int = 0) -> some View {
        let photoURL = VaultInitializer.vaultURL.appendingPathComponent(att.file)
        let photoState = attachmentDownloadState(for: photoURL)
        switch photoState {
        case .current:
            PhotoThumbnailView(fileURL: photoURL, aspect: 1.0, compact: true)
                .frame(width: edge, height: edge)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    // "+N more" scrim on the last grid cell — the tap still
                    // opens this photo's viewer; the timeline's detail flow is
                    // where the rest of the set is browsed.
                    if overflowCount > 0 {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.black.opacity(0.5))
                            Text("+\(overflowCount)")
                                .font(DSFonts.jetBrainsMono(size: 15, weight: .medium, relativeTo: .body))
                                .foregroundColor(.white)
                        }
                    }
                }
                .modifier(PhotoZoomSource(id: att.file, namespace: photoZoomNamespace))
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.tapConfirm()
                    viewerPhoto = PhotoViewerTarget(file: att.file)
                }
                .a11yButton(label: L10n.MemoCard.photoA11yLabel, hint: L10n.MemoCard.photoA11yHint)
        case .downloading, .notDownloaded, .failed:
            PhotoDownloadPlaceholder(state: photoState)
                .frame(width: edge, height: edge)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onAppear {
                    if photoState == .notDownloaded || photoState == .failed {
                        startDownload(photoURL)
                    }
                }
                .onTapGesture {
                    if photoState == .notDownloaded || photoState == .failed {
                        startDownload(photoURL)
                    }
                }
                .minTapTarget()
                .a11yButton(label: L10n.MemoCard.photoDownloadA11yLabel,
                            hint: L10n.MemoCard.downloadA11yHint)
        }
    }

    private func pollDownloadStatus(for url: URL) {
        guard downloadStates[url] == .downloading else { return }
        downloadTask = Task {
            for i in 0..<30 {
                // Fast pre-check on iteration 0 (download can be near-instant
                // for small files already staged by iOS) so we don't burn a
                // full 2s poll cycle when nothing needs waiting on.
                if i > 0 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }
                }
                if isAttachmentDownloaded(url) {
                    await MainActor.run { downloadStates[url] = .current }
                    return
                }
            }
            await MainActor.run { downloadStates[url] = .failed }
        }
    }

    private func isAttachmentDownloaded(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
              let status = values.ubiquitousItemDownloadingStatus else { return true }
        return status == .current || status == .downloaded
    }

    var body: some View {
        Group {
            if memo.type == .location {
                locationCard
            } else {
                standardCard
            }
        }
        .onDisappear { downloadTask?.cancel() }
    }

    // MARK: - Location Card

    private var locationCard: some View {
        HStack(spacing: 14) {
            // Amber pin icon
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DSColor.amberSoft)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(DSColor.amberRim, lineWidth: 0.5)
                    )
                    .frame(width: 44, height: 44)
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(DSColor.accentOnBg)
            }

            VStack(alignment: .leading, spacing: 3) {
                if let name = memo.location?.name, !name.isEmpty {
                    Text(name)
                        .font(DSType.serifBody16)
                        .foregroundColor(DSColor.inkPrimary)
                        .lineLimit(1)
                }
                let coord = coordinateString(memo.location)
                if !coord.isEmpty {
                    Text(coord)
                        .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundColor(DSColor.inkMuted)
                }
                Text(RelativeTimeFormatter.relative(memo.created))
                    .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundColor(DSColor.inkMuted)
                    .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .solidCard(cornerRadius: 14)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            if memo.location?.lat != nil { showLocationSheet = true }
        }
        .a11yButton(label: L10n.MemoCard.locationA11yLabel, hint: L10n.MemoCard.locationA11yHint)
        .sheet(isPresented: $showLocationSheet) {
            LocationPreviewSheet(location: memo.location, onDelete: onDelete)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Standard Card

    private var standardCard: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Voice card: quoted transcript style
            if memo.type == .voice || (memo.type == .mixed && memo.attachments.contains(where: { $0.kind == "audio" })) {
                if let att = memo.attachments.first(where: { $0.kind == "audio" }) {
                    let audioURL = VaultInitializer.vaultURL.appendingPathComponent(att.file)
                    let audioState = attachmentDownloadState(for: audioURL)
                    switch audioState {
                    case .current:
                        VoiceMemoPlayerRow(
                            fileURL: audioURL,
                            duration: att.duration ?? 0,
                            transcript: att.transcript,
                            transcriptionStatus: att.transcriptionStatus,
                            onRetranscribe: { onRetranscribe?(memo, att) }
                        )
                        .padding(.top, 4)
                    case .downloading, .notDownloaded, .failed:
                        AudioDownloadPlaceholder(state: audioState)
                            .padding(.top, 4)
                            .onAppear {
                                if audioState == .notDownloaded { startDownload(audioURL) }
                                else if audioState == .failed { startDownload(audioURL) }
                            }
                            .onTapGesture {
                                if audioState == .notDownloaded || audioState == .failed {
                                    startDownload(audioURL)
                                }
                            }
                            .minTapTarget()
                            .a11yButton(label: L10n.MemoCard.audioDownloadA11yLabel,
                                        hint: L10n.MemoCard.downloadA11yHint)
                    }
                }
            }

            // File attachments
            let fileAtts = memo.attachments.filter { $0.kind == "file" }
            if !fileAtts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(fileAtts, id: \.file) { att in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 12))
                                .foregroundColor(DSColor.inkMuted)
                            Text(att.transcript ?? URL(fileURLWithPath: att.file).lastPathComponent)
                                .font(DSFonts.jetBrainsMono(size: 11, relativeTo: .caption))
                                .foregroundColor(DSColor.inkMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 3)
                    }
                }
                .padding(.top, 8)
            }

            // Body text — serif
            let bodyTrimmed = memo.body.trimmingCharacters(in: .whitespacesAndNewlines)
            // Suppress body text when it is identical to an audio transcript
            // already shown in the VoiceMemoPlayerRow above.  The old check used
            // `memo.type == .voice`, which missed `.mixed` memos containing audio
            // + text; now we look for any audio attachment kind. (#US-016)
            let hasAudio = memo.attachments.contains(where: { $0.kind == "audio" })
            let isBodyDuplicate = hasAudio &&
                memo.attachments.contains(where: { att in
                    att.kind == "audio" &&
                    att.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) == bodyTrimmed &&
                    !bodyTrimmed.isEmpty
                })
            if !bodyTrimmed.isEmpty && !isBodyDuplicate {
                // Museum reading rhythm: tight leading. Design app.jsx:546-548
                // renders 16pt body at line-height 1.62; for SwiftUI's
                // *additive* lineSpacing that compact rhythm is ~2pt, not 6.
                Group {
                    if FeatureFlagStore.shared.isEnabled(.markdownRendering) {
                        // Markdown M1 — links render styled but inert here:
                        // the swipe overlay / card tap own this surface.
                        MarkdownBodyView(text: bodyTrimmed, lineSpacing: 2, linksActive: false)
                    } else {
                        // Render-only polish: CJK/Latin spacing; does not modify vault file.
                        Text(CJKTextPolish.polish(bodyTrimmed))
                            .font(DSType.serifBody16)
                            .foregroundColor(DSColor.inkPrimary)
                            .lineSpacing(2)
                    }
                }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                // NOTE: no contextMenu here. The swipe overlay above this
                // card owns the long press, so an inner menu could never be
                // summoned — Copy lives in TimelineRow's merged menu instead.
            }

            // Photo — a footnote to the prose, so it sits *under* the body as
            // a row of small square thumbnails (flomo rhythm) rather than a
            // full-width crop above it. Every photo attachment renders, not
            // just the first (a two-photo memo used to silently drop the
            // second image, which read as data loss). Tapping a chip
            // hero-zooms to the full-screen viewer where the original
            // composition and EXIF live.
            let photoAtts = memo.attachments.filter { $0.kind == "photo" }
            if !photoAtts.isEmpty {
                photoGallery(photoAtts)
                    .padding(.horizontal, 14)
                    .padding(.top, bodyTrimmed.isEmpty || isBodyDuplicate ? 14 : 10)
                    .fullScreenCover(item: $viewerPhoto) { target in
                        PhotoFullScreenViewer(
                            fileURL: VaultInitializer.vaultURL.appendingPathComponent(target.file),
                            exifText: PhotoThumbnailView.exifText(forRelativePath: target.file)
                        )
                        .modifier(PhotoZoomDestination(id: target.file, namespace: photoZoomNamespace))
                    }
            }

            // Bottom meta row — content-first: only a quiet mono timestamp.
            // Weather / location / type chip / a resting share button are all
            // hidden by the museum-aesthetic redesign: location & type live on
            // the detail page; share is the left-swipe action; power-user
            // overrides remain in the long-press contextMenu below.
            HStack(spacing: 8) {
                // Single line of metadata: precise 24h time as "15·23".
                let photoFlag = memo.attachments.contains { $0.kind == "photo" }
                let voiceFlag = memo.attachments.contains { $0.kind == "audio" }
                Text(Self.cardTimeFmt.string(from: memo.created).replacingOccurrences(of: ":", with: "·"))
                    .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                    // Tracking pulled from 1.6 → 1.2: the wide letter-spacing
                    // read as a terminal readout on a serif card (§4 type
                    // discipline — mono stays for the digits, but the spacing
                    // relaxes toward prose).
                    .tracking(1.2)
                    .foregroundColor(DSColor.inkMuted)

                // Tiny attachment glyphs hint content type without a loud chip.
                if photoFlag {
                    Image(systemName: "photo")
                        // 9pt (was 8) — 8pt SF Symbols fall below the legibility
                        // floor; 9pt keeps the quiet inkSubtle tone while letting
                        // the glyph optically match the 10pt mono timestamp.
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DSColor.inkMuted)
                }
                if voiceFlag {
                    Image(systemName: "mic")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DSColor.inkMuted)
                }

                Spacer(minLength: 4)
            }
            // Meta whispers, prose speaks — sink the whole timestamp row a
            // touch below inkSubtle so the memo body owns the card.
            .opacity(0.85)
            .padding(.horizontal, 14)
            // Density tightened one notch (§4): .top 10→8, .bottom 14→12, so a
            // short memo's net height drops and the timeline packs one more.
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard(cornerRadius: 14)
        // 2026-07-05 (#808): the template-override contextMenu (分享文本 /
        // 强制文字卡 / 强制照片卡 / 强制语音卡) and its sharePayload sheet were
        // removed as dead code — the swipe overlay above this card owns the
        // long press, so that menu was never reachable. Share flows live in
        // the left-swipe action and TimelineRow's merged long-press menu.
    }

    // MARK: - Helpers

    private func coordinateString(_ loc: Memo.Location?) -> String {
        guard let lat = loc?.lat, let lng = loc?.lng else { return "" }
        let latStr = String(format: "%.4f° %@", abs(lat), lat >= 0 ? "N" : "S")
        let lngStr = String(format: "%.4f° %@", abs(lng), lng >= 0 ? "E" : "W")
        return "\(latStr) · \(lngStr)"
    }

}

// MARK: - Photo hero zoom (iOS 18+)
//
// Photos-style hero: tapping the in-card thumbnail zooms the full-screen
// viewer out of the thumbnail frame; dismiss shrinks it back in. Mirrors the
// CardZoomSource / CardZoomDestination pattern in TodayView.swift, but keyed
// by the attachment's relative file path (String) so every photo has its own
// stable transition identity. Both halves read Reduce Motion and pass content
// through untouched when it is on — on iOS 16–17 (or with Reduce Motion) the
// fullScreenCover keeps its default presentation.

private struct PhotoZoomSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), !reduceMotion {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

private struct PhotoZoomDestination: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), !reduceMotion {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

// MARK: - PhotoFullScreenViewer

struct PhotoFullScreenViewer: View {

    let fileURL: URL
    let exifText: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var image: UIImage?
    @State private var isLoading: Bool = true

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    /// Live downward drag while at fit-scale, driving the interactive
    /// swipe-to-dismiss: the photo follows the finger and the black backdrop
    /// fades proportionally, so releasing past the threshold reads as the photo
    /// falling away (Apple Photos rubber-band dismiss) rather than a hard cut.
    @State private var dismissDragY: CGFloat = 0

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 4.0
    private let snapBackThreshold: CGFloat = 1.05

    var body: some View {
        ZStack {
            // Backdrop fades as the photo is dragged down toward dismissal, so
            // the underlying content shows through — the photo reads as lifting
            // off the page rather than a modal snapping shut.
            Color.black
                .opacity(Double(max(0, 1 - abs(dismissDragY) / 320)))
                .ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(.white)
            } else if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(x: offset.width, y: offset.height + dismissDragY)
                    .gesture(
                        SimultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    let newScale = lastScale * value
                                    scale = min(maxScale, max(minScale, newScale))
                                }
                                .onEnded { value in
                                    let newScale = lastScale * value
                                    if newScale < snapBackThreshold {
                                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75)) {
                                            scale = minScale
                                            offset = .zero
                                        }
                                        lastScale = minScale
                                        lastOffset = .zero
                                    } else {
                                        scale = min(maxScale, max(minScale, newScale))
                                        lastScale = scale
                                    }
                                },
                            DragGesture()
                                .onChanged { value in
                                    if scale > 1.0 {
                                        // Zoomed in — pan around the photo.
                                        offset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                    } else if value.translation.height > 0 {
                                        // At fit-scale, a downward drag is a
                                        // dismissal-in-progress: track the finger
                                        // 1:1 so the photo falls with it.
                                        dismissDragY = value.translation.height
                                    }
                                }
                                .onEnded { value in
                                    if scale <= 1.0 {
                                        let threshold: CGFloat = 120
                                        if value.translation.height > threshold
                                            || value.predictedEndTranslation.height > 260 {
                                            Haptics.light()
                                            dismiss()
                                        } else {
                                            // Below threshold — rubber-band the
                                            // photo and backdrop back to rest.
                                            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75)) {
                                                offset = .zero
                                                dismissDragY = 0
                                            }
                                            lastOffset = .zero
                                        }
                                    } else {
                                        lastOffset = offset
                                    }
                                }
                        )
                    )
                    // Double-tap to zoom: matches the iOS muscle memory for
                    // full-screen photos (pinch + swipe-to-dismiss were already
                    // here, but a quick double-tap was the missing reflex).
                    // Centered toggle between fit (1x) and 2x; reuses the existing
                    // snap spring and honors Reduce Motion. A two-finger pinch and
                    // a one-finger double-tap can't collide, so this composes
                    // cleanly with the SimultaneousGesture above.
                    .onTapGesture(count: 2) {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75)) {
                            if scale > 1.0 {
                                scale = minScale
                                offset = .zero
                            } else {
                                scale = 2.0
                            }
                        }
                        lastScale = scale
                        lastOffset = offset
                    }
            }

            // Close button — pinned inside safe area so it never overlaps
            // the Dynamic Island / notch on iPhone 14 Pro and later.
            VStack {
                HStack {
                    Spacer()
                    Button {
                        Haptics.soft()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(DSColor.amberSoft)
                            .padding(12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString(
                        "photo.viewer.close",
                        value: "关闭图片",
                        comment: "Full-screen photo viewer — close button a11y"
                    ))
                }
                Spacer()
            }
            .safeAreaInset(edge: .top) { EmptyView() }
            .padding(.top, 4)

            // EXIF caption. Gradient scrim strengthened from 0.7 → 0.85 so
            // mono10 uppercase reads cleanly against bright / low-contrast
            // photos too, without hiding image detail above the caption.
            if let exifText {
                VStack {
                    Spacer()
                    Text(exifText)
                        .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                        .tracking(0.5)
                        .textCase(.uppercase)
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            LinearGradient(
                                colors: [Color.clear, Color.black.opacity(0.85)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                }
            }
        }
        .task {
            isLoading = true
            image = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: fileURL) else { return nil }
                return UIImage(data: data)
            }.value
            isLoading = false
        }
    }
}

// MARK: - LocationPreviewSheet

struct LocationPreviewSheet: View {

    let location: Memo.Location?
    var onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = location?.lat, let lng = location?.lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let name = location?.name, !name.isEmpty {
                        Text(name)
                            .font(DSType.h2)
                            .foregroundColor(DSColor.inkPrimary)
                    } else {
                        Text("Location")
                            .font(DSType.h2)
                            .foregroundColor(DSColor.inkPrimary)
                    }
                    if let coord = coordinate {
                        Text(String(format: "%.5f°, %.5f°", coord.latitude, coord.longitude))
                            .font(DSFonts.jetBrainsMono(size: 11, relativeTo: .caption))
                            .foregroundColor(DSColor.inkMuted)
                    }
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DSColor.inkMuted)
                        .frame(width: 32, height: 32)
                        .background(DSColor.amberSoft)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider().background(DSColor.glassRim)

            if let coord = coordinate {
                MapPreviewView(coordinate: coord)
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "map")
                        .font(.system(size: 32))
                        .foregroundColor(DSColor.inkMuted)
                    Text("No coordinates")
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.inkMuted)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .background(DSColor.glassLo)
            }

            Divider().background(DSColor.glassRim)

            VStack(spacing: 0) {
                Button(action: openInAppleMaps) {
                    HStack(spacing: 10) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(DSColor.accentOnBg)
                        Text(NSLocalizedString("memo.detail.location.open_maps", comment: ""))
                            .font(DSType.titleSM)
                            .foregroundColor(DSColor.accentOnBg)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DSColor.inkMuted)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.plain)
                .disabled(coordinate == nil)

                if onDelete != nil {
                    Divider().padding(.horizontal, 20).background(DSColor.glassRim)
                    Button(action: { dismiss(); onDelete?() }) {
                        HStack(spacing: 10) {
                            Image(systemName: "trash")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(DSColor.statusError)
                            Text("Delete")
                                .font(DSType.titleSM)
                                .foregroundColor(DSColor.statusError)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(DSColor.glassStd)

            Spacer()
        }
        .background(DSColor.bgWarm.ignoresSafeArea())
    }

    private func openInAppleMaps() {
        guard let coord = coordinate else { return }
        if let url = URL(string: "maps://?ll=\(coord.latitude),\(coord.longitude)") {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - MapPreviewView

struct MapPreviewView: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.isUserInteractionEnabled = false
        map.showsUserLocation = false
        // Journal context, not a navigation surface — strip POI labels so the
        // street grid reads as a quiet etching instead of a business directory.
        map.pointOfInterestFilter = .excludingAll
        map.delegate = context.coordinator
        return map
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let region = MKCoordinateRegion(center: coordinate,
                                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        mapView.setRegion(region, animated: false)
        mapView.removeAnnotations(mapView.annotations)
        let pin = MKPointAnnotation()
        pin.coordinate = coordinate
        mapView.addAnnotation(pin)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let id = "memo.pin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            // Brand-amber dot with a white ring — the system red balloon is
            // the only off-palette element on an otherwise warm surface.
            let size: CGFloat = 16
            view.frame = CGRect(x: 0, y: 0, width: size, height: size)
            view.layer.cornerRadius = size / 2
            view.backgroundColor = UIColor(red: 0xA8 / 255, green: 0x54 / 255, blue: 0x1B / 255, alpha: 1)
            view.layer.borderColor = UIColor.white.cgColor
            view.layer.borderWidth = 2.5
            view.layer.shadowColor = UIColor.black.cgColor
            view.layer.shadowOpacity = 0.25
            view.layer.shadowRadius = 3
            view.layer.shadowOffset = CGSize(width: 0, height: 1)
            return view
        }
    }
}

// MARK: - VoiceMemoPlayerRow

struct VoiceMemoPlayerRow: View {

    let fileURL: URL
    let duration: TimeInterval
    let transcript: String?
    /// #821: per-attachment transcription state from the vault frontmatter
    /// (`transcription_status: pending|done|failed`). The transcribing /
    /// failed branches below key off THIS, not the global queue count — a
    /// stuck retry loop elsewhere in the queue must never freeze this card
    /// in a spinner (the exact failure observed in the 2026-07-11 audit).
    var transcriptionStatus: Memo.TranscriptionStatus? = nil
    // US-016: called when user taps retry on a failed transcript
    var onRetranscribe: (() -> Void)? = nil

    static let maxRetries = 3

    @State private var isPlaying: Bool = false
    @State private var isRetranscribing: Bool = false
    @State private var player: AVAudioPlayer?
    @State private var playbackProgress: Double = 0
    @State private var progressTimer: Timer?
    @State private var fileError: Bool = false
    @State private var isScrubbing: Bool = false
    /// Number of failed transcription attempts for this attachment. Persisted
    /// in UserDefaults so retry count survives the memo card going off-screen.
    @State private var retryCount: Int = 0

    private var retryKey: String { "voice.retry.\(fileURL.lastPathComponent)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Playback row
            HStack(spacing: 12) {
                Button(action: togglePlayback) {
                    ZStack {
                        Circle()
                            .fill(DSColor.amberSoft)
                            .overlay(Circle().strokeBorder(DSColor.amberRim, lineWidth: 0.5))
                            .frame(width: 36, height: 36)
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(fileError ? DSColor.inkSubtle : DSColor.accentOnBg)
                    }
                }
                .buttonStyle(.plain)
                .disabled(fileError)

                // Waveform is split into a static base layer + a progress-driven
                // mask layer. The base layer never re-renders during playback;
                // only the Rectangle inside the mask updates its scaleEffect
                // every 100 ms. Without this split, both 40-bar ForEach layers
                // were diffed on every progressTimer tick, dominating scroll
                // jank on tall voice memo cards.
                GeometryReader { geo in
                    WaveformView(
                        heights: waveformHeights,
                        progress: playbackProgress
                    )
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !isScrubbing {
                                    isScrubbing = true
                                    Haptics.soft()
                                }
                                let fraction = max(0, min(1, value.location.x / geo.size.width))
                                seek(to: fraction)
                            }
                            .onEnded { _ in
                                isScrubbing = false
                            }
                    )
                }
                .frame(height: 36)

                Text(formatDur(isPlaying ? duration * playbackProgress : duration))
                    .font(DSFonts.jetBrainsMono(size: 11, relativeTo: .caption))
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 36, alignment: .trailing)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)

            // Transcript (italic serif quote style — typographic curly quotes
            // rather than ASCII " to read as a real pull-quote when mixed
            // with CJK text).
            if let t = transcript, !t.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("\u{201C}")
                        .font(DSFonts.serif(size: 20, weight: .medium, relativeTo: .title3))
                        // Quote glyphs are decorative punctuation, not an accent.
                        // Mute to 50% ink so the transcript reads as a quiet
                        // pull-quote rather than two loud amber marks.
                        .foregroundColor(DSColor.inkMuted.opacity(0.5))
                        .offset(y: -2)
                    // Render-only polish: CJK/Latin spacing; does not modify vault file.
                    Text(CJKTextPolish.polish(t))
                        .font(DSType.serifQuote)
                        .foregroundColor(DSColor.inkMuted)
                        // 18pt italic pull-quote reads tight when it wraps; the
                        // 16pt body uses additive lineSpacing(2), so give the
                        // larger italic quote a touch more air (4pt) to breathe.
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = t
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                            }
                            // Long-press to re-run transcription even on an
                            // already-transcribed clip. The live-stream draft is
                            // fast but occasionally rougher than the flash file
                            // pass; this lets the user upgrade it on demand
                            // instead of being stuck with the first result.
                            if onRetranscribe != nil {
                                Button {
                                    isRetranscribing = true
                                    onRetranscribe?()
                                } label: {
                                    Label(NSLocalizedString("voice.retry.rerun", value: "重新转写", comment: "Re-run transcription on an already-transcribed clip"), systemImage: "arrow.clockwise")
                                }
                            }
                        }
                    Text("\u{201D}")
                        .font(DSFonts.serif(size: 20, weight: .medium, relativeTo: .title3))
                        .foregroundColor(DSColor.inkMuted.opacity(0.5))
                        .offset(y: -2)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
                // #821 ink-bloom reveal: the finished transcript settles in
                // like ink spreading on paper — blur 6→0 + rise 4pt + fade.
                // Replaces the hard pop when the shimmer skeleton swapped to
                // text. Honors Reduce Motion via the transition's insertion
                // being driven by Motion.rise below.
                .transition(TranscriptBloom.transition)
            } else if transcript == nil {
                if transcriptionStatus == .pending || isRetranscribing {
                    // #821: breathing skeleton lines, not a spinner — this is
                    // "becoming text", not "loading". Keyed to THIS
                    // attachment's status so a stuck queue can never freeze
                    // the card (was: global pendingCount > 0).
                    TranscriptShimmerPlaceholder()
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                        .accessibilityLabel(NSLocalizedString("voice.retry.transcribing", comment: ""))
                } else if retryCount >= Self.maxRetries {
                    // US-016: permanent failure after max retries
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DSColor.errorRed)
                        Text(NSLocalizedString("voice.retry.failed_permanent", comment: ""))
                            .font(DSType.bodySM)
                            .foregroundColor(DSColor.errorRed)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    .accessibilityLabel(NSLocalizedString("voice.retry.failed_permanent_a11y", comment: ""))
                } else {
                    // US-016: retry button with attempt counter
                    Button {
                        retryCount += 1
                        UserDefaults.standard.set(retryCount, forKey: retryKey)
                        isRetranscribing = true
                        onRetranscribe?()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                            Text(retryCount == 0
                                 ? NSLocalizedString("voice.retry.button", comment: "")
                                 : String(format: NSLocalizedString("voice.retry.button_attempt", comment: ""), retryCount + 1, Self.maxRetries))
                                .font(DSType.bodySM)
                        }
                        .foregroundColor(DSColor.accentOnBg)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    .accessibilityLabel(NSLocalizedString("voice.retry.button_a11y", comment: ""))
                }
            }
        }
        .onAppear {
            retryCount = UserDefaults.standard.integer(forKey: retryKey)
        }
        // Drives the shimmer→transcript bloom (and shimmer→retry downgrade)
        // through one calm curve; without this the .transition above never
        // animates because the state change itself would be un-animated.
        .animation(Motion.rise, value: transcript)
        .animation(Motion.fade, value: transcriptionStatus)
        .onChange(of: transcript) { newValue in
            // When transcription succeeds, also clear the persisted retry counter
            // so future failures start over from attempt #1. Previously this
            // handler only reset `isRetranscribing`, which left retryCount frozen
            // at 3 and the card permanently stuck at "Transcription unavailable"
            // even when transcription had actually succeeded.
            if newValue != nil {
                isRetranscribing = false
                retryCount = 0
                UserDefaults.standard.removeObject(forKey: retryKey)
            }
        }
        .onDisappear { stopPlayback() }
    }

    private var waveformHeights: [CGFloat] {
        let seed = abs(fileURL.hashValue)
        return (0..<40).map { i in CGFloat(3 + ((seed >> i) & 0x1F) % 20) }
    }

    private func togglePlayback() {
        isPlaying ? stopPlayback() : startPlayback()
    }

    private func startPlayback() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { fileError = true; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: fileURL)
            p.play()
            player = p
            isPlaying = true
            playbackProgress = 0
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] _ in
                Task { @MainActor in
                    guard let p = player, p.isPlaying else { stopPlayback(); return }
                    // Skip timer write while the finger is scrubbing so the
                    // timer doesn't fight the gesture's progress updates.
                    guard !isScrubbing else { return }
                    // Disable implicit animation: if a parent withAnimation()
                    // block is still in flight when this assignment runs (e.g.
                    // a swipe spring), SwiftUI would otherwise interpolate
                    // playbackProgress across multiple frames per tick and
                    // schedule extra layout passes during the swipe.
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        playbackProgress = p.duration > 0 ? p.currentTime / p.duration : 0
                    }
                }
            }
        } catch { fileError = true }
    }

    private func seek(to fraction: Double) {
        let clampedFraction = max(0, min(1, fraction))
        if player == nil {
            // No active player — prepare, seek, then play so the audio engine
            // starts at the tapped position instead of briefly playing from 0.
            // If setup fails, clear isScrubbing so the gesture doesn't stall.
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                fileError = true; isScrubbing = false; return
            }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                let p = try AVAudioPlayer(contentsOf: fileURL)
                p.prepareToPlay()
                p.currentTime = clampedFraction * p.duration
                p.play()
                player = p
                isPlaying = true
                playbackProgress = clampedFraction
                progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] _ in
                    Task { @MainActor in
                        guard let p = player, p.isPlaying else { stopPlayback(); return }
                        guard !isScrubbing else { return }
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) {
                            playbackProgress = p.duration > 0 ? p.currentTime / p.duration : 0
                        }
                    }
                }
            } catch { fileError = true; isScrubbing = false }
            return
        }
        guard let p = player else { return }
        p.currentTime = clampedFraction * p.duration
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            playbackProgress = clampedFraction
        }
    }

    private func stopPlayback() {
        player?.stop(); player = nil
        progressTimer?.invalidate(); progressTimer = nil
        isPlaying = false; playbackProgress = 0
    }

    private func formatDur(_ secs: TimeInterval) -> String {
        secs.mmss
    }
}

// MARK: - WaveformView
//
// Extracted from VoiceMemoPlayerRow so that the 40-bar base layer is built
// once per cell (Equatable diff on `heights`) and only the progress mask
// re-renders on the 100 ms playback timer. The .transaction modifier strips
// any implicit animation propagated from the parent (cell mount, list
// shuffle, layout pass), keeping the mask scale change instantaneous and
// preventing SwiftUI from interpolating progress between ticks — which used
// to interleave dozens of intermediate render passes with scroll gestures.
private struct WaveformView: View, Equatable {

    let heights: [CGFloat]
    let progress: Double

    // Equatable: only re-diff when progress or the underlying heights change.
    // heights is a value-typed [CGFloat], so == is structural; cheap because
    // we have 40 elements.
    static func == (lhs: WaveformView, rhs: WaveformView) -> Bool {
        lhs.heights == rhs.heights && lhs.progress == rhs.progress
    }

    var body: some View {
        ZStack(alignment: .leading) {
            WaveformBars(heights: heights, color: DSColor.inkFaint)
                .equatable()
            WaveformBars(heights: heights, color: DSColor.accentOnBg)
                .equatable()
                .mask(alignment: .leading) {
                    GeometryReader { geo in
                        Rectangle()
                            .frame(width: max(0, geo.size.width * CGFloat(progress)))
                    }
                }
                .transaction { $0.animation = nil }
        }
    }
}

// Base bar layer — Equatable so SwiftUI skips the ForEach diff when the
// heights array is unchanged (always, for a given fileURL).
private struct WaveformBars: View, Equatable {

    let heights: [CGFloat]
    let color: Color

    static func == (lhs: WaveformBars, rhs: WaveformBars) -> Bool {
        lhs.color == rhs.color && lhs.heights == rhs.heights
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 2.5, height: h)
            }
        }
    }
}

// MARK: - DailyPageEntryCard

/// Compiled-day hero card — Liquid Glass amber style.
struct DailyPageEntryCard: View {
    let summary: String?
    /// Ribbon line above the serif excerpt. Defaults to the "today" wording;
    /// the Yesterday section passes its own so the card never contradicts
    /// its section header (the old hardcoded "Today's page compiled" did).
    var ribbonText: String = NSLocalizedString(
        "today.card.compiled.today",
        comment: "Compiled-page card ribbon for today's own page")
    /// Quiet meta coda ("6 条 memo") so the ribbon-only form still carries
    /// information when the page has no summary. nil hides the line.
    var metaText: String? = nil
    var onTap: (() -> Void)?

    private var hasSummary: Bool {
        guard let summary else { return false }
        return !summary.isEmpty
    }

    var body: some View {
        Button(action: { onTap?() }) {
            // Content-first: the compiled page speaks through its own serif
            // opening line. No trailing arrow (the whole card is the tap
            // target) and no "digest is ready" meta copy — without a summary
            // the card collapses to the quiet ribbon line.
            VStack(alignment: .leading, spacing: 6) {
                // Amber dot + label
                HStack(spacing: 6) {
                    Circle()
                        .fill(DSColor.accentOnBg)
                        .frame(width: 6, height: 6)
                        .shadow(color: DSColor.amberGlow, radius: 4, x: 0, y: 0)
                    Text(ribbonText)
                        .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                        .tracking(1)
                        .textCase(.uppercase)
                        .foregroundColor(DSColor.accentOnBg)
                }

                if let summary, hasSummary {
                    Text(summary)
                        .font(DSType.serifBody18)
                        .foregroundColor(DSColor.inkPrimary)
                        .lineLimit(2)
                        .lineSpacing(2)
                }

                if let metaText, !metaText.isEmpty {
                    // §4 number discipline: this coda carries a count ("6 条
                    // memo"), so it joins the mono family with the rest of the
                    // app's numerals instead of sitting in Inter.
                    Text(metaText)
                        .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                        .tracking(0.4)
                        .foregroundColor(DSColor.inkMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, hasSummary ? 18 : 14)
            .frame(maxWidth: .infinity)
            .liquidGlassCard(cornerRadius: 18, tone: .hi)
            .overlay(alignment: .leading) {
                // Left amber accent strip — only alongside serif prose. On
                // the compact ribbon-only form (~44pt tall) the 14pt vertical
                // insets squeeze it to a stub that reads as a glitch.
                if hasSummary {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [DSColor.accentOnBg, DSColor.accentOnBg.opacity(0)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        // Unify accent-rail width across cards. Design app.jsx:420
                        // renders the rail at 2px; AISummaryCard already uses 2.
                        .frame(width: 2)
                        .padding(.vertical, 14)
                        .padding(.leading, 0)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - CompilePromptCard

struct CompilePromptCard: View {
    let memoCount: Int
    var isCompiling: Bool = false
    var onCompile: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isCompiling ? DSColor.amberSoft : DSColor.glassLo)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isCompiling ? DSColor.amberRim : DSColor.glassRim, lineWidth: 0.5)
                    )
                    .frame(width: 44, height: 44)
                if isCompiling {
                    ProgressView().scaleEffect(0.7).tint(DSColor.accentOnBg)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18))
                        .foregroundColor(DSColor.inkMuted)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if isCompiling {
                    Text("Compiling \(memoCount) memos…")
                        .font(DSFonts.spaceGrotesk(size: 13, weight: .semibold, relativeTo: .footnote))
                        .textCase(.uppercase)
                        .tracking(1)
                        .foregroundColor(DSColor.accentOnBg)
                } else if memoCount > 0 {
                    Text(NSLocalizedString("memocard.state.ready", comment: "Ready to compile"))
                        .font(DSFonts.spaceGrotesk(size: 13, weight: .semibold, relativeTo: .footnote))
                        .textCase(.uppercase)
                        .tracking(1)
                        .foregroundColor(DSColor.inkMuted)
                    Text(String(format: NSLocalizedString("memocard.state.captured", comment: "N signals captured today"), memoCount))
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.inkMuted)
                } else {
                    Text(NSLocalizedString("memocard.state.empty", comment: "Start capturing"))
                        .font(DSFonts.spaceGrotesk(size: 13, weight: .semibold, relativeTo: .footnote))
                        .textCase(.uppercase)
                        .tracking(1)
                        .foregroundColor(DSColor.inkMuted)
                    Text(NSLocalizedString("memocard.state.tonight", comment: "Signals will compile tonight"))
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.inkMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isCompiling && memoCount > 0 {
                Button(action: { onCompile?() }) {
                    Text(NSLocalizedString("memocard.cta.compile", comment: "Compile CTA"))
                        .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundColor(DSColor.bgWarm)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(DSColor.amberDeep)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .liquidGlassCard(cornerRadius: 18)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isCompiling)
    }
}

// MARK: - Photo Placeholders

struct PhotoDownloadPlaceholder: View {
    let state: AttachmentDownloadState

    // The gallery now sizes every cell to a fixed ~92–112pt square, so the
    // placeholder fills that frame with just a glyph — the old 160pt-tall
    // block with a caption line would overflow a 112pt chip. VoiceOver still
    // announces the download state via the cell's a11y label.
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DSColor.glassLo)
            switch state {
            case .notDownloaded:
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(DSColor.inkMuted)
            case .downloading:
                ProgressView().tint(DSColor.inkSubtle)
            case .failed:
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(DSColor.accentOnBg)
            case .current:
                EmptyView()
            }
        }
    }
}

// MARK: - Thumbnail Cache

// Process-level cache for decoded photo thumbnails.
// NSCache automatically evicts entries under memory pressure — but leaving
// the cache unbounded meant a scroll through 100 photos could pin ~500MB of
// UIImages until iOS forced a purge, at which point every visible thumbnail
// would reload mid-scroll. Pinning the limits keeps working-set steady.
private let thumbnailCache: NSCache<NSURL, UIImage> = {
    let cache = NSCache<NSURL, UIImage>()
    cache.countLimit = 100                     // ~two full timeline pages of photos
    cache.totalCostLimit = 50 * 1024 * 1024    // 50MB decoded — well below MemoryWarn threshold
    return cache
}()

struct PhotoThumbnailView: View {
    let fileURL: URL
    /// Aspect the cell crops to. Solo photos keep the museum 4:5 portrait;
    /// grid cells use 1:1 so multi-photo memos stay height-bounded.
    var aspect: CGFloat = 4.0 / 5.0
    /// Compact grid cells drop the EXIF caption and zoom badge — at half
    /// width or less they read as clutter, and tap-to-zoom still works.
    var compact: Bool = false
    /// Self-owned: each thumbnail in a multi-photo memo decodes and caches
    /// independently (a shared parent binding made siblings overwrite each
    /// other). EXIF caption loads with the decode, off the main actor —
    /// reading image properties in the card's `body` was synchronous disk
    /// I/O on every re-render.
    @State private var thumbnail: UIImage?
    @State private var exifText: String?

    var body: some View {
        Group {
            if let thumb = thumbnail {
                // Design app.jsx:527 — CafePhoto renders a fixed 4:5 portrait
                // crop. Enforce the same aspect with a fill so the museum
                // timeline keeps a consistent photo rhythm instead of letting
                // each image dictate its own height.
                // The 4:5 frame must be owned by a container with the image as
                // an overlay: a bare `.fill` image reports its oversized width
                // up the modifier chain, so `.clipped()` had nothing to clip
                // and landscape photos blew the card out past the screen edge.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .aspectRatio(aspect, contentMode: .fit)
                    .overlay {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
            } else {
                Rectangle()
                    .fill(DSColor.glassLo)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(aspect, contentMode: .fit)
            }
        }
        .task(id: fileURL) {
            // Fast path: if the process cache already has this thumb, use it
            // directly and skip the nil-then-set flicker. Only clear when the
            // decode has to hit disk, so returning to a previously-viewed
            // photo shows it instantly.
            let cacheKey = fileURL as NSURL
            if let cached = thumbnailCache.object(forKey: cacheKey) {
                if thumbnail !== cached { thumbnail = cached }
            } else {
                thumbnail = nil
                thumbnail = await loadThumbnailAsync(from: fileURL)
            }
            // EXIF caption is only rendered on non-compact cells (the caption
            // overlay below is gated on `!compact`). Every card thumbnail is
            // now compact, so reading EXIF here was pure wasted disk I/O —
            // one extra CGImageSource open + property parse per chip, ×N
            // photos, on the scroll path. Skip it unless the caption will show.
            if !compact {
                let url = fileURL
                exifText = await Task.detached(priority: .utility) {
                    Self.exifText(for: url)
                }.value
            }
        }
        .overlay(alignment: .bottom) {
            if let exifText, !compact {
                Text(exifText)
                    .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundColor(DSColor.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(
                            colors: [Color.clear, DSColor.glassHi],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            }
        }
        // Small "tap to zoom" affordance in the top-right corner. The gallery
        // now renders every card photo as a small square chip, so the badge
        // shrinks with it — it's the only cue that the chip opens the original
        // composition full-screen. EXIF and the full crop live in the viewer.
        .overlay(alignment: .topTrailing) {
            if thumbnail != nil {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(4)
                    .background(
                        Circle().fill(Color.black.opacity(0.4))
                    )
                    .padding(5)
                    .accessibilityHidden(true)
            }
        }
    }

    /// A film-strip caption of *real* camera parameters — e.g. "26MM · F/1.8".
    /// Metadata-only read (no pixel decode), but still disk I/O — call off the
    /// main actor.
    ///
    /// Deliberately returns `nil` when no meaningful EXIF is present. The raw
    /// filename (`IMG_2043.JPG`, `WECHAT_XXX.JPG`, a screenshot's name) must
    /// never surface as a caption: it reads as a debug watermark, not a photo
    /// credit, and leaks the file system into the museum surface. No params →
    /// no caption at all. Formatting is shared with the detail-view overlay via
    /// `MemoExifFormat`, which also carries the EXIF→Int crash guards.
    static func exifText(for fileURL: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        else { return nil }

        var parts: [String] = []
        if let focal = exif[kCGImagePropertyExifFocalLength as String] as? Double,
           let label = MemoExifFormat.focalLengthLabel(focal) {
            parts.append(label)
        }
        if let aperture = exif[kCGImagePropertyExifFNumber as String] as? Double,
           let label = MemoExifFormat.apertureLabel(aperture) {
            parts.append(label)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Convenience for callers that hold a vault-relative path (viewer).
    static func exifText(forRelativePath relative: String) -> String? {
        exifText(for: VaultInitializer.vaultURL.appendingPathComponent(relative))
    }

    private func loadThumbnailAsync(from url: URL) async -> UIImage? {
        // Check process-level cache first to avoid redundant disk reads.
        let cacheKey = url as NSURL
        if let cached = thumbnailCache.object(forKey: cacheKey) { return cached }

        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                // Card thumbnails now top out at a 112pt chip (~336px @3x); the
                // old 600px target decoded ~3× the pixels the timeline can show,
                // burning CPU on every scroll-in and inflating the cache. 448px
                // keeps a retina-crisp chip with headroom for Dynamic Type. The
                // full-screen viewer decodes the original separately, so zoom
                // fidelity is untouched.
                kCGImageSourceThumbnailMaxPixelSize: 448
            ]
            let image: UIImage?
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
                // Decode-on-load: force the bitmap now, off the main actor, so
                // the first scroll frame that shows this chip isn't stalled by a
                // lazy CA decode. `kCGImageSourceShouldCacheImmediately` +
                // reading the pixels here moves that cost off the render path.
                image = UIImage(cgImage: cgThumb)
            } else {
                image = UIImage(data: data)
            }
            if let image {
                // Cost the entry by its real pixel footprint so NSCache's
                // totalCostLimit (50MB) actually bounds the working set —
                // setObject without a cost made the byte limit a no-op.
                let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
                thumbnailCache.setObject(image, forKey: cacheKey, cost: cost)
            }
            return image
        }.value
    }
}

// MARK: - AudioDownloadPlaceholder

// MARK: - Transcript Shimmer & Bloom (#821)

/// Two breathing skeleton lines shown while an audio attachment is being
/// transcribed. Deliberately NOT a spinner: the memo is already safe on
/// disk, so the affordance reads as "text is forming", with the calm of the
/// museum surface. Static under Reduce Motion.
struct TranscriptShimmerPlaceholder: View {
    @State private var bright = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            skeletonLine(widthFraction: 0.92)
            skeletonLine(widthFraction: 0.58)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                bright = true
            }
        }
        .accessibilityElement(children: .ignore)
    }

    private func skeletonLine(widthFraction: CGFloat) -> some View {
        GeometryReader { geo in
            Capsule(style: .continuous)
                .fill(DSColor.inkFaint.opacity(bright ? 0.55 : 0.28))
                .frame(width: geo.size.width * widthFraction)
        }
        .frame(height: 9)
    }
}

/// Ink-bloom transition for a freshly arrived transcript: blur 6→0, rise
/// 4pt, fade in — the text settles like ink spreading into paper.
enum TranscriptBloom {
    static var transition: AnyTransition {
        .modifier(
            active: BloomModifier(blur: 6, opacity: 0, offsetY: 4),
            identity: BloomModifier(blur: 0, opacity: 1, offsetY: 0)
        )
    }

    struct BloomModifier: ViewModifier {
        let blur: CGFloat
        let opacity: Double
        let offsetY: CGFloat
        func body(content: Content) -> some View {
            content
                .blur(radius: blur)
                .opacity(opacity)
                .offset(y: offsetY)
        }
    }
}

struct AudioDownloadPlaceholder: View {
    let state: AttachmentDownloadState

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DSColor.glassLo)
                    .frame(width: 36, height: 36)
                switch state {
                case .notDownloaded:
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DSColor.inkMuted)
                case .downloading:
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(DSColor.inkSubtle)
                case .failed:
                    Image(systemName: "exclamationmark.icloud")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DSColor.accentOnBg)
                case .current:
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DSColor.inkMuted)
                }
            }
            HStack(spacing: 2) {
                ForEach(0..<36, id: \.self) { i in
                    let h = CGFloat(3 + (i % 6) * 3)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(DSColor.inkFaint)
                        .frame(width: 2.5, height: h)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch state {
            case .notDownloaded:
                Text("icloud")
                    .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 36, alignment: .trailing)
            case .downloading:
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(DSColor.inkSubtle)
                    .frame(width: 36, alignment: .trailing)
            case .failed:
                Text("retry")
                    .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                    .foregroundColor(DSColor.accentOnBg)
                    .frame(width: 36, alignment: .trailing)
            case .current:
                Text("--:--")
                    .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

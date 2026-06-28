import SwiftUI
import ImageIO
import AVFoundation
import MapKit

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
    @State private var thumbnail: UIImage?
    @State private var downloadStates: [URL: AttachmentDownloadState] = [:]
    @State private var downloadTask: Task<Void, Never>? = nil
    @State private var sharePayload: SharePayload? = nil
    @State private var showPhotoViewer: Bool = false

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

    private func pollDownloadStatus(for url: URL) {
        guard downloadStates[url] == .downloading else { return }
        downloadTask = Task {
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
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
                    .foregroundColor(DSColor.amberAccent)
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
                        .font(DSFonts.jetBrainsMono(size: 10))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundColor(DSColor.inkSubtle)
                }
                Text(RelativeTimeFormatter.relative(memo.created))
                    .font(DSFonts.jetBrainsMono(size: 10))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundColor(DSColor.inkSubtle)
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
                    }
                }
            }

            // Photo
            if memo.type == .photo || (memo.type == .mixed && memo.attachments.contains(where: { $0.kind == "photo" })) {
                if let att = memo.attachments.first(where: { $0.kind == "photo" }) {
                    let photoURL = VaultInitializer.vaultURL.appendingPathComponent(att.file)
                    let photoState = attachmentDownloadState(for: photoURL)
                    switch photoState {
                    case .current:
                        PhotoThumbnailView(fileURL: photoURL, thumbnail: $thumbnail, exifText: photoExifText)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Haptics.tapConfirm()
                                showPhotoViewer = true
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 14)
                            .fullScreenCover(isPresented: $showPhotoViewer) {
                                if let att = memo.attachments.first(where: { $0.kind == "photo" }) {
                                    PhotoFullScreenViewer(
                                        fileURL: VaultInitializer.vaultURL.appendingPathComponent(att.file),
                                        exifText: photoExifText
                                    )
                                }
                            }
                    case .downloading, .notDownloaded, .failed:
                        PhotoDownloadPlaceholder(state: photoState)
                            .padding(.top, 4)
                            .onAppear {
                                if photoState == .notDownloaded { startDownload(photoURL) }
                                else if photoState == .failed { startDownload(photoURL) }
                            }
                            .onTapGesture {
                                if photoState == .notDownloaded || photoState == .failed {
                                    startDownload(photoURL)
                                }
                            }
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
                                .foregroundColor(DSColor.inkSubtle)
                            Text(att.transcript ?? URL(fileURLWithPath: att.file).lastPathComponent)
                                .font(DSFonts.jetBrainsMono(size: 11))
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
                // Render-only polish: CJK/Latin spacing; does not modify vault file.
                Text(CJKTextPolish.polish(bodyTrimmed))
                    .font(DSType.serifBody16)
                    .foregroundColor(DSColor.inkPrimary)
                    // Museum reading rhythm: tight leading. Design app.jsx:546-548
                    // renders 16pt body at line-height 1.62; for SwiftUI's
                    // *additive* lineSpacing that compact rhythm is ~2pt, not 6.
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = bodyTrimmed
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
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
                    .font(DSFonts.jetBrainsMono(size: 10))
                    .tracking(1.6)
                    .foregroundColor(DSColor.inkSubtle)

                // Tiny attachment glyphs hint content type without a loud chip.
                if photoFlag {
                    Image(systemName: "photo")
                        // 9pt (was 8) — 8pt SF Symbols fall below the legibility
                        // floor; 9pt keeps the quiet inkSubtle tone while letting
                        // the glyph optically match the 10pt mono timestamp.
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DSColor.inkSubtle)
                }
                if voiceFlag {
                    Image(systemName: "mic")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DSColor.inkSubtle)
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard(cornerRadius: 14)
        .contextMenu {
            // Tap the button above for the smart default; long-press here to
            // override the template or send plain text.
            let shareText = shareableText
            if !shareText.isEmpty {
                ShareLink(item: shareText) {
                    Label("分享文本", systemImage: "doc.plaintext")
                }
            }
            Button {
                sharePayload = .memo(MemoSnapshot.from(memo))
            } label: {
                Label("强制文字卡", systemImage: "rectangle.on.rectangle")
            }
            if memo.attachments.contains(where: { $0.kind == "photo" }),
               let snap = PhotoSnapshot.from(memo) {
                Button {
                    sharePayload = .photo(snap)
                } label: {
                    Label("强制照片卡", systemImage: "photo.on.rectangle")
                }
            }
            if memo.attachments.contains(where: { $0.kind == "audio" }),
               let snap = VoiceSnapshot.from(memo) {
                Button {
                    sharePayload = .voice(snap)
                } label: {
                    Label("强制语音卡", systemImage: "mic.badge.plus")
                }
            }
        }
        .sheet(item: $sharePayload) { payload in
            ShareCardSheet(payload: payload)
        }
    }

    // MARK: - Share text

    /// Builds a plain-text representation of the memo suitable for sharing.
    /// Prefers the voice transcript when present; falls back to body text.
    private var shareableText: String {
        // For voice/mixed memos, use the transcript if available.
        if let att = memo.attachments.first(where: { $0.kind == "audio" }),
           let transcript = att.transcript, !transcript.isEmpty {
            let body = memo.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty || body == transcript {
                return transcript
            }
            return "\(transcript)\n\n\(body)"
        }
        return memo.body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Type chip

    private var typeChip: some View {
        Group {
            switch memo.type {
            case .voice:
                Label("Voice", systemImage: "mic.fill")
            case .photo:
                Label("Photo", systemImage: "photo")
            case .mixed:
                Label("Mixed", systemImage: "square.stack")
            default:
                EmptyView()
            }
        }
        .font(DSFonts.jetBrainsMono(size: 9))
        .tracking(0.5)
        .textCase(.uppercase)
        .foregroundColor(DSColor.amberAccent)
    }

    // MARK: - Helpers

    private func coordinateString(_ loc: Memo.Location?) -> String {
        guard let lat = loc?.lat, let lng = loc?.lng else { return "" }
        let latStr = String(format: "%.4f° %@", abs(lat), lat >= 0 ? "N" : "S")
        let lngStr = String(format: "%.4f° %@", abs(lng), lng >= 0 ? "E" : "W")
        return "\(latStr) · \(lngStr)"
    }

    private var photoExifText: String? {
        guard let att = memo.attachments.first(where: { $0.kind == "photo" }) else { return nil }
        let filename = URL(fileURLWithPath: att.file).lastPathComponent.uppercased()
        let fileURL = VaultInitializer.vaultURL.appendingPathComponent(att.file)
        if let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let focal = exif[kCGImagePropertyExifFocalLength as String] as? Double {
            return "\(filename) // FOCUS: \(Int(focal))mm"
        }
        return filename
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

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 4.0
    private let snapBackThreshold: CGFloat = 1.05

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(.white)
            } else if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
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
                                        offset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                    }
                                }
                                .onEnded { value in
                                    if scale <= 1.0 {
                                        let threshold: CGFloat = 100
                                        if value.translation.height > threshold {
                                            dismiss()
                                        } else {
                                            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75)) {
                                                offset = .zero
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

            // Close button
            VStack {
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(DSColor.amberSoft)
                            .padding(16)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            // EXIF caption
            if let exifText {
                VStack {
                    Spacer()
                    Text(exifText)
                        .font(DSFonts.jetBrainsMono(size: 10))
                        .tracking(0.5)
                        .textCase(.uppercase)
                        .foregroundColor(DSColor.inkSubtle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            LinearGradient(
                                colors: [Color.clear, Color.black.opacity(0.7)],
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
                            .font(DSFonts.jetBrainsMono(size: 11))
                            .foregroundColor(DSColor.inkSubtle)
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
                        .foregroundColor(DSColor.inkSubtle)
                    Text("No coordinates")
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.inkSubtle)
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
                            .foregroundColor(DSColor.amberDeep)
                        Text(NSLocalizedString("memo.detail.location.open_maps", comment: ""))
                            .font(DSType.titleSM)
                            .foregroundColor(DSColor.amberDeep)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DSColor.inkSubtle)
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
                                .foregroundColor(.red)
                            Text("Delete")
                                .font(DSType.titleSM)
                                .foregroundColor(.red)
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

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.isUserInteractionEnabled = false
        map.showsUserLocation = false
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
}

// MARK: - VoiceMemoPlayerRow

struct VoiceMemoPlayerRow: View {

    let fileURL: URL
    let duration: TimeInterval
    let transcript: String?
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
                            .foregroundColor(fileError ? DSColor.inkSubtle : DSColor.amberDeep)
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
                    .font(DSFonts.jetBrainsMono(size: 11))
                    .foregroundColor(DSColor.inkSubtle)
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
                        .font(DSFonts.serif(size: 20, weight: .medium))
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
                        }
                    Text("\u{201D}")
                        .font(DSFonts.serif(size: 20, weight: .medium))
                        .foregroundColor(DSColor.inkMuted.opacity(0.5))
                        .offset(y: -2)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            } else if transcript == nil {
                if VoiceAttachmentQueue.shared.pendingCount > 0 || isRetranscribing {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7).tint(DSColor.inkSubtle)
                        Text(NSLocalizedString("voice.retry.transcribing", comment: ""))
                            .font(DSType.bodySM)
                            .foregroundColor(DSColor.inkSubtle)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
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
                        .foregroundColor(DSColor.amberAccent)
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
        let t = Int(secs)
        return String(format: "%02d:%02d", t / 60, t % 60)
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
            WaveformBars(heights: heights, color: DSColor.amberAccent)
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
    var onTap: (() -> Void)?

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    // Amber dot + label
                    HStack(spacing: 6) {
                        Circle()
                            .fill(DSColor.amberAccent)
                            .frame(width: 6, height: 6)
                            .shadow(color: DSColor.amberGlow, radius: 4, x: 0, y: 0)
                        Text("Today's page compiled")
                            .font(DSFonts.jetBrainsMono(size: 10))
                            .tracking(1)
                            .textCase(.uppercase)
                            .foregroundColor(DSColor.amberAccent)
                    }

                    if let summary = summary, !summary.isEmpty {
                        Text(summary)
                            .font(DSType.serifBody18)
                            .foregroundColor(DSColor.inkPrimary)
                            .lineLimit(2)
                            .lineSpacing(2)
                    } else {
                        Text("Your daily digest is ready.")
                            .font(DSType.serifBody18)
                            .foregroundColor(DSColor.inkPrimary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.forward")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DSColor.amberDeep)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .liquidGlassCard(cornerRadius: 18, tone: .hi)
            .overlay(alignment: .leading) {
                // Left amber accent strip
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [DSColor.amberAccent, DSColor.amberAccent.opacity(0)],
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
                    ProgressView().scaleEffect(0.7).tint(DSColor.amberDeep)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18))
                        .foregroundColor(DSColor.inkSubtle)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if isCompiling {
                    Text("Compiling \(memoCount) memos…")
                        .font(DSFonts.spaceGrotesk(size: 13, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(1)
                        .foregroundColor(DSColor.amberDeep)
                } else if memoCount > 0 {
                    Text("Ready to compile")
                        .font(DSFonts.spaceGrotesk(size: 13, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(1)
                        .foregroundColor(DSColor.inkSubtle)
                    Text("\(memoCount) signals captured today")
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.inkSubtle)
                } else {
                    Text("Start capturing")
                        .font(DSFonts.spaceGrotesk(size: 13, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(1)
                        .foregroundColor(DSColor.inkSubtle)
                    Text("Your signals will compile tonight.")
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.inkSubtle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isCompiling && memoCount > 0 {
                Button(action: { onCompile?() }) {
                    Text("Compile")
                        .font(DSFonts.jetBrainsMono(size: 10))
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

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DSColor.glassLo)
                .frame(maxWidth: .infinity, minHeight: 160)
            VStack(spacing: 8) {
                switch state {
                case .notDownloaded:
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundColor(DSColor.inkSubtle)
                    Text("Tap to download")
                        .font(DSFonts.jetBrainsMono(size: 10))
                        .textCase(.uppercase)
                        .foregroundColor(DSColor.inkSubtle)
                case .downloading:
                    ProgressView().tint(DSColor.inkSubtle)
                    Text("Downloading from iCloud…")
                        .font(DSFonts.jetBrainsMono(size: 10))
                        .textCase(.uppercase)
                        .foregroundColor(DSColor.inkSubtle)
                case .failed:
                    Image(systemName: "exclamationmark.icloud")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundColor(DSColor.amberAccent)
                    Text("Download failed — tap to retry")
                        .font(DSFonts.jetBrainsMono(size: 10))
                        .textCase(.uppercase)
                        .foregroundColor(DSColor.inkSubtle)
                case .current:
                    EmptyView()
                }
            }
        }
    }
}

// MARK: - Thumbnail Cache

// Process-level cache for decoded photo thumbnails.
// NSCache automatically evicts entries under memory pressure.
private let thumbnailCache = NSCache<NSURL, UIImage>()

struct PhotoThumbnailView: View {
    let fileURL: URL
    @Binding var thumbnail: UIImage?
    let exifText: String?

    var body: some View {
        Group {
            if let thumb = thumbnail {
                // Design app.jsx:527 — CafePhoto renders a fixed 4:5 portrait
                // crop. Enforce the same aspect with a fill so the museum
                // timeline keeps a consistent photo rhythm instead of letting
                // each image dictate its own height.
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(4.0 / 5.0, contentMode: .fit)
                    .clipped()
            } else {
                Rectangle()
                    .fill(DSColor.glassLo)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(4.0 / 5.0, contentMode: .fit)
            }
        }
        .task(id: fileURL) {
            thumbnail = nil
            thumbnail = await loadThumbnailAsync(from: fileURL)
        }
        .overlay(alignment: .bottom) {
            if let exifText {
                Text(exifText)
                    .font(DSFonts.jetBrainsMono(size: 10))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundColor(DSColor.inkSubtle)
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
    }

    private func loadThumbnailAsync(from url: URL) async -> UIImage? {
        // Check process-level cache first to avoid redundant disk reads.
        let cacheKey = url as NSURL
        if let cached = thumbnailCache.object(forKey: cacheKey) { return cached }

        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: 600
            ]
            let image: UIImage?
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
                image = UIImage(cgImage: cgThumb)
            } else {
                image = UIImage(data: data)
            }
            if let image {
                thumbnailCache.setObject(image, forKey: cacheKey)
            }
            return image
        }.value
    }
}

// MARK: - AudioDownloadPlaceholder

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
                        .foregroundColor(DSColor.inkSubtle)
                case .downloading:
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(DSColor.inkSubtle)
                case .failed:
                    Image(systemName: "exclamationmark.icloud")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DSColor.amberAccent)
                case .current:
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DSColor.inkSubtle)
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
                    .font(DSFonts.jetBrainsMono(size: 10))
                    .foregroundColor(DSColor.inkSubtle)
                    .frame(width: 36, alignment: .trailing)
            case .downloading:
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(DSColor.inkSubtle)
                    .frame(width: 36, alignment: .trailing)
            case .failed:
                Text("retry")
                    .font(DSFonts.jetBrainsMono(size: 10))
                    .foregroundColor(DSColor.amberAccent)
                    .frame(width: 36, alignment: .trailing)
            case .current:
                Text("--:--")
                    .font(DSFonts.jetBrainsMono(size: 10))
                    .foregroundColor(DSColor.inkSubtle)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

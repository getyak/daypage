import SwiftUI
import UIKit
import ImageIO
import AVFoundation
import MapKit

// MARK: - MemoCardView

/// Displays a single Memo as a card in the Today timeline.
/// Shows time + full content; cards grow to fit the memo so long voice
/// transcriptions and long text are never clipped.
struct MemoCardView: View {

    let memo: Memo

    /// Optional callback invoked when the user confirms deletion of this memo.
    var onDelete: (() -> Void)? = nil

    @State private var showLocationSheet: Bool = false
    /// Tracks which attachment URLs have finished downloading from iCloud.
    @State private var downloadedURLs: Set<URL> = []
    @State private var thumbnail: UIImage?
    @State private var pollingURLs: Set<URL> = []

    // MARK: - iCloud Attachment Helpers

    /// Returns true when the file at `url` is locally available (not evicted to iCloud).
    /// For non-ubiquitous (local-vault) files this always returns true.
    private func isAttachmentDownloaded(_ url: URL) -> Bool {
        guard VaultInitializer.shared.isUsingiCloud else { return true }
        guard let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
              let status = values.ubiquitousItemDownloadingStatus else {
            // Not a ubiquitous item — treat as locally available.
            return true
        }
        return status == .current
    }

    /// Requests iCloud to download the file at `url` if it is not already local.
    /// No-op for local-vault files or files that are already downloaded.
    private func startDownload(_ url: URL) {
        guard VaultInitializer.shared.isUsingiCloud else { return }
        guard !isAttachmentDownloaded(url) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// Polls the download status and marks the URL as downloaded once iCloud delivers it.
    private func pollDownloadStatus(for url: URL) {
        guard !downloadedURLs.contains(url), !pollingURLs.contains(url) else { return }
        pollingURLs.insert(url)
        Task {
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 s
                if isAttachmentDownloaded(url) {
                    await MainActor.run {
                        downloadedURLs.insert(url)
                        pollingURLs.remove(url)
                    }
                    return
                }
            }
            await MainActor.run { pollingURLs.remove(url) }
        }
    }

    var body: some View {
        // Location memos get their own dedicated card layout
        if memo.type == .location {
            locationCard
        } else {
            standardCard
        }
    }

    // MARK: - Location Card

    private var locationCard: some View {
        HStack(spacing: 0) {
            // Left 4pt accent line
            Rectangle()
                .fill(DSColor.primary)
                .frame(width: 4)

            // Time + content
            VStack(alignment: .leading, spacing: 0) {
                // Time chip
                TimeChip(time: RelativeTimeFormatter.relative(memo.created))
                    .padding(.horizontal, DSSpacing.cardInner)
                    .padding(.top, 10)

                // Location name + coordinates row
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let name = memo.location?.name, !name.isEmpty {
                            Text(name.uppercased())
                                .h2Style()
                                .foregroundColor(DSColor.onSurface)
                        }

                        let coordText = coordinateString(memo.location)
                        if !coordText.isEmpty {
                            Text(coordText)
                                .monoLabelStyle(size: 11)
                                .foregroundColor(DSColor.onSurfaceVariant)
                        }
                    }

                    Spacer()

                    Image(systemName: "location.fill")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(DSColor.primary)
                }
                .padding(.horizontal, DSSpacing.cardInner)
                .padding(.top, 6)
                .padding(.bottom, DSSpacing.cardInner)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSColor.surfaceContainer)
            .contentShape(Rectangle())
            .onTapGesture {
                if memo.location?.lat != nil && memo.location?.lng != nil {
                    showLocationSheet = true
                }
            }
        }
        .cornerRadius(DSSpacing.radiusCard)
        .surfaceElevatedShadow()
        .pressableCard()
        .sheet(isPresented: $showLocationSheet) {
            LocationPreviewSheet(
                location: memo.location,
                onDelete: onDelete
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Standard Card

    private var standardCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: time chip + type icon
            HStack(alignment: .center, spacing: 8) {
                TimeChip(time: RelativeTimeFormatter.relative(memo.created))
                typeLabel
                Spacer()
            }
            .padding(.horizontal, DSSpacing.cardInner)
            .padding(.top, 10)

            // Voice player row (for voice memos with audio attachments)
            if memo.type == .voice || (memo.type == .mixed && memo.attachments.contains(where: { $0.kind == "audio" })) {
                if let att = memo.attachments.first(where: { $0.kind == "audio" }) {
                    let audioURL = VaultInitializer.vaultURL.appendingPathComponent(att.file)
                    let isReady = isAttachmentDownloaded(audioURL) || downloadedURLs.contains(audioURL)
                    if isReady {
                        VoiceMemoPlayerRow(
                            fileURL: audioURL,
                            duration: att.duration ?? 0,
                            transcript: att.transcript
                        )
                        .padding(.top, 6)
                    } else {
                        // iCloud evicted — show waveform placeholder with download icon
                        AudioDownloadPlaceholder()
                            .padding(.top, 6)
                            .onAppear {
                                startDownload(audioURL)
                                pollDownloadStatus(for: audioURL)
                            }
                            .onDisappear {
                                pollingURLs.remove(audioURL)
                            }
                            .onTapGesture {
                                startDownload(audioURL)
                                pollDownloadStatus(for: audioURL)
                            }
                    }
                }
            }

            // Photo thumbnail row (for photo and mixed memos with photo attachments)
            if memo.type == .photo || (memo.type == .mixed && memo.attachments.contains(where: { $0.kind == "photo" })) {
                if let att = memo.attachments.first(where: { $0.kind == "photo" }) {
                    let photoURL = VaultInitializer.vaultURL.appendingPathComponent(att.file)
                    let isReady = isAttachmentDownloaded(photoURL) || downloadedURLs.contains(photoURL)
                    if isReady {
                        PhotoThumbnailView(
                            fileURL: photoURL,
                            thumbnail: $thumbnail,
                            exifText: photoExifText
                        )
                        .padding(.top, 6)
                    } else if !isReady {
                        // iCloud evicted — show gray placeholder with spinner
                        PhotoDownloadPlaceholder()
                            .padding(.top, 6)
                            .onAppear {
                                startDownload(photoURL)
                                pollDownloadStatus(for: photoURL)
                            }
                            .onDisappear {
                                pollingURLs.remove(photoURL)
                            }
                    }
                }
            }

            // File attachment rows (for mixed memos with file attachments)
            let fileAttachments = memo.attachments.filter { $0.kind == "file" }
            if !fileAttachments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(fileAttachments, id: \.file) { att in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 13))
                                .foregroundColor(DSColor.onSurfaceVariant)
                            Text(att.transcript ?? URL(fileURLWithPath: att.file).lastPathComponent)
                                .monoLabelStyle(size: 11)
                                .foregroundColor(DSColor.onSurface)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, DSSpacing.cardInner)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.top, 6)
            }

            // Body content (caption)
            // For voice-only memos, suppress body when it duplicates the transcript
            // (legacy data had transcript copied into body before the fix).
            let bodyText = memo.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let isBodyDuplicateOfTranscript = memo.type == .voice &&
                memo.attachments.contains(where: { $0.transcript == bodyText && !bodyText.isEmpty })
            if !bodyText.isEmpty && !isBodyDuplicateOfTranscript {
                Text(bodyText)
                    .bodySMStyle()
                    .foregroundColor(DSColor.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, DSSpacing.cardInner)
                    .padding(.top, 6)
            }

            // Bottom row: location label
            if let locationName = memo.location?.name, !locationName.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "mappin")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DSColor.onSurfaceVariant)
                    Text(locationName)
                        .monoLabelStyle(size: 9)
                        .foregroundColor(DSColor.onSurfaceVariant)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DSSpacing.cardInner)
                .padding(.top, 6)
                .padding(.bottom, DSSpacing.cardInner)
            } else {
                // Match the location branch's 6pt top + cardInner bottom rhythm
                // so cards with and without a location label share the same
                // bottom whitespace.
                Spacer().frame(height: DSSpacing.cardInner + 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSColor.surfaceContainer)
        .overlay(
            Rectangle()
                .fill(borderColor)
                .frame(width: 3),
            alignment: .leading
        )
        .cornerRadius(DSSpacing.radiusCard)
        .surfaceElevatedShadow()
        .pressableCard()
    }

    // MARK: - Subviews

    private var typeLabel: some View {
        Group {
            switch memo.type {
            case .voice:
                Label("语音", systemImage: "mic.fill")
                    .monoLabelStyle(size: 9)
                    .foregroundColor(DSColor.onSurfaceVariant)
            case .photo:
                Label("照片", systemImage: "photo")
                    .monoLabelStyle(size: 9)
                    .foregroundColor(DSColor.onSurfaceVariant)
            case .location:
                Label("位置", systemImage: "location.fill")
                    .monoLabelStyle(size: 9)
                    .foregroundColor(DSColor.onSurfaceVariant)
            case .mixed:
                Label("混合", systemImage: "square.stack")
                    .monoLabelStyle(size: 9)
                    .foregroundColor(DSColor.onSurfaceVariant)
            case .text:
                EmptyView()
            }
        }
    }

    // MARK: - Helpers

    /// Formats lat/lng as "45.52306° N, 122.67648° W"
    private func coordinateString(_ loc: Memo.Location?) -> String {
        guard let lat = loc?.lat, let lng = loc?.lng else { return "" }
        let latStr = String(format: "%.5f° %@", abs(lat), lat >= 0 ? "N" : "S")
        let lngStr = String(format: "%.5f° %@", abs(lng), lng >= 0 ? "E" : "W")
        return "\(latStr), \(lngStr)"
    }

    /// Builds EXIF annotation text for the first photo attachment.
    /// Format: "IMG_0001.HEIC // FOCUS: INFINITYmm"
    private var photoExifText: String? {
        guard let att = memo.attachments.first(where: { $0.kind == "photo" }) else { return nil }
        let filename = URL(fileURLWithPath: att.file).lastPathComponent.uppercased()
        // Try to read focal length from image metadata
        let fileURL = VaultInitializer.vaultURL.appendingPathComponent(att.file)
        if let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let focalLength = exif[kCGImagePropertyExifFocalLength as String] as? Double {
            return "\(filename) // FOCUS: \(Int(focalLength))mm"
        }
        return "\(filename)"
    }

    /// Loads a thumbnail from `fileURL`. Returns nil if the file is not locally available.
    private func loadThumbnail(from fileURL: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 600
        ]
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
            return UIImage(cgImage: cgThumb)
        }
        return UIImage(data: data)
    }

    private var borderColor: Color {
        switch memo.type {
        case .text:    return DSColor.primary
        case .voice:   return DSColor.onSurfaceVariant
        case .photo:   return DSColor.secondaryFixed
        case .location: return DSColor.tertiaryFixed
        case .mixed:   return DSColor.amberArchival
        }
    }

}

// MARK: - LocationPreviewSheet

/// Sheet shown when tapping a location card. Displays a MapKit map preview
/// with options to open in Apple Maps or delete the attachment.
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
            // Handle bar area + title
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let name = location?.name, !name.isEmpty {
                        Text(name.uppercased())
                            .h2Style()
                            .foregroundColor(DSColor.onSurface)
                    } else {
                        Text("位置附件")
                            .h2Style()
                            .foregroundColor(DSColor.onSurface)
                    }
                    if let coord = coordinate {
                        Text(String(format: "%.5f°, %.5f°", coord.latitude, coord.longitude))
                            .monoLabelStyle(size: 11)
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DSColor.onSurfaceVariant)
                        .frame(width: 32, height: 32)
                        .background(DSColor.surfaceContainerHigh)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider().background(DSColor.outline)

            // Map view
            if let coord = coordinate {
                MapPreviewView(coordinate: coord)
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "map")
                        .font(.system(size: 32))
                        .foregroundColor(DSColor.onSurfaceVariant)
                    Text("无坐标信息")
                        .bodySMStyle()
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .background(DSColor.surfaceContainer)
            }

            Divider().background(DSColor.outline)

            // Action buttons
            VStack(spacing: 0) {
                // Open in Apple Maps
                Button(action: openInAppleMaps) {
                    HStack(spacing: 10) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(DSColor.primary)
                        Text("在 Apple Maps 中打开")
                            .titleSMStyle()
                            .foregroundColor(DSColor.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.plain)
                .disabled(coordinate == nil)

                if onDelete != nil {
                    Divider()
                        .padding(.horizontal, 20)
                        .background(DSColor.outlineVariant)

                    Button(action: {
                        dismiss()
                        onDelete?()
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: "trash")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.red)
                            Text("删除附件")
                                .titleSMStyle()
                                .foregroundColor(.red)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(DSColor.surfaceContainer)

            Spacer()
        }
        .background(DSColor.background.ignoresSafeArea())
    }

    private func openInAppleMaps() {
        guard let coord = coordinate else { return }
        let urlStr = "maps://?ll=\(coord.latitude),\(coord.longitude)"
        if let url = URL(string: urlStr) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - MapPreviewView

/// A UIViewRepresentable wrapper for MKMapView to show a static map snapshot with a pin.
struct MapPreviewView: UIViewRepresentable {

    let coordinate: CLLocationCoordinate2D

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.isUserInteractionEnabled = false
        map.showsUserLocation = false
        map.mapType = .standard
        return map
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        mapView.setRegion(region, animated: false)

        mapView.removeAnnotations(mapView.annotations)
        let pin = MKPointAnnotation()
        pin.coordinate = coordinate
        mapView.addAnnotation(pin)
    }
}

// MARK: - VoiceMemoPlayerRow

/// Inline voice memo player: black square play button + static waveform bars + duration.
/// Uses AVAudioPlayer for playback. Only one instance plays at a time via a shared player.
struct VoiceMemoPlayerRow: View {

    let fileURL: URL
    let duration: TimeInterval
    let transcript: String?

    @State private var isPlaying: Bool = false
    @State private var player: AVAudioPlayer?
    @State private var playbackProgress: Double = 0
    @State private var progressTimer: Timer?
    @State private var fileError: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                // Play/Pause button (40x40 black square)
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(fileError ? DSColor.onSurfaceVariant : DSColor.onPrimary)
                        .frame(width: 40, height: 40)
                        .background(fileError ? DSColor.surfaceContainerHigh : DSColor.primary)
                }
                .buttonStyle(.plain)
                .cornerRadius(0)
                .disabled(fileError)

                // Waveform + progress overlay
                ZStack(alignment: .leading) {
                    // Background bars
                    waveformBars(count: 30, color: DSColor.outlineVariant)

                    // Progress overlay (mask-based: scale a leading-anchored
                    // Rectangle by playbackProgress instead of measuring the
                    // container with GeometryReader on every frame).
                    waveformBars(count: 30, color: DSColor.primary)
                        .mask(alignment: .leading) {
                            Rectangle()
                                .scaleEffect(x: CGFloat(playbackProgress), y: 1, anchor: .leading)
                        }
                }
                .frame(height: 28)

                // Duration
                Text(formatDur(isPlaying ? (duration * playbackProgress) : duration))
                    .monoLabelStyle(size: 10)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .frame(width: 36, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Full transcript (if available) or queued placeholder.
            // No line limit — long transcriptions must remain fully readable
            // (see issue #203).
            if let t = transcript, !t.isEmpty {
                Text(t)
                    .bodySMStyle()
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            } else if transcript == nil && VoiceAttachmentQueue.shared.pendingCount > 0 {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(DSColor.onSurfaceVariant)
                    Text("转写中...")
                        .bodySMStyle()
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
        .onDisappear {
            stopPlayback()
        }
    }

    // MARK: - Waveform Bars (static, pseudo-random per URL)

    /// Pre-computed deterministic bar heights derived from `fileURL.hashValue`.
    /// Computed once per body re-evaluation instead of recomputing the bit-shift
    /// expression for every bar on every frame during a swipe gesture.
    private var waveformHeights: [CGFloat] {
        let seed = abs(fileURL.hashValue)
        return (0..<30).map { i in
            CGFloat(4 + ((seed >> i) & 0x1F) % 24)
        }
    }

    private func waveformBars(count: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(waveformHeights.prefix(count).enumerated()), id: \.offset) { _, h in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 3, height: h)
            }
        }
    }

    // MARK: - Playback Control

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            fileError = true
            return
        }
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
                    guard let p = player, p.isPlaying else {
                        stopPlayback()
                        return
                    }
                    playbackProgress = p.currentTime / p.duration
                }
            }
        } catch {
            fileError = true
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        progressTimer?.invalidate()
        progressTimer = nil
        isPlaying = false
        playbackProgress = 0
    }

    private func formatDur(_ secs: TimeInterval) -> String {
        let t = Int(secs)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}

// MARK: - DailyPageEntryCard

/// Card shown at the top of the timeline when today's Daily Page has been compiled.
/// Full-width black card per design spec (Brutalist style).
struct DailyPageEntryCard: View {
    let summary: String?
    var onTap: (() -> Void)?

    @State private var arrowOffset: CGFloat = 0

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TODAY'S PAGE COMPILED")
                        .sectionLabelStyle()
                        .foregroundColor(DSColor.onPrimary)

                    if let summary = summary, !summary.isEmpty {
                        Text(summary)
                            .bodySMStyle()
                            .foregroundColor(DSColor.onPrimary.opacity(0.7))
                            .lineLimit(2)
                    } else {
                        Text("Your daily digest is ready.")
                            .bodySMStyle()
                            .foregroundColor(DSColor.onPrimary.opacity(0.7))
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.forward")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DSColor.onPrimary)
                    .offset(x: arrowOffset)
            }
            .padding(.horizontal, DSSpacing.cardInner)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(DSColor.primary)
            .cornerRadius(DSSpacing.radiusCard)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                arrowOffset = hovering ? 4 : 0
            }
        }
    }
}

// MARK: - CompilePromptCard

/// Placeholder card shown when today's Daily Page has not been compiled.
/// Supports a loading/compiling state that disables the button and shows progress text.
struct CompilePromptCard: View {
    let memoCount: Int
    var isCompiling: Bool = false
    var onCompile: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isCompiling ? DSColor.primary : DSColor.outlineVariant)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 8) {
                if isCompiling {
                    // US-004: single unified compiling indicator on screen.
                    // Title + spinner share one line so this card is the only "Compiling" UI.
                    HStack(spacing: 8) {
                        Text("正在编译 \(memoCount) 条 memo")
                            .sectionLabelStyle()
                            .foregroundColor(DSColor.onSurface)
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(DSColor.onSurfaceVariant)
                        Spacer(minLength: 0)
                    }
                } else {
                    Text("今日还未编译")
                        .sectionLabelStyle()
                        .foregroundColor(DSColor.onSurfaceVariant)

                    if memoCount > 0 {
                        Text("已有 \(memoCount) 条记录，点击立即编译")
                            .bodySMStyle()
                            .foregroundColor(DSColor.onSurfaceVariant)

                        Button(action: { onCompile?() }) {
                            Text("立即编译")
                                .monoLabelStyle(size: 10)
                                .foregroundColor(DSColor.onPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(DSColor.primary)
                                .cornerRadius(DSSpacing.radiusSmall)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("记录今天的想法，晚些时候将自动编译成日记")
                            .bodySMStyle()
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSColor.surfaceContainer)
        }
        .cornerRadius(DSSpacing.radiusCard)
        .surfaceElevatedShadow()
        .animation(.easeInOut(duration: 0.2), value: isCompiling)
    }
}

// MARK: - PhotoDownloadPlaceholder

/// Gray placeholder shown when a photo attachment is evicted to iCloud and not yet downloaded.
struct PhotoDownloadPlaceholder: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 0)
                .fill(DSColor.surfaceContainerHigh)
                .frame(maxWidth: .infinity)
                .frame(height: 160)

            VStack(spacing: 8) {
                ProgressView()
                    .tint(DSColor.onSurfaceVariant)
                Text("正在从 iCloud 下载…")
                    .monoLabelStyle(size: 10)
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
        }
    }
}

// MARK: - PhotoThumbnailView

struct PhotoThumbnailView: View {
    let fileURL: URL
    @Binding var thumbnail: UIImage?
    let exifText: String?

    var body: some View {
        Group {
            if let thumb = thumbnail {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .clipped()
            } else {
                Rectangle()
                    .fill(DSColor.surfaceContainerHigh)
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
            }
        }
        .task(id: fileURL) {
            thumbnail = nil
            thumbnail = await loadThumbnailAsync(from: fileURL)
        }
        .overlay(alignment: .bottom) {
            if let exifText = exifText {
                Text(exifText)
                    .monoLabelStyle(size: 10)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, DSSpacing.cardInner)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DSColor.surfaceContainer)
            }
        }
    }

    private func loadThumbnailAsync(from fileURL: URL) async -> UIImage? {
        let url = fileURL
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: 600
            ]
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
                return UIImage(cgImage: cgThumb)
            }
            return UIImage(data: data)
        }.value
    }
}

// MARK: - AudioDownloadPlaceholder

/// Waveform placeholder shown when an audio attachment is evicted to iCloud and not yet downloaded.
struct AudioDownloadPlaceholder: View {
    var body: some View {
        HStack(spacing: 12) {
            // Download icon in place of play button
            ZStack {
                Rectangle()
                    .fill(DSColor.surfaceContainerHigh)
                    .frame(width: 40, height: 40)
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DSColor.onSurfaceVariant)
            }

            // Placeholder waveform bars
            HStack(spacing: 2) {
                ForEach(0..<30, id: \.self) { i in
                    let h = CGFloat(4 + (i % 6) * 4)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(DSColor.outlineVariant)
                        .frame(width: 3, height: h)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("--:--")
                .monoLabelStyle(size: 10)
                .foregroundColor(DSColor.onSurfaceVariant)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

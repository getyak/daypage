import SwiftUI
import ImageIO
import AVFoundation
import MapKit

// MARK: - MemoCardView

/// A single Memo rendered as a Liquid Glass card in the Today timeline.
struct MemoCardView: View {

    let memo: Memo
    var onDelete: (() -> Void)? = nil

    @State private var showLocationSheet: Bool = false
    @State private var downloadedURLs: Set<URL> = []
    @State private var thumbnail: UIImage?
    @State private var pollingURLs: Set<URL> = []

    // MARK: - iCloud helpers

    private func isAttachmentDownloaded(_ url: URL) -> Bool {
        guard VaultInitializer.shared.isUsingiCloud else { return true }
        guard let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
              let status = values.ubiquitousItemDownloadingStatus else { return true }
        return status == .current
    }

    private func startDownload(_ url: URL) {
        guard VaultInitializer.shared.isUsingiCloud else { return }
        guard !isAttachmentDownloaded(url) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    private func pollDownloadStatus(for url: URL) {
        guard !downloadedURLs.contains(url), !pollingURLs.contains(url) else { return }
        pollingURLs.insert(url)
        Task {
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
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
        if memo.type == .location {
            locationCard
        } else {
            standardCard
        }
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
        .liquidGlassCard(cornerRadius: 18)
        .contentShape(RoundedRectangle(cornerRadius: 18))
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
                    let isReady = isAttachmentDownloaded(audioURL) || downloadedURLs.contains(audioURL)
                    if isReady {
                        VoiceMemoPlayerRow(
                            fileURL: audioURL,
                            duration: att.duration ?? 0,
                            transcript: att.transcript
                        )
                        .padding(.top, 4)
                    } else {
                        AudioDownloadPlaceholder()
                            .padding(.top, 4)
                            .onAppear { startDownload(audioURL); pollDownloadStatus(for: audioURL) }
                            .onDisappear { pollingURLs.remove(audioURL) }
                            .onTapGesture { startDownload(audioURL); pollDownloadStatus(for: audioURL) }
                    }
                }
            }

            // Photo
            if memo.type == .photo || (memo.type == .mixed && memo.attachments.contains(where: { $0.kind == "photo" })) {
                if let att = memo.attachments.first(where: { $0.kind == "photo" }) {
                    let photoURL = VaultInitializer.vaultURL.appendingPathComponent(att.file)
                    let isReady = isAttachmentDownloaded(photoURL) || downloadedURLs.contains(photoURL)
                    if isReady {
                        PhotoThumbnailView(fileURL: photoURL, thumbnail: $thumbnail, exifText: photoExifText)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(.horizontal, 14)
                            .padding(.top, 14)
                    } else {
                        PhotoDownloadPlaceholder()
                            .padding(.top, 4)
                            .onAppear { startDownload(photoURL); pollDownloadStatus(for: photoURL) }
                            .onDisappear { pollingURLs.remove(photoURL) }
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
            let isBodyDuplicate = memo.type == .voice &&
                memo.attachments.contains(where: { $0.transcript == bodyTrimmed && !bodyTrimmed.isEmpty })
            if !bodyTrimmed.isEmpty && !isBodyDuplicate {
                Text(bodyTrimmed)
                    .font(DSType.serifBody16)
                    .foregroundColor(DSColor.inkPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }

            // Bottom meta row: time + type chip + location
            HStack(spacing: 8) {
                Text(RelativeTimeFormatter.relative(memo.created))
                    .font(DSFonts.jetBrainsMono(size: 10))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundColor(DSColor.inkSubtle)

                if memo.type != .text {
                    typeChip
                }

                if let loc = memo.location?.name, !loc.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "mappin")
                            .font(.system(size: 8, weight: .medium))
                        Text(loc)
                            .font(DSFonts.jetBrainsMono(size: 9))
                            .tracking(0.4)
                            .textCase(.uppercase)
                    }
                    .foregroundColor(DSColor.inkSubtle)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 18)
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
                        Text("Open in Apple Maps")
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

    @State private var isPlaying: Bool = false
    @State private var player: AVAudioPlayer?
    @State private var playbackProgress: Double = 0
    @State private var progressTimer: Timer?
    @State private var fileError: Bool = false

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

                ZStack(alignment: .leading) {
                    waveformBars(count: 40, color: DSColor.inkFaint)
                    waveformBars(count: 40, color: DSColor.amberAccent)
                        .mask(alignment: .leading) {
                            Rectangle()
                                .scaleEffect(x: CGFloat(playbackProgress), y: 1, anchor: .leading)
                        }
                }
                .frame(height: 24)

                Text(formatDur(isPlaying ? duration * playbackProgress : duration))
                    .font(DSFonts.jetBrainsMono(size: 11))
                    .foregroundColor(DSColor.inkSubtle)
                    .frame(width: 36, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)

            // Transcript (italic serif quote style)
            if let t = transcript, !t.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("\"")
                        .font(DSFonts.newYork(size: 20, weight: .medium))
                        .foregroundColor(DSColor.amberAccent)
                        .offset(y: -2)
                    Text(t)
                        .font(DSType.serifQuote)
                        .foregroundColor(DSColor.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Text("\"")
                        .font(DSFonts.newYork(size: 20, weight: .medium))
                        .foregroundColor(DSColor.amberAccent)
                        .offset(y: -2)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            } else if transcript == nil && VoiceAttachmentQueue.shared.pendingCount > 0 {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7).tint(DSColor.inkSubtle)
                    Text("Transcribing…")
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.inkSubtle)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
        }
        .onDisappear { stopPlayback() }
    }

    private var waveformHeights: [CGFloat] {
        let seed = abs(fileURL.hashValue)
        return (0..<40).map { i in CGFloat(3 + ((seed >> i) & 0x1F) % 20) }
    }

    private func waveformBars(count: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(waveformHeights.prefix(count).enumerated()), id: \.offset) { _, h in
                RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 2.5, height: h)
            }
        }
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
                    playbackProgress = p.currentTime / p.duration
                }
            }
        } catch { fileError = true }
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
            .liquidGlassCard(cornerRadius: 18, tone: .elevated)
            .overlay(alignment: .leading) {
                // Left amber accent strip
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [DSColor.amberAccent, DSColor.amberAccent.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
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
        .animation(.easeInOut(duration: 0.2), value: isCompiling)
    }
}

// MARK: - Photo Placeholders

struct PhotoDownloadPlaceholder: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DSColor.glassLo)
                .frame(maxWidth: .infinity, minHeight: 160)
            VStack(spacing: 8) {
                ProgressView().tint(DSColor.inkSubtle)
                Text("Downloading from iCloud…")
                    .font(DSFonts.jetBrainsMono(size: 10))
                    .textCase(.uppercase)
                    .foregroundColor(DSColor.inkSubtle)
            }
        }
    }
}

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
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .clipped()
            } else {
                Rectangle()
                    .fill(DSColor.glassLo)
                    .frame(maxWidth: .infinity, minHeight: 200)
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
        await Task.detached(priority: .userInitiated) {
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

struct AudioDownloadPlaceholder: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DSColor.glassLo)
                    .frame(width: 36, height: 36)
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DSColor.inkSubtle)
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
            Text("--:--")
                .font(DSFonts.jetBrainsMono(size: 10))
                .foregroundColor(DSColor.inkSubtle)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

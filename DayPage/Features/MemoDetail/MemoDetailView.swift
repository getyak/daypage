import SwiftUI
import MapKit
import ImageIO
import AVFoundation

// MARK: - MemoDetailView

struct MemoDetailView: View {

    let memo: Memo
    let vm: any MemoDetailViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var fullResImage: UIImage?
    @State private var showPhotoFullscreen: Bool = false

    // Edit body state
    @State private var isEditingBody: Bool = false
    @State private var editedBody: String = ""

    // Delete confirmation
    @State private var showDeleteConfirm: Bool = false

    private var kickerText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd  HH:mm"
        return f.string(from: memo.created).uppercased()
    }

    var body: some View {
        ZStack(alignment: .top) {
            AmbientBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // MARK: Navigation Bar Row
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Today")
                                    .font(DSType.bodySM)
                            }
                            .foregroundColor(DSColor.inkMuted)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Menu {
                            Button {
                                editedBody = memo.body
                                isEditingBody = true
                            } label: {
                                Label("Edit Body", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                Haptics.tapConfirm()
                                showDeleteConfirm = true
                            } label: {
                                Label("Delete Memo", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundColor(DSColor.inkMuted)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 20)

                    // MARK: Kicker — mono date + time
                    Text(kickerText)
                        .font(DSType.mono10)
                        .foregroundColor(DSColor.inkSubtle)
                        .tracking(1.2)
                        .padding(.bottom, 14)

                    // MARK: Serif Body (view or edit)
                    let bodyTrimmed = memo.body.trimmingCharacters(in: .whitespacesAndNewlines)
                    let hasAudio = memo.attachments.contains(where: { $0.kind == "audio" })
                    let isBodyDuplicate = hasAudio &&
                        memo.attachments.contains(where: { att in
                            att.kind == "audio" &&
                            att.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) == bodyTrimmed &&
                            !bodyTrimmed.isEmpty
                        })

                    if isEditingBody {
                        VStack(alignment: .leading, spacing: 10) {
                            TextEditor(text: $editedBody)
                                .font(DSType.serifBody16)
                                .foregroundColor(DSColor.inkPrimary)
                                .frame(minHeight: 120)
                                .scrollContentBackground(.hidden)
                                .background(DSColor.glassLo)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            HStack(spacing: 12) {
                                Button("Cancel") {
                                    isEditingBody = false
                                }
                                .font(DSType.bodySM)
                                .foregroundColor(DSColor.inkMuted)
                                .buttonStyle(.plain)

                                Spacer()

                                Button("Save") {
                                    vm.update(memo: memo, body: editedBody)
                                    isEditingBody = false
                                }
                                .font(DSType.bodySM)
                                .foregroundColor(DSColor.amberDeep)
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 14)
                    } else if !bodyTrimmed.isEmpty && !isBodyDuplicate {
                        Text(CJKTextPolish.polish(bodyTrimmed))
                            .font(DSType.serifBody16)
                            .foregroundColor(DSColor.inkPrimary)
                            .lineSpacing(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }

                    // MARK: Attachment Sections
                    let audioAtts = memo.attachments.filter { $0.kind == "audio" }
                    let photoAtts = memo.attachments.filter { $0.kind == "photo" }
                    let fileAtts  = memo.attachments.filter { $0.kind == "file" }
                    let hasLocation = memo.location?.lat != nil

                    if !audioAtts.isEmpty || !photoAtts.isEmpty || !fileAtts.isEmpty || hasLocation {
                        Divider()
                            .background(DSColor.inkFaint)
                            .padding(.vertical, 20)

                        VStack(alignment: .leading, spacing: 20) {

                            // Voice
                            ForEach(audioAtts, id: \.file) { att in
                                DetailVoiceSection(attachment: att)
                            }

                            // Photo
                            ForEach(photoAtts, id: \.file) { att in
                                DetailPhotoSection(
                                    attachment: att,
                                    fullResImage: $fullResImage,
                                    showFullscreen: $showPhotoFullscreen
                                )
                            }

                            // Location
                            if hasLocation {
                                DetailLocationSection(location: memo.location)
                            }

                            // Files
                            if !fileAtts.isEmpty {
                                DetailFilesSection(attachments: fileAtts)
                            }
                        }
                    }

                    // MARK: Metadata Section
                    Divider()
                        .background(DSColor.inkFaint)
                        .padding(.vertical, 20)

                    DetailMetadataSection(memo: memo)

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .navigationBarHidden(true)
        .fullScreenCover(isPresented: $showPhotoFullscreen) {
            PhotoFullscreenView(image: fullResImage)
        }
        .confirmationDialog("Delete this memo?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                vm.deleteMemo(memo)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }
}

// MARK: - DetailVoiceSection

private struct DetailVoiceSection: View {
    let attachment: Memo.Attachment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Voice")
            let audioURL = VaultInitializer.vaultURL.appendingPathComponent(attachment.file)
            VoiceMemoPlayerRow(
                fileURL: audioURL,
                duration: attachment.duration ?? 0,
                transcript: attachment.transcript
            )
            .frame(maxWidth: .infinity)
            .liquidGlassCard(cornerRadius: 14, tone: .lo)
        }
    }
}

// MARK: - DetailPhotoSection

private struct DetailPhotoSection: View {
    let attachment: Memo.Attachment
    @Binding var fullResImage: UIImage?
    @Binding var showFullscreen: Bool

    @State private var loadedImage: UIImage?

    private var photoURL: URL {
        VaultInitializer.vaultURL.appendingPathComponent(attachment.file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Photo")

            ZStack(alignment: .bottom) {
                Group {
                    if let img = loadedImage {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity, minHeight: 240)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(DSColor.glassLo)
                            .frame(maxWidth: .infinity, minHeight: 240)
                            .overlay(ProgressView().tint(DSColor.inkSubtle))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture {
                    fullResImage = loadedImage
                    showFullscreen = true
                }

                // EXIF overlay
                if let exif = exifOverlayText {
                    Text(exif)
                        .font(DSFonts.jetBrainsMono(size: 10))
                        .tracking(0.5)
                        .textCase(.uppercase)
                        .foregroundColor(DSColor.bgWarm.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            LinearGradient(
                                colors: [Color.clear, Color.black.opacity(0.45)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        )
                }
            }
            .task(id: photoURL) {
                loadedImage = await loadFullResImage(from: photoURL)
            }

            // Tap hint
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .medium))
                Text("Tap to view full screen")
                    .font(DSFonts.jetBrainsMono(size: 10))
                    .tracking(0.4)
            }
            .foregroundColor(DSColor.inkSubtle)
            .textCase(.uppercase)
        }
    }

    private var exifOverlayText: String? {
        let filename = URL(fileURLWithPath: attachment.file).lastPathComponent.uppercased()
        if let source = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            var parts: [String] = [filename]
            if let focal = exif[kCGImagePropertyExifFocalLength as String] as? Double {
                parts.append("\(Int(focal))mm")
            }
            if let aperture = exif[kCGImagePropertyExifFNumber as String] as? Double {
                parts.append(String(format: "f/%.1f", aperture))
            }
            if let shutter = exif[kCGImagePropertyExifExposureTime as String] as? Double {
                let denom = Int(1.0 / shutter)
                parts.append("1/\(denom)s")
            }
            return parts.joined(separator: "  //  ")
        }
        return filename
    }

    private func loadFullResImage(from url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
    }
}

// MARK: - DetailLocationSection

private struct DetailLocationSection: View {
    let location: Memo.Location?

    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = location?.lat, let lng = location?.lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Location")

            VStack(alignment: .leading, spacing: 0) {
                // Map preview
                if let coord = coordinate {
                    MapPreviewView(coordinate: coord)
                        .frame(maxWidth: .infinity)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(DSColor.glassLo)
                            .frame(maxWidth: .infinity, minHeight: 120)
                        VStack(spacing: 6) {
                            Image(systemName: "map")
                                .font(.system(size: 28))
                                .foregroundColor(DSColor.inkSubtle)
                            Text("No coordinates")
                                .font(DSType.bodySM)
                                .foregroundColor(DSColor.inkSubtle)
                        }
                    }
                }

                // Location name + coords
                VStack(alignment: .leading, spacing: 4) {
                    if let name = location?.name, !name.isEmpty {
                        Text(name)
                            .font(DSType.serifBody16)
                            .foregroundColor(DSColor.inkPrimary)
                    }
                    if let coord = coordinate {
                        Text(String(format: "%.5f°, %.5f°", coord.latitude, coord.longitude))
                            .font(DSFonts.jetBrainsMono(size: 11))
                            .foregroundColor(DSColor.inkSubtle)
                            .tracking(0.4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider().background(DSColor.glassRim).padding(.horizontal, 14)

                // Open in Apple Maps
                Button(action: openInMaps) {
                    HStack(spacing: 10) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DSColor.amberDeep)
                        Text("Open in Apple Maps")
                            .font(DSType.bodySM)
                            .foregroundColor(DSColor.amberDeep)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DSColor.inkSubtle)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .disabled(coordinate == nil)
            }
            .liquidGlassCard(cornerRadius: 14, tone: .lo)
        }
    }

    private func openInMaps() {
        guard let coord = coordinate,
              let url = URL(string: "maps://?ll=\(coord.latitude),\(coord.longitude)") else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - DetailFilesSection

private struct DetailFilesSection: View {
    let attachments: [Memo.Attachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Files")

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(attachments.enumerated()), id: \.element.file) { index, att in
                    if index > 0 {
                        Divider().background(DSColor.glassRim).padding(.leading, 44)
                    }
                    DetailFileRow(attachment: att)
                }
            }
            .liquidGlassCard(cornerRadius: 14, tone: .lo)
        }
    }
}

// MARK: - DetailFileRow

private struct DetailFileRow: View {
    let attachment: Memo.Attachment

    @State private var fileSize: String = ""

    private var fileURL: URL {
        VaultInitializer.vaultURL.appendingPathComponent(attachment.file)
    }

    private var fileName: String {
        attachment.transcript ?? fileURL.lastPathComponent
    }

    private var fileIcon: String {
        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "pdf":                              return "doc.richtext.fill"
        case "jpg", "jpeg", "png", "heic":      return "photo.fill"
        case "mp4", "mov", "m4v":               return "video.fill"
        case "mp3", "m4a", "wav", "aac":        return "music.note"
        case "zip", "tar", "gz":                return "archivebox.fill"
        case "txt", "md":                       return "doc.text.fill"
        case "xls", "xlsx", "csv":              return "tablecells.fill"
        case "doc", "docx":                     return "doc.fill"
        default:                                return "doc.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DSColor.amberSoft)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(DSColor.amberRim, lineWidth: 0.5)
                    )
                    .frame(width: 32, height: 32)
                Image(systemName: fileIcon)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(DSColor.amberAccent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .font(DSFonts.jetBrainsMono(size: 11))
                    .foregroundColor(DSColor.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !fileSize.isEmpty {
                    Text(fileSize)
                        .font(DSFonts.jetBrainsMono(size: 10))
                        .foregroundColor(DSColor.inkSubtle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: openFile) {
                Text("Open")
                    .font(DSFonts.jetBrainsMono(size: 10))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundColor(DSColor.amberDeep)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(DSColor.amberSoft)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(DSColor.amberRim, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .onAppear { loadFileSize() }
    }

    private func loadFileSize() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let bytes = attrs[.size] as? Int64 else { return }
        fileSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func openFile() {
        UIApplication.shared.open(fileURL)
    }
}

// MARK: - DetailMetadataSection

private struct DetailMetadataSection: View {
    let memo: Memo

    private var createdFull: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: memo.created)
    }

    private var vaultFilePath: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return "vault/raw/\(f.string(from: memo.created)).md"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Metadata")
                .font(DSType.mono10)
                .foregroundColor(DSColor.inkSubtle)
                .tracking(1.2)
                .textCase(.uppercase)
                .padding(.bottom, 4)

            metaRow(label: "Created", value: createdFull)
            metaRow(label: "File", value: vaultFilePath)
            metaRow(label: "Kind", value: memo.type.rawValue.capitalized)

            // Kind-specific fields
            kindSpecificRows
        }
    }

    @ViewBuilder
    private var kindSpecificRows: some View {
        // Voice: duration + transcription provider
        if let audioAtt = memo.attachments.first(where: { $0.kind == "audio" }) {
            if let dur = audioAtt.duration {
                let mins = Int(dur) / 60
                let secs = Int(dur) % 60
                metaRow(label: "Duration", value: String(format: "%02d:%02d", mins, secs))
            }
            if let transcript = audioAtt.transcript, !transcript.isEmpty {
                metaRow(label: "Transcription", value: "OpenAI Whisper")
            } else {
                metaRow(label: "Transcription", value: "Pending")
            }
        }

        // Photo: EXIF fields
        if let photoAtt = memo.attachments.first(where: { $0.kind == "photo" }) {
            let photoURL = VaultInitializer.vaultURL.appendingPathComponent(photoAtt.file)
            if let source = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                    if let aperture = exif[kCGImagePropertyExifFNumber as String] as? Double {
                        metaRow(label: "Aperture", value: String(format: "f/%.1f", aperture))
                    }
                    if let shutter = exif[kCGImagePropertyExifExposureTime as String] as? Double {
                        let denom = Int(1.0 / shutter)
                        metaRow(label: "Shutter", value: "1/\(denom)s")
                    }
                    if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int],
                       let isoVal = iso.first {
                        metaRow(label: "ISO", value: "\(isoVal)")
                    }
                    if let focal = exif[kCGImagePropertyExifFocalLength as String] as? Double {
                        metaRow(label: "Focal Length", value: "\(Int(focal))mm")
                    }
                }
                // Pixel dimensions
                if let w = props[kCGImagePropertyPixelWidth as String] as? Int,
                   let h = props[kCGImagePropertyPixelHeight as String] as? Int {
                    metaRow(label: "Dimensions", value: "\(w) × \(h)")
                }
            }
        }

        // Location: coordinates
        if let loc = memo.location {
            if let lat = loc.lat, let lng = loc.lng {
                metaRow(label: "Coordinates", value: String(format: "%.6f, %.6f", lat, lng))
            }
            if let name = loc.name, !name.isEmpty {
                metaRow(label: "Place", value: name)
            }
        }

        // Weather
        if let weather = memo.weather, !weather.isEmpty {
            metaRow(label: "Weather", value: weather)
        }
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label.uppercased())
                .font(DSFonts.jetBrainsMono(size: 10))
                .tracking(0.6)
                .foregroundColor(DSColor.inkSubtle)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(DSFonts.jetBrainsMono(size: 10))
                .tracking(0.4)
                .foregroundColor(DSColor.inkMuted)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - PhotoFullscreenView

struct PhotoFullscreenView: View {
    let image: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.2))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 20)
                    .padding(.top, 20)
                }
                Spacer()
            }
        }
    }
}

// MARK: - Section label helper

private func sectionLabel(_ title: String) -> some View {
    Text(title.uppercased())
        .font(DSType.mono10)
        .foregroundColor(DSColor.inkSubtle)
        .tracking(1.2)
}

import SwiftUI
import MapKit
import ImageIO
import DayPageModels
import DayPageStorage
import DayPageServices

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

    // Share sheet (mono text → UIActivityViewController)
    @State private var showShareSheet: Bool = false

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
                                Text(NSLocalizedString(
                                    "memo.detail.nav.back",
                                    value: "Today",
                                    comment: "Detail view — back-to-today button label"
                                ))
                                    .font(DSType.bodySM)
                            }
                            .foregroundColor(DSColor.inkMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(NSLocalizedString(
                            "memo.detail.a11y.back",
                            value: "返回今天",
                            comment: "Detail view — back button VoiceOver label"
                        ))

                        Spacer()

                        Menu {
                            Button {
                                Haptics.soft()
                                editedBody = memo.body
                                isEditingBody = true
                            } label: {
                                Label(NSLocalizedString(
                                    "memo.detail.action.edit",
                                    value: "Edit Body",
                                    comment: "Detail view — menu: edit body"
                                ), systemImage: "pencil")
                            }

                            Button {
                                UIPasteboard.general.string = memo.body
                                Haptics.tapConfirm()
                            } label: {
                                Label(NSLocalizedString(
                                    "memo.detail.action.copy",
                                    value: "Copy Text",
                                    comment: "Detail view — menu: copy body"
                                ), systemImage: "doc.on.doc")
                            }

                            Button {
                                Haptics.soft()
                                showShareSheet = true
                            } label: {
                                Label(NSLocalizedString(
                                    "memo.detail.action.share",
                                    value: "Share",
                                    comment: "Detail view — menu: share"
                                ), systemImage: "square.and.arrow.up")
                            }

                            Divider()

                            Button(role: .destructive) {
                                // Destructive: use the warning notification
                                // pulse rather than the lighter confirm tick
                                // so the haptic itself signals irreversibility.
                                Haptics.warningNotification()
                                showDeleteConfirm = true
                            } label: {
                                Label(NSLocalizedString(
                                    "memo.detail.action.delete",
                                    value: "Delete Memo",
                                    comment: "Detail view — menu: delete"
                                ), systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundColor(DSColor.inkMuted)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(NSLocalizedString(
                            "memo.detail.a11y.menu",
                            value: "更多操作",
                            comment: "Detail view — ellipsis menu a11y"
                        ))
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
                                .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))

                            HStack(spacing: 12) {
                                Button(NSLocalizedString(
                                    "memo.detail.edit.cancel",
                                    value: "Cancel",
                                    comment: "Detail view — cancel body edit"
                                )) {
                                    Haptics.soft()
                                    isEditingBody = false
                                }
                                .font(DSType.bodySM)
                                .foregroundColor(DSColor.inkMuted)
                                .buttonStyle(.plain)

                                Spacer()

                                Button(NSLocalizedString(
                                    "memo.detail.edit.save",
                                    value: "Save",
                                    comment: "Detail view — save body edit"
                                )) {
                                    Haptics.tapConfirm()
                                    vm.update(memo: memo, body: editedBody)
                                    isEditingBody = false
                                }
                                .font(DSType.bodySM)
                                .foregroundColor(DSColor.accentOnBg)
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 14)
                    } else if !bodyTrimmed.isEmpty && !isBodyDuplicate {
                        Text(CJKTextPolish.polish(bodyTrimmed))
                            .font(DSType.serifBody16)
                            .foregroundColor(DSColor.inkPrimary)
                            // Line-spacing raised from 6→8 (≈1.5× serifBody16) so
                            // long-form journal entries breathe like a printed
                            // page. Below 8pt the CJK stroke density read as a
                            // tight paragraph rather than reflective prose.
                            .lineSpacing(8)
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

                    // MARK: Ask Past Self (Issue #11, 2026-07-03)
                    //
                    // Anchored just above the metadata footer. Opens the
                    // shared AskPastView (D1 memory-chat agent) with the
                    // current memo's body pre-seeded as the retrieval
                    // context. The action fires the standard
                    // `daypage://ask?q=` URL so navModel + RootView keep
                    // authoritative — no new sheet plumbing here.
                    Divider()
                        .background(DSColor.inkFaint)
                        .padding(.vertical, 20)

                    Button {
                        Haptics.tapConfirm()
                        let question = "关于这条 memo（\(memo.body.prefix(60))），我当时为什么这么想？"
                        if let encoded = question.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                           let url = URL(string: "daypage://ask?q=\(encoded)") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(DSColor.accentOnBg)
                            Text("追问过去的自己")
                                .font(DSType.bodySM)
                                .foregroundColor(DSColor.accentOnBg)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DSColor.accentOnBg.opacity(0.65))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(DSColor.amberSoft)
                        .overlay(
                            RoundedRectangle(cornerRadius: DSRadius.md)
                                .strokeBorder(DSColor.amberRim, lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("memo.detail.ask.past")

                    // MARK: Metadata Section
                    Divider()
                        .background(DSColor.inkFaint)
                        .padding(.vertical, 20)

                    DetailMetadataSection(memo: memo)

                    // Tightened from 40→24 so the metadata section anchors the
                    // page instead of floating in a dead-zone at the bottom.
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            // Issue #18 (2026-07-03): capture the detail-open funnel so
            // the debug board can show how many memo cards actually got
            // read vs. swiped past. Fires from the top-level body so
            // `memo` is in scope (was misplaced inside DetailFileRow's
            // onAppear last edit).
            AnalyticsService.shared.record(
                AnalyticsService.Name.detailOpened,
                props: ["memo_id": memo.id.uuidString]
            )
        }
        .fullScreenCover(isPresented: $showPhotoFullscreen) {
            PhotoFullscreenView(image: fullResImage)
        }
        .sheet(isPresented: $showShareSheet) {
            // Reuse the app-wide ShareSheet wrapper (Settings/ObsidianExport
            // already ships it). Sends the memo body as plain text — future
            // work can attach photo/audio URLs alongside.
            ShareSheet(activityItems: [memo.body])
        }
        .confirmationDialog(
            NSLocalizedString(
                "memo.detail.delete.title",
                value: "Delete this memo?",
                comment: "Detail view — delete confirmation title"
            ),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(
                NSLocalizedString(
                    "memo.detail.delete.confirm",
                    value: "Delete",
                    comment: "Detail view — delete confirmation destructive action"
                ),
                role: .destructive
            ) {
                Haptics.warningNotification()
                vm.deleteMemo(memo)
                dismiss()
            }
            Button(
                NSLocalizedString(
                    "memo.detail.delete.cancel",
                    value: "Cancel",
                    comment: "Detail view — delete confirmation cancel"
                ),
                role: .cancel
            ) {}
        } message: {
            Text(NSLocalizedString(
                "memo.detail.delete.warning",
                value: "This cannot be undone.",
                comment: "Detail view — delete confirmation warning body"
            ))
        }
    }
}

// MARK: - DetailVoiceSection

private struct DetailVoiceSection: View {
    let attachment: Memo.Attachment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(NSLocalizedString("memo.detail.section.voice", comment: ""))
            let audioURL = VaultInitializer.vaultURL.appendingPathComponent(attachment.file)
            VoiceMemoPlayerRow(
                fileURL: audioURL,
                duration: attachment.duration ?? 0,
                transcript: attachment.transcript
            )
            .frame(maxWidth: .infinity)
            .liquidGlassCard(cornerRadius: DSRadius.md, tone: .lo)
        }
    }
}

// MARK: - DetailPhotoSection

private struct DetailPhotoSection: View {
    let attachment: Memo.Attachment
    @State private var exifText: String?
    @Binding var fullResImage: UIImage?
    @Binding var showFullscreen: Bool

    @State private var loadedImage: UIImage?

    private var photoURL: URL {
        VaultInitializer.vaultURL.appendingPathComponent(attachment.file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(NSLocalizedString("memo.detail.section.photo", comment: ""))

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
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                .onTapGesture {
                    fullResImage = loadedImage
                    showFullscreen = true
                }

                // EXIF overlay
                if let exif = exifText {
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
                            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                        )
                }
            }
            .task(id: photoURL) {
                loadedImage = await loadFullResImage(from: photoURL)
                // EXIF caption loads off-main with the image — as a computed
                // property it re-read the file header on every body pass.
                let url = photoURL
                let file = attachment.file
                exifText = await Task.detached(priority: .utility) {
                    Self.exifOverlayText(file: file, photoURL: url)
                }.value
            }

            // Tap hint
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .medium))
                Text(NSLocalizedString("memo.detail.photo.tap_fullscreen", comment: ""))
                    .font(DSFonts.jetBrainsMono(size: 10))
                    .tracking(0.4)
            }
            .foregroundColor(DSColor.inkSubtle)
            .textCase(.uppercase)
        }
    }

    nonisolated private static func exifOverlayText(file: String, photoURL: URL) -> String? {
        let filename = URL(fileURLWithPath: file).lastPathComponent.uppercased()
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
            sectionLabel(NSLocalizedString("memo.detail.section.location", comment: ""))

            VStack(alignment: .leading, spacing: 0) {
                // Map preview
                if let coord = coordinate {
                    MapPreviewView(coordinate: coord)
                        .frame(maxWidth: .infinity)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                            .fill(DSColor.glassLo)
                            .frame(maxWidth: .infinity, minHeight: 120)
                        VStack(spacing: 6) {
                            Image(systemName: "map")
                                .font(.system(size: 28))
                                .foregroundColor(DSColor.inkSubtle)
                            Text(NSLocalizedString("memo.detail.location.no_coordinates", comment: ""))
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
                            .foregroundColor(DSColor.accentOnBg)
                        Text(NSLocalizedString("memo.detail.location.open_maps", comment: ""))
                            .font(DSType.bodySM)
                            .foregroundColor(DSColor.accentOnBg)
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
            .liquidGlassCard(cornerRadius: DSRadius.md, tone: .lo)
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
            .liquidGlassCard(cornerRadius: DSRadius.md, tone: .lo)
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
                    .foregroundColor(DSColor.accentOnBg)
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
                    .foregroundColor(DSColor.accentOnBg)
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

    /// Photo EXIF rows resolved off-main. Reading image properties inline in
    /// `kindSpecificRows` was synchronous disk I/O on every body pass.
    @State private var photoExifRows: [(label: String, value: String)] = []

    private var createdFull: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: memo.created)
    }

    private var vaultFilePath: String {
        "vault/raw/\(DateFormatters.isoDate.string(from: memo.created)).md"
    }

    // MARK: - Body stats

    private struct BodyStats {
        let wordCount: Int
        let charCount: Int
        let readingMinutes: Int  // 0 means "< 1 min"
    }

    private func bodyStats(for text: String) -> BodyStats {
        var cjkCount = 0
        var latinWords = 0
        var inLatinRun = false
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3400...0x4DBF).contains(scalar.value) ||
               (0x3040...0x30FF).contains(scalar.value) {
                cjkCount += 1
                inLatinRun = false
            } else if scalar.properties.isWhitespace {
                inLatinRun = false
            } else {
                if !inLatinRun { latinWords += 1 }
                inLatinRun = true
            }
        }
        // Reading time: CJK at 300 cpm, Latin at 220 wpm — sum independent estimates
        let totalMinutes = Double(cjkCount) / 300.0 + Double(latinWords) / 220.0
        return BodyStats(
            wordCount: TextCount.words(text),
            charCount: text.count,
            readingMinutes: Int(totalMinutes.rounded())
        )
    }

    var body: some View {
        let bodyTrimmed = memo.body.trimmingCharacters(in: .whitespacesAndNewlines)

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

            // Body stats — only shown when there is actual body text
            if !bodyTrimmed.isEmpty {
                let stats = bodyStats(for: bodyTrimmed)
                metaRow(
                    label: NSLocalizedString("memo.detail.meta.words", comment: ""),
                    value: "\(stats.wordCount)"
                )
                metaRow(
                    label: NSLocalizedString("memo.detail.meta.characters", comment: ""),
                    value: "\(stats.charCount)"
                )
                let readingValue: String = stats.readingMinutes < 1
                    ? NSLocalizedString("memo.detail.meta.reading.less_than_1", comment: "")
                    : String(format: NSLocalizedString("memo.detail.meta.reading.min", comment: ""), stats.readingMinutes)
                metaRow(
                    label: NSLocalizedString("memo.detail.meta.reading", comment: ""),
                    value: readingValue
                )
            }

            // Kind-specific fields
            kindSpecificRows
        }
        .task(id: memo.id) {
            guard let photoAtt = memo.attachments.first(where: { $0.kind == "photo" }) else { return }
            let url = VaultInitializer.vaultURL.appendingPathComponent(photoAtt.file)
            photoExifRows = await Task.detached(priority: .utility) {
                Self.loadPhotoExifRows(from: url)
            }.value
        }
    }

    /// Metadata-only image header read (no pixel decode) — still disk I/O,
    /// so it runs off the main actor via the .task above.
    nonisolated private static func loadPhotoExifRows(from photoURL: URL) -> [(label: String, value: String)] {
        guard let source = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return []
        }
        var rows: [(label: String, value: String)] = []
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let aperture = exif[kCGImagePropertyExifFNumber as String] as? Double {
                rows.append(("Aperture", String(format: "f/%.1f", aperture)))
            }
            if let shutter = exif[kCGImagePropertyExifExposureTime as String] as? Double {
                let denom = Int(1.0 / shutter)
                rows.append(("Shutter", "1/\(denom)s"))
            }
            if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int],
               let isoVal = iso.first {
                rows.append(("ISO", "\(isoVal)"))
            }
            if let focal = exif[kCGImagePropertyExifFocalLength as String] as? Double {
                rows.append(("Focal Length", "\(Int(focal))mm"))
            }
        }
        if let w = props[kCGImagePropertyPixelWidth as String] as? Int,
           let h = props[kCGImagePropertyPixelHeight as String] as? Int {
            rows.append(("Dimensions", "\(w) × \(h)"))
        }
        return rows
    }

    @ViewBuilder
    private var kindSpecificRows: some View {
        // Voice: duration + transcription provider
        if let audioAtt = memo.attachments.first(where: { $0.kind == "audio" }) {
            if let dur = audioAtt.duration {
                metaRow(label: "Duration", value: dur.mmss)
            }
            if let transcript = audioAtt.transcript, !transcript.isEmpty {
                metaRow(label: "Transcription", value: "OpenAI Whisper")
            } else {
                metaRow(label: "Transcription", value: "Pending")
            }
        }

        // Photo: EXIF fields — rendered from state; resolved off-main in .task.
        ForEach(photoExifRows, id: \.label) { row in
            metaRow(label: row.label, value: row.value)
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

import SwiftUI
import PhotosUI
import UIKit
import ImageIO
import DayPageModels
import DayPageStorage
import DayPageServices

// MARK: - DailyPageMetadataEditView

/// 用于编辑 Daily Page 元数据字段的 Sheet：摘要、天气、心情、封面图片。
/// 更改会原子性地写回已编译日记的 YAML front-matter 中。
@MainActor
struct DailyPageMetadataEditView: View {

    let dateString: String
    let currentSummary: String
    let currentWeather: String
    let currentMood: String
    let currentCoverPath: String?
    let rawMemos: [Memo]

    @Environment(\.dismiss) private var dismiss

    @State private var summary: String = ""
    @State private var weather: String = ""
    @State private var mood: String = ""
    @State private var selectedCoverPath: String? = nil
    @State private var photosPickerItem: PhotosPickerItem? = nil
    @State private var coverPreview: UIImage? = nil
    @State private var isSaving: Bool = false
    @State private var saveError: String? = nil
    @State private var pendingCover: PendingCover? = nil
    @State private var coverTask: Task<Void, Never>? = nil
    @State private var coverGeneration = UUID()
    @State private var isLoadingCover = false
    @State private var presentationActive = false
    @State private var initialized = false
    @State private var capturedVaultRoot: URL? = nil
    @State private var capturedResolvedRoot: URL? = nil

    // Selection is a draft. No asset is created until explicit Save.
    private struct PendingCover {
        let jpeg: Data
        let relativePath: String
    }

    private struct MoodOption {
        // Keep persisted values stable across display languages and existing diaries.
        let storedValue: String
        let localizationKey: String
        let fallback: String

        var label: String {
            NSLocalizedString(localizationKey, value: fallback, comment: "Daily mood option")
        }
    }

    private let moodOptions = [
        MoodOption(storedValue: "😊 开心", localizationKey: "daily.metadata.mood.happy", fallback: "😊 Happy"),
        MoodOption(storedValue: "😐 平静", localizationKey: "daily.metadata.mood.calm", fallback: "😐 Calm"),
        MoodOption(storedValue: "😔 低落", localizationKey: "daily.metadata.mood.low", fallback: "😔 Low"),
        MoodOption(storedValue: "😤 烦躁", localizationKey: "daily.metadata.mood.irritable", fallback: "😤 Irritable"),
        MoodOption(storedValue: "🤩 兴奋", localizationKey: "daily.metadata.mood.excited", fallback: "🤩 Excited"),
        MoodOption(storedValue: "😴 疲惫", localizationKey: "daily.metadata.mood.tired", fallback: "😴 Tired"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                DSColor.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        summarySection
                        moodSection
                        weatherSection
                        coverSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                }
                .disabled(isSaving)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) {
                        endPresentation()
                        dismiss()
                    }
                    .disabled(isSaving)
                        .foregroundColor(DSColor.onSurface)
                }
                ToolbarItem(placement: .principal) {
                    Text(NSLocalizedString("daily.metadata.title", comment: "Edit daily page metadata title"))
                        .headlineMDStyle()
                        .foregroundColor(DSColor.onSurface)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSaving {
                        ProgressView().tint(DSColor.onSurface).scaleEffect(0.8)
                    } else {
                        Button(NSLocalizedString("common.save", comment: "Save")) {
                            save()
                        }
                        .foregroundColor(DSColor.primary)
                        .h2Style()
                        .disabled(isLoadingCover)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            presentationActive = true
            guard !initialized else { return }
            initialized = true
            let root = VaultInitializer.vaultURL.standardizedFileURL
            capturedVaultRoot = root
            capturedResolvedRoot = root.resolvingSymlinksInPath()
            summary = currentSummary
            weather = currentWeather
            mood = currentMood
            selectedCoverPath = currentCoverPath
            if let path = currentCoverPath {
                loadCoverPreview(path: path)
            }
        }
        .onDisappear { endPresentation() }
        .alert(NSLocalizedString("daily.metadata.save_failed", comment: "Metadata save failed alert title"), isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button(NSLocalizedString("common.confirm", comment: "Confirm"), role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .onChange(of: photosPickerItem) { newItem in
            guard let item = newItem else { return }
            beginPhotoImport(item: item)
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(NSLocalizedString("daily.metadata.section.summary", value: "SUMMARY", comment: "Summary section"))
            TextEditor(text: $summary)
                .bodyMDStyle()
                .foregroundColor(DSColor.onSurface)
                .frame(minHeight: 80)
                .padding(12)
                .background(DSColor.surfaceContainer)
                .cornerRadius(0)
                .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 1))
        }
    }

    private var moodSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(NSLocalizedString("daily.metadata.section.mood", value: "MOOD", comment: "Mood section"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(moodOptions, id: \.storedValue) { option in
                        Button(action: {
                            mood = mood == option.storedValue ? "" : option.storedValue
                        }) {
                            Text(option.label)
                                .captionStyle()
                                .foregroundColor(mood == option.storedValue ? DSColor.onPrimary : DSColor.onSurface)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(mood == option.storedValue ? DSColor.primary : DSColor.surfaceContainer)
                                .cornerRadius(0)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(option.localizationKey)
                        .accessibilityAddTraits(mood == option.storedValue ? [.isSelected] : [])
                    }
                }
            }
            if !mood.isEmpty && !moodOptions.contains(where: { $0.storedValue == mood }) {
                Text(mood)
                    .font(DSFonts.jetBrainsMono(size: 12, weight: .medium, relativeTo: .caption2))
                    .tracking(0.5)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .padding(.top, 4)
            }
        }
    }

    private var weatherSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(NSLocalizedString("daily.metadata.section.weather", value: "WEATHER", comment: "Weather section"))
            TextField(NSLocalizedString("daily.metadata.weather.placeholder", comment: "Weather metadata placeholder"), text: $weather)
                .bodyMDStyle()
                .foregroundColor(DSColor.onSurface)
                .padding(12)
                .background(DSColor.surfaceContainer)
                .cornerRadius(0)
                .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 1))
        }
    }

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(NSLocalizedString("daily.metadata.section.cover", value: "COVER IMAGE", comment: "Cover image section"))

            if let preview = coverPreview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .clipped()
                    .cornerRadius(0)
            }

            if isLoadingCover { ProgressView() }

            HStack(spacing: 12) {
                // Choose from existing raw memos photos
                Menu {
                    ForEach(photoAttachmentsFromMemos, id: \.file) { att in
                        Button(att.file.components(separatedBy: "/").last ?? att.file) {
                            loadCoverPreview(path: att.file)
                        }
                    }
                    if selectedCoverPath != nil || pendingCover != nil {
                        Divider()
                        Button(NSLocalizedString("daily.metadata.cover.remove", comment: "Remove cover image"), role: .destructive) {
                            cancelCoverWork()
                            pendingCover = nil
                            selectedCoverPath = nil
                            coverPreview = nil
                        }
                    }
                } label: {
                    Text(NSLocalizedString(selectedCoverPath == nil && pendingCover == nil ? "daily.metadata.cover.from_memos" : "daily.metadata.cover.change", comment: "Choose daily page cover"))
                        .labelSMStyle()
                        .foregroundColor(DSColor.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(DSColor.surfaceContainer)
                        .cornerRadius(0)
                        .overlay(Rectangle().stroke(DSColor.primary, lineWidth: 1))
                }
                .buttonStyle(.plain)

                // Pick from photo library
                PhotosPicker(selection: $photosPickerItem, matching: .images) {
                    Text(NSLocalizedString("daily.metadata.cover.from_library", comment: "Choose daily page cover from photo library"))
                        .labelSMStyle()
                        .foregroundColor(DSColor.onSurfaceVariant)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(DSColor.surfaceContainer)
                        .cornerRadius(0)
                        .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .sectionLabelStyle()
            .foregroundColor(DSColor.onSurfaceVariant)
    }

    // MARK: - Data Helpers

    private var photoAttachmentsFromMemos: [Memo.Attachment] {
        rawMemos.flatMap { $0.attachments }.filter { $0.kind == "photo" }
    }

    private var photoFailureMessage: String {
        NSLocalizedString("error.memo.photo_failed", comment: "Photo processing failed")
    }

    private func ownedRoot() -> URL? {
        guard presentationActive, let root = capturedVaultRoot,
              let resolved = capturedResolvedRoot,
              VaultInitializer.vaultURL.standardizedFileURL == root,
              root.resolvingSymlinksInPath() == resolved else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory),
              directory.boolValue else { return nil }
        return root
    }

    private func ownedURL(_ relativePath: String, root: URL) -> URL? {
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"),
              let resolved = capturedResolvedRoot,
              url.resolvingSymlinksInPath().path.hasPrefix(resolved.path + "/") else { return nil }
        return url
    }

    private func canPublish(_ generation: UUID, root: URL) -> Bool {
        presentationActive && coverGeneration == generation && ownedRoot() == root
    }

    private func cancelCoverWork() {
        coverGeneration = UUID()
        coverTask?.cancel()
        coverTask = nil
        isLoadingCover = false
    }

    private func endPresentation() {
        presentationActive = false
        cancelCoverWork()
    }

    private func showVaultChanged() {
        saveError = NSLocalizedString("today.recovery.vault_changed", comment: "Draft belongs to another vault")
    }

    private func loadCoverPreview(path: String) {
        cancelCoverWork()
        guard let root = ownedRoot(), let url = ownedURL(path, root: root) else {
            showVaultChanged()
            return
        }
        let generation = coverGeneration
        isLoadingCover = true
        coverTask = Task { @MainActor in
            defer {
                if presentationActive && coverGeneration == generation {
                    isLoadingCover = false
                    coverTask = nil
                }
            }
            // The processor reads only this already validated, captured URL.
            // It returns bounded JPEG Data; no UIImage crosses the actor boundary.
            do {
                let previewJPEG = try await CoverPhotoProcessor.shared.previewJPEG(at: url)
                guard !Task.isCancelled, canPublish(generation, root: root) else { return }
                guard let preview = UIImage(data: previewJPEG) else {
                    saveError = photoFailureMessage
                    return
                }
                guard !Task.isCancelled, canPublish(generation, root: root) else { return }
                selectedCoverPath = path
                pendingCover = nil
                coverPreview = preview
            } catch {
                guard !Task.isCancelled, canPublish(generation, root: root) else { return }
                saveError = photoFailureMessage
            }
        }
    }

    private func beginPhotoImport(item: PhotosPickerItem) {
        cancelCoverWork()
        guard let root = ownedRoot() else { showVaultChanged(); return }
        let generation = coverGeneration
        isLoadingCover = true
        coverTask = Task { @MainActor in
            defer {
                if presentationActive && coverGeneration == generation {
                    isLoadingCover = false
                    coverTask = nil
                }
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    if !Task.isCancelled && canPublish(generation, root: root) { saveError = photoFailureMessage }
                    return
                }
                guard !Task.isCancelled, canPublish(generation, root: root) else { return }
                let processed = try await CoverPhotoProcessor.shared.processImport(data)
                guard !Task.isCancelled, canPublish(generation, root: root) else { return }
                guard let preview = UIImage(data: processed.previewJPEG) else {
                    saveError = photoFailureMessage
                    return
                }
                guard !Task.isCancelled, canPublish(generation, root: root) else { return }
                pendingCover = PendingCover(jpeg: processed.savedJPEG,
                    relativePath: "raw/assets/cover-\(dateString)-\(UUID().uuidString).jpg")
                coverPreview = preview
            } catch {
                guard !Task.isCancelled, canPublish(generation, root: root) else { return }
                saveError = photoFailureMessage
            }
        }
    }

    // MARK: - Save

    private func save() {
        guard !isSaving, !isLoadingCover, presentationActive else { return }
        guard RawStorage.isValidDayString(dateString), let root = ownedRoot(),
              let dailyURL = ownedURL("wiki/daily/\(dateString).md", root: root) else {
            showVaultChanged()
            return
        }
        isSaving = true
        defer { isSaving = false }
        // No await here: fields, Cancel, and interactive dismissal cannot race
        // these writes through the main-actor UI. All URLs use the captured root.
        do {
            let content = try String(contentsOf: dailyURL, encoding: .utf8)
            let draft = pendingCover
            let path = draft?.relativePath ?? selectedCoverPath
            if draft != nil {
                let lines = content.components(separatedBy: "\n")
                guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
                      lines.dropFirst().contains(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
                    saveError = photoFailureMessage
                    return
                }
            }
            let updated = updateFrontmatter(content: content, summary: summary,
                weather: weather, mood: mood, coverPath: path)
            if let draft {
                guard ownedRoot() == root, let assetURL = ownedURL(draft.relativePath, root: root) else {
                    showVaultChanged()
                    return
                }
                if FileManager.default.fileExists(atPath: assetURL.path) {
                    // A retry may reuse only these exact draft bytes. Never
                    // overwrite a different existing/shared asset.
                    guard try Data(contentsOf: assetURL) == draft.jpeg else {
                        saveError = photoFailureMessage
                        return
                    }
                } else {
                    try RawStorage.atomicWrite(data: draft.jpeg, to: assetURL)
                }
            }
            guard ownedRoot() == root else { showVaultChanged(); return }
            try RawStorage.atomicWrite(string: updated, to: dailyURL)
            pendingCover = nil
            endPresentation()
            dismiss()
        } catch {
            // Do not delete an asset on thrown storage errors: the daily write
            // may already have committed. Keep the same UUID draft for retry.
            saveError = String(format: NSLocalizedString("error.memo.save_failed", comment: "Save failed"), error.localizedDescription)
        }
    }

    /// Updates YAML front-matter fields: summary, weather, mood, cover.
    /// Preserves all other fields and the body unchanged.
    private func updateFrontmatter(
        content: String,
        summary: String,
        weather: String,
        mood: String,
        coverPath: String?
    ) -> String {
        var lines = content.components(separatedBy: "\n")

        // Find front-matter bounds
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return content
        }

        var closingLine = -1
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closingLine = i
                break
            }
        }
        guard closingLine > 0 else { return content }

        // Update existing keys or insert before closing ---
        func setKey(_ key: String, value: String) {
            let prefix = "\(key):"
            if let idx = (1..<closingLine).first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }) {
                if value.isEmpty {
                    lines.remove(at: idx)
                    closingLine -= 1
                } else {
                    lines[idx] = "\(key): \(value)"
                }
            } else if !value.isEmpty {
                lines.insert("\(key): \(value)", at: closingLine)
                closingLine += 1
            }
        }

        setKey("summary", value: summary.isEmpty ? "" : "\"\(summary.replacingOccurrences(of: "\"", with: "\\\""))\"")
        setKey("weather", value: weather)
        setKey("mood", value: mood)
        setKey("cover", value: coverPath ?? "")

        return lines.joined(separator: "\n")
    }
}

// MARK: - Serial, memory-only cover processing

/// Both entry methods are synchronous actor-isolated work with no suspension
/// points, so this shared instance processes at most one image at a time.
/// UIKit/CoreGraphics image objects remain local; only Data crosses isolation.
private actor CoverPhotoProcessor {
    static let shared = CoverPhotoProcessor()

    struct ImportedCover: Sendable {
        let savedJPEG: Data
        let previewJPEG: Data
    }

    private enum ProcessingError: Error {
        case invalidImage
    }

    // Preview-only maximum edge. Saved covers keep their original dimensions.
    private static let previewMaximumPixelSize = 2048

    func processImport(_ data: Data) throws -> ImportedCover {
        try Task.checkCancellation()
        return try autoreleasepool {
            // Keep V2's full-resolution UIImage -> JPEG(0.85) save policy.
            // The inner pool shortens the full-size UIImage's temporary lifetime.
            let savedJPEG: Data = try autoreleasepool {
                try Task.checkCancellation()
                guard let image = UIImage(data: data) else {
                    throw ProcessingError.invalidImage
                }
                try Task.checkCancellation()
                guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
                    throw ProcessingError.invalidImage
                }
                try Task.checkCancellation()
                return jpeg
            }
            try Task.checkCancellation()
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
                throw ProcessingError.invalidImage
            }
            try Task.checkCancellation()
            let previewJPEG = try makePreviewJPEG(from: source)
            try Task.checkCancellation()
            return ImportedCover(savedJPEG: savedJPEG, previewJPEG: previewJPEG)
        }
    }

    func previewJPEG(at capturedOwnedURL: URL) throws -> Data {
        try Task.checkCancellation()
        return try autoreleasepool {
            // No vault lookup, asset write, or detached image task here.
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(capturedOwnedURL as CFURL, sourceOptions) else {
                throw ProcessingError.invalidImage
            }
            try Task.checkCancellation()
            return try makePreviewJPEG(from: source)
        }
    }

    private func makePreviewJPEG(from source: CGImageSource) throws -> Data {
        try Task.checkCancellation()
        // Avoid caching the full source. Decode the bounded, orientation-correct
        // thumbnail immediately, then release it after producing JPEG Data.
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.previewMaximumPixelSize,
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              thumbnail.width <= Self.previewMaximumPixelSize,
              thumbnail.height <= Self.previewMaximumPixelSize else {
            throw ProcessingError.invalidImage
        }
        try Task.checkCancellation()
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else { throw ProcessingError.invalidImage }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        CGImageDestinationAddImage(destination, thumbnail, properties)
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else {
            throw ProcessingError.invalidImage
        }
        try Task.checkCancellation()
        return output as Data
    }
}

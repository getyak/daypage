import SwiftUI
import PhotosUI

// MARK: - DailyPageMetadataEditView

/// 用于编辑 Daily Page 元数据字段的 Sheet：摘要、天气、心情、封面图片。
/// 更改会原子性地写回已编译日记的 YAML front-matter 中。
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

    private let moodOptions = ["😊 开心", "😐 平静", "😔 低落", "😤 烦躁", "🤩 兴奋", "😴 疲惫"]

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
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundColor(DSColor.onSurface)
                }
                ToolbarItem(placement: .principal) {
                    Text("编辑元数据")
                        .headlineMDStyle()
                        .foregroundColor(DSColor.onSurface)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSaving {
                        ProgressView().tint(DSColor.onSurface).scaleEffect(0.8)
                    } else {
                        Button("保存") {
                            Task { await save() }
                        }
                        .foregroundColor(DSColor.primary)
                        .h2Style()
                    }
                }
            }
        }
        .onAppear {
            summary = currentSummary
            weather = currentWeather
            mood = currentMood
            selectedCoverPath = currentCoverPath
            if let path = currentCoverPath {
                loadCoverPreview(path: path)
            }
        }
        .alert("保存失败", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .onChange(of: photosPickerItem) { newItem in
            guard let item = newItem else { return }
            Task { await loadSelectedPhoto(item: item) }
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("SUMMARY")
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
            sectionLabel("MOOD")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(moodOptions, id: \.self) { option in
                        Button(action: {
                            mood = mood == option ? "" : option
                        }) {
                            Text(option)
                                .captionStyle()
                                .foregroundColor(mood == option ? DSColor.onPrimary : DSColor.onSurface)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(mood == option ? DSColor.primary : DSColor.surfaceContainer)
                                .cornerRadius(0)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !mood.isEmpty && !moodOptions.contains(mood) {
                Text(mood)
                    .monoLabelStyle(size: 12)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .padding(.top, 4)
            }
        }
    }

    private var weatherSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("WEATHER")
            TextField("例如：晴 28°C", text: $weather)
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
            sectionLabel("COVER IMAGE")

            if let preview = coverPreview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .clipped()
                    .cornerRadius(0)
            }

            HStack(spacing: 12) {
                // Choose from existing raw memos photos
                Menu {
                    ForEach(photoAttachmentsFromMemos, id: \.file) { att in
                        Button(att.file.components(separatedBy: "/").last ?? att.file) {
                            selectedCoverPath = att.file
                            loadCoverPreview(path: att.file)
                        }
                    }
                    if selectedCoverPath != nil {
                        Divider()
                        Button("移除封面", role: .destructive) {
                            selectedCoverPath = nil
                            coverPreview = nil
                        }
                    }
                } label: {
                    Text(selectedCoverPath == nil ? "从记录中选择" : "更换封面")
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
                    Text("从相册选择")
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
            .foregroundColor(DSColor.outline)
    }

    // MARK: - Data Helpers

    private var photoAttachmentsFromMemos: [Memo.Attachment] {
        rawMemos.flatMap { $0.attachments }.filter { $0.kind == "photo" }
    }

    private func loadCoverPreview(path: String) {
        let url = VaultInitializer.vaultURL.appendingPathComponent(path)
        Task.detached(priority: .userInitiated) {
            let img = UIImage(contentsOfFile: url.path)
            await MainActor.run { self.coverPreview = img }
        }
    }

    private func loadSelectedPhoto(item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let img = UIImage(data: data) else { return }

        // Save to vault/raw/assets/
        let filename = "cover-\(dateString)-\(Int(Date().timeIntervalSince1970)).jpg"
        let assetsDir = VaultInitializer.vaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("assets")
        let fileURL = assetsDir.appendingPathComponent(filename)

        do {
            if !FileManager.default.fileExists(atPath: assetsDir.path) {
                try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
            }
            if let jpeg = img.jpegData(compressionQuality: 0.85) {
                try jpeg.write(to: fileURL)
            }
            selectedCoverPath = "raw/assets/\(filename)"
            coverPreview = img
        } catch {
            saveError = "保存封面图片失败: \(error.localizedDescription)"
        }
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let dailyURL = VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("daily")
            .appendingPathComponent("\(dateString).md")

        let content: String
        do { content = try String(contentsOf: dailyURL, encoding: .utf8) }
        catch { saveError = "无法读取日记文件"; DayPageLogger.shared.error("DailyPageView: read daily: \(error)"); return }

        let updated = updateFrontmatter(
            content: content,
            summary: summary,
            weather: weather,
            mood: mood,
            coverPath: selectedCoverPath
        )

        do {
            try RawStorage.atomicWrite(string: updated, to: dailyURL)
            dismiss()
        } catch {
            saveError = "写入失败: \(error.localizedDescription)"
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
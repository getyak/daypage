import SwiftUI
import UIKit
import Photos

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

    var id: String {
        switch self {
        case .memo(let s):    return "memo-\(s.id.uuidString)"
        case .daily(let s):   return "daily-\(s.dateString)"
        case .monthly(let s): return "monthly-\(s.monthTitle)"
        case .quote(let s):   return "quote-\(s.id.uuidString)"
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
        }
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

    static func from(_ memo: Memo, coverImage: UIImage? = nil) -> MemoSnapshot {
        let voiceDuration = memo.attachments
            .first(where: { $0.kind == "audio" })?
            .duration
        return MemoSnapshot(
            id: memo.id,
            body: memo.body,
            createdAt: memo.created,
            locationName: memo.location?.name,
            weather: memo.weather,
            coverImage: coverImage,
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

    static func from(_ model: DailyPageModel, coverImage: UIImage? = nil) -> DailySnapshot {
        let highlights = Array(model.sections.prefix(3).map { $0.title })
        return DailySnapshot(
            dateString: model.dateString,
            weekday: model.weekday.uppercased(),
            summary: model.summary,
            locationPrimary: model.locationPrimary,
            memoCount: model.memoCount,
            coverImage: coverImage,
            highlights: highlights
        )
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
        case (.polaroid, .memo):    return PolaroidMemoTemplate.render(payload)
        case (.polaroid, .daily):   return PolaroidDailyTemplate.render(payload)
        case (.polaroid, .monthly): return PolaroidMonthlyTemplate.render(payload)
        case (.polaroid, .quote):   return PolaroidQuoteTemplate.render(payload)
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

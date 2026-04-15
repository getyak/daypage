import SwiftUI
import UIKit
import ImageIO

// MARK: - MemoCardView

/// Displays a single Memo as a card in the Today timeline.
/// Shows time + content preview with expand/collapse for long text.
struct MemoCardView: View {

    let memo: Memo

    @State private var isExpanded: Bool = false

    // Maximum lines when collapsed
    private let previewLineLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: time chip + type icon
            HStack(alignment: .center, spacing: 8) {
                TimeChip(time: memo.created.formatted(.dateTime.hour().minute()))
                typeLabel
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // Photo thumbnail row (for photo and mixed memos with photo attachments)
            if let photoThumb = firstPhotoThumbnail {
                Image(uiImage: photoThumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .clipped()
                    .padding(.top, 6)
            }

            // Body content (caption)
            if !memo.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(memo.body.trimmingCharacters(in: .whitespacesAndNewlines))
                    .bodySMStyle()
                    .foregroundColor(DSColor.onSurface)
                    .lineLimit(isExpanded ? nil : previewLineLimit)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }

            // Bottom row: location label + expand toggle
            HStack(alignment: .center, spacing: 8) {
                if let locationName = memo.location?.name, !locationName.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "mappin")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(DSColor.onSurfaceVariant)
                        Text(locationName)
                            .monoLabelStyle(size: 9)
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                }

                Spacer()

                // Expand/collapse button for long content
                if needsExpansionButton {
                    Button(action: { isExpanded.toggle() }) {
                        Text(isExpanded ? "收起" : "展开")
                            .monoLabelStyle(size: 9)
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSColor.surfaceContainer)
        .overlay(
            Rectangle()
                .fill(borderColor)
                .frame(width: 3),
            alignment: .leading
        )
        .cornerRadius(0)
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

    /// Loads a thumbnail for the first photo attachment (if any).
    private var firstPhotoThumbnail: UIImage? {
        guard memo.type == .photo || memo.type == .mixed else { return nil }
        guard let att = memo.attachments.first(where: { $0.kind == "photo" }) else { return nil }
        let fileURL = VaultInitializer.vaultURL.appendingPathComponent(att.file)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // Use CGImageSource thumbnail for efficiency
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

    /// Whether the body is long enough to need an expand button.
    private var needsExpansionButton: Bool {
        let body = memo.body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Approximate: if body has many newlines or is long
        let lineCount = body.components(separatedBy: "\n").count
        return lineCount > previewLineLimit || body.count > 200
    }
}

// MARK: - DailyPageEntryCard

/// Card shown at the top of the timeline when today's Daily Page has been compiled.
struct DailyPageEntryCard: View {
    let summary: String?
    var onTap: (() -> Void)?

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(DSColor.primary)
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("今日日记")
                            .sectionLabelStyle()
                            .foregroundColor(DSColor.onSurface)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }

                    if let summary = summary, !summary.isEmpty {
                        Text(summary)
                            .bodySMStyle()
                            .foregroundColor(DSColor.onSurfaceVariant)
                            .italic()
                            .lineLimit(2)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DSColor.surfaceContainerHigh)
            }
            .cornerRadius(0)
        }
        .buttonStyle(.plain)
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
                HStack(spacing: 8) {
                    Text(isCompiling ? "正在编译..." : "今日还未编译")
                        .sectionLabelStyle()
                        .foregroundColor(isCompiling ? DSColor.onSurface : DSColor.onSurfaceVariant)

                    if isCompiling {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(DSColor.onSurfaceVariant)
                    }
                }

                if isCompiling {
                    Text("正在编译 \(memoCount) 条 memo...")
                        .bodySMStyle()
                        .foregroundColor(DSColor.onSurfaceVariant)
                } else if memoCount > 0 {
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
                            .cornerRadius(0)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCompiling)
                } else {
                    Text("记录今天的想法，晚些时候将自动编译成日记")
                        .bodySMStyle()
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSColor.surfaceContainer)
        }
        .cornerRadius(0)
        .animation(.easeInOut(duration: 0.2), value: isCompiling)
    }
}

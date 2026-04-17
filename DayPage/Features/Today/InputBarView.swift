import SwiftUI
import CoreLocation
import PhotosUI
import UIKit

// MARK: - InputBarView

/// Fixed bottom input bar: single text field + send button.
/// Secondary actions (mic, photo, file, location) live in a QuickBar
/// that appears above the system keyboard via toolbar(placement: .keyboard).
struct InputBarView: View {

    // MARK: Binding

    @Binding var text: String
    var isSubmitting: Bool
    var isLocating: Bool
    var pendingLocation: Memo.Location?
    var locationAuthStatus: CLAuthorizationStatus
    var isProcessingPhoto: Bool
    var pendingAttachments: [PendingAttachment]
    var onFetchLocation: () -> Void
    var onClearLocation: () -> Void
    var onAddPhoto: (PhotosPickerItem) -> Void
    var onCapturePhoto: () -> Void
    var onRemoveAttachment: (String) -> Void
    var onStartVoiceRecording: () -> Void
    var onAddFile: () -> Void
    var onSubmit: () -> Void

    // MARK: Private State

    @FocusState private var isFocused: Bool
    @State private var selectedItem: PhotosPickerItem? = nil
    @State private var showPhotoSourceDialog: Bool = false

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(DSColor.outline)

            // Staged attachment preview cards
            if !pendingAttachments.isEmpty {
                attachmentPreviewRow
            }

            // Location chip row
            if let loc = pendingLocation {
                locationChipRow(loc: loc)
            }

            // Main row: TextField + send button only
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("LOG NEW OBSERVATION...")
                            .font(.custom("JetBrainsMono-Regular", fixedSize: 13))
                            .foregroundColor(DSColor.outlineVariant)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .bodyMDStyle()
                        .foregroundColor(DSColor.onSurface)
                        .focused($isFocused)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 44, maxHeight: 140)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                        // QuickBar above keyboard
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                quickBar
                            }
                        }
                }
                .background(DSColor.surfaceContainerLow)

                submitButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(DSColor.surfaceContainerLow)
        }
        .onChange(of: selectedItem) { newItem in
            guard let item = newItem else { return }
            onAddPhoto(item)
            selectedItem = nil
        }
        .confirmationDialog("选择照片来源", isPresented: $showPhotoSourceDialog, titleVisibility: .visible) {
            Button("拍照") { onCapturePhoto() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - QuickBar (keyboard accessory)

    @ViewBuilder
    private var quickBar: some View {
        // Mic
        Button(action: { onStartVoiceRecording() }) {
            Image(systemName: "mic")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(DSColor.onSurfaceVariant)
        }

        // Camera (tap = photo dialog, separate from library)
        Button(action: { showPhotoSourceDialog = true }) {
            Image(systemName: "camera")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(DSColor.onSurfaceVariant)
        }

        // Photo library
        PhotosPicker(
            selection: $selectedItem,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Image(systemName: "photo")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(isProcessingPhoto ? DSColor.amberArchival : DSColor.onSurfaceVariant)
        }
        .buttonStyle(.plain)

        // File attachment
        Button(action: { onAddFile() }) {
            Image(systemName: "paperclip")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(DSColor.onSurfaceVariant)
        }

        // Location
        Button(action: {
            guard !isLocating else { return }
            onFetchLocation()
        }) {
            if isLocating {
                ProgressView()
                    .tint(DSColor.amberArchival)
            } else {
                Image(systemName: "mappin.circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(pendingLocation != nil ? DSColor.amberArchival : DSColor.onSurfaceVariant)
            }
        }
        .disabled(isLocating || locationAuthStatus == .denied || locationAuthStatus == .restricted)

        Spacer()
    }

    // MARK: - Submit Button

    @ViewBuilder
    private var submitButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         || !pendingAttachments.isEmpty
        Button(action: {
            guard hasContent, !isSubmitting else { return }
            onSubmit()
        }) {
            if isSubmitting {
                ProgressView()
                    .tint(DSColor.onPrimary)
                    .frame(width: 44, height: 44)
                    .background(DSColor.onSurfaceVariant)
            } else {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(hasContent ? DSColor.onPrimary : DSColor.onSurfaceVariant)
                    .frame(width: 44, height: 44)
                    .background(hasContent ? DSColor.primary : DSColor.surfaceContainerHigh)
            }
        }
        .disabled(!hasContent || isSubmitting)
        .cornerRadius(0)
    }

    // MARK: - Attachment Preview Row

    @ViewBuilder
    private var attachmentPreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { att in
                    attachmentCard(att)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(DSColor.surfaceContainerLow)
    }

    @ViewBuilder
    private func attachmentCard(_ att: PendingAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            switch att {
            case .photo(let result):
                photoCard(result)
            case .voice(let result):
                voiceCard(result)
            case .file(let result):
                fileCard(result)
            }
            Button(action: { onRemoveAttachment(att.id) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DSColor.onSurface)
                    .background(Circle().fill(DSColor.surfaceContainerHigh))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
    }

    @ViewBuilder
    private func photoCard(_ result: PhotoPickerResult) -> some View {
        let fileURL = VaultInitializer.vaultURL.appendingPathComponent(result.filePath)
        let uiImage: UIImage? = {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return UIImage(data: data)
        }()
        Group {
            if let img = uiImage {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(DSColor.surfaceContainerHigh)
                    .overlay(Image(systemName: "photo").foregroundColor(DSColor.onSurfaceVariant))
            }
        }
        .frame(width: 64, height: 64)
        .clipped()
        .cornerRadius(0)
    }

    @ViewBuilder
    private func fileCard(_ result: FilePickerResult) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "doc.fill").font(.system(size: 20)).foregroundColor(DSColor.onSurfaceVariant)
            Text(result.fileName).monoLabelStyle(size: 9).foregroundColor(DSColor.onSurfaceVariant)
                .lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(width: 64, height: 64)
        .background(DSColor.surfaceContainerHigh)
        .cornerRadius(0)
    }

    @ViewBuilder
    private func voiceCard(_ result: VoiceRecordingResult) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "mic.fill").font(.system(size: 20)).foregroundColor(DSColor.onSurfaceVariant)
            Text(formatDuration(result.duration)).monoLabelStyle(size: 9).foregroundColor(DSColor.onSurfaceVariant)
        }
        .frame(width: 64, height: 64)
        .background(DSColor.surfaceContainerHigh)
        .cornerRadius(0)
    }

    // MARK: - Location Chip

    @ViewBuilder
    private func locationChipRow(loc: Memo.Location) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "mappin").font(.system(size: 10, weight: .semibold)).foregroundColor(DSColor.amberArchival)
            Text(locationLabel(loc)).monoLabelStyle(size: 10).foregroundColor(DSColor.amberArchival).lineLimit(1)
            Spacer()
            Button(action: onClearLocation) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(DSColor.onSurfaceVariant)
            }
            .cornerRadius(0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(DSColor.surfaceContainerLow)
    }

    // MARK: - Helpers

    private func locationLabel(_ loc: Memo.Location) -> String {
        if let name = loc.name, !name.isEmpty { return name }
        if let lat = loc.lat, let lng = loc.lng { return String(format: "%.4f, %.4f", lat, lng) }
        return "未知位置"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

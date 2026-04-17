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
    var onVoiceComplete: (VoiceRecordingResult) -> Void
    var onAddFile: () -> Void
    var onSubmit: () -> Void

    // MARK: Private State

    @FocusState private var isFocused: Bool
    @State private var selectedItem: PhotosPickerItem? = nil
    @State private var showPhotoSourceDialog: Bool = false
    @State private var showVoiceSheet: Bool = false

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
                            .monoLabelStyle(size: 13)
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
        .sheet(isPresented: $showVoiceSheet) {
            VoiceRecordingView(
                onComplete: { result in
                    showVoiceSheet = false
                    onVoiceComplete(result)
                },
                onCancel: { showVoiceSheet = false }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
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
        let icon = isSubmitting ? "arrow.up" : "arrow.up"
        ZStack {
            if isSubmitting {
                ProgressView()
                    .tint(DSColor.onPrimary)
                    .frame(width: 44, height: 44)
                    .background(DSColor.onSurfaceVariant)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(hasContent ? DSColor.onPrimary : DSColor.onSurfaceVariant)
                    .frame(width: 44, height: 44)
                    .background(hasContent ? DSColor.primary : DSColor.surfaceContainerHigh)
            }
        }
        .cornerRadius(0)
        .contentShape(Rectangle())
        // Short tap: send text
        .onTapGesture {
            guard hasContent, !isSubmitting else { return }
            onSubmit()
        }
        // Long press (0.3s): open voice recording half-sheet
        .onLongPressGesture(minimumDuration: 0.3) {
            guard !isSubmitting else { return }
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            showVoiceSheet = true
        }
    }

    // MARK: - Attachment Chip Row

    @ViewBuilder
    private var attachmentPreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { att in
                    attachmentChip(att)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(DSColor.surfaceContainerLow)
    }

    @ViewBuilder
    private func attachmentChip(_ att: PendingAttachment) -> some View {
        let (icon, label) = chipContent(att)
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(DSColor.onSurfaceVariant)
            Text(label)
                .monoLabelStyle(size: 11)
                .foregroundColor(DSColor.onSurfaceVariant)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120)
            Button(action: { onRemoveAttachment(att.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: 32)
        .background(DSColor.surfaceContainerHigh)
        .cornerRadius(6)
    }

    private func chipContent(_ att: PendingAttachment) -> (icon: String, label: String) {
        switch att {
        case .photo(let result):
            let name = (result.filePath as NSString).lastPathComponent
            return ("photo", String(name.prefix(20)))
        case .voice(let result):
            return ("mic.fill", formatDuration(result.duration))
        case .file(let result):
            return ("doc.fill", String(result.fileName.prefix(20)))
        }
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

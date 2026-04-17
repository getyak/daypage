import SwiftUI
import CoreLocation
import PhotosUI
import UIKit

// MARK: - InputBarView

/// Fixed bottom input bar for composing and submitting text/photo/voice/mixed memos.
/// Provides a multiline TextEditor, a location pin button, a camera/photo button, a mic button,
/// staged attachment preview cards (photo + voice), and a submit button.
struct InputBarView: View {

    // MARK: Binding

    /// The draft text the user is composing.
    @Binding var text: String

    /// Whether a submission is currently in progress.
    var isSubmitting: Bool

    /// Whether a location fetch is in progress.
    var isLocating: Bool

    /// The pending location (if already fetched); shown as a removable chip.
    var pendingLocation: Memo.Location?

    /// Current CLLocation authorization status (for denied-state guidance).
    var locationAuthStatus: CLAuthorizationStatus

    /// Whether a photo is being processed.
    var isProcessingPhoto: Bool

    /// Staged attachments waiting to be submitted (photo + voice).
    var pendingAttachments: [PendingAttachment]

    /// Callback invoked when the user taps the location pin icon.
    var onFetchLocation: () -> Void

    /// Callback invoked when the user clears the pending location chip.
    var onClearLocation: () -> Void

    /// Callback invoked when the user selects a photo from the picker (staged, not submitted).
    var onAddPhoto: (PhotosPickerItem) -> Void

    /// Callback invoked when the user chooses to take a photo with the camera.
    var onCapturePhoto: () -> Void

    /// Callback invoked when the user removes a staged attachment.
    var onRemoveAttachment: (String) -> Void

    /// Callback invoked when the user taps the microphone icon to start recording.
    var onStartVoiceRecording: () -> Void

    /// Callback invoked when the user taps the submit button.
    var onSubmit: () -> Void

    // MARK: Private State

    @FocusState private var isFocused: Bool

    /// PhotosPicker selection binding (single item).
    @State private var selectedItem: PhotosPickerItem? = nil

    /// Whether the photo source confirmation dialog is shown (long-press on photo button).
    @State private var showPhotoSourceDialog: Bool = false

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(DSColor.outline)

            // Attachment preview cards (staged photos + voice recordings)
            if !pendingAttachments.isEmpty {
                attachmentPreviewRow
            }

            // Location chip row (shown when a pending location exists)
            if let loc = pendingLocation {
                locationChipRow(loc: loc)
            }

            HStack(alignment: .bottom, spacing: 8) {
                // Microphone / Voice recording button
                microphoneButton

                // Camera / Photo picker button
                photoButton

                // Multiline text input
                ZStack(alignment: .topLeading) {
                    // Placeholder text
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
                }
                .background(DSColor.surfaceContainerLow)

                // Location pin button (right side per design)
                locationButton

                // Submit button
                submitButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(DSColor.surfaceContainerLow)
        }
        // Wire PhotosPicker onChange to callback
        .onChange(of: selectedItem) { newItem in
            guard let item = newItem else { return }
            onAddPhoto(item)
            // Reset picker selection so same item can be re-selected
            selectedItem = nil
        }
    }

    // MARK: - Subviews

    /// Horizontal scrollable row of staged attachment preview cards.
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

    /// Single attachment preview card with a remove button.
    @ViewBuilder
    private func attachmentCard(_ att: PendingAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            switch att {
            case .photo(let result):
                photoCard(result)
            case .voice(let result):
                voiceCard(result)
            }

            // Remove (X) button
            Button(action: { onRemoveAttachment(att.id) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DSColor.onSurface)
                    .background(
                        Circle()
                            .fill(DSColor.surfaceContainerHigh)
                    )
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
    }

    /// Photo thumbnail card (64x64 pt).
    @ViewBuilder
    private func photoCard(_ result: PhotoPickerResult) -> some View {
        let fileURL = VaultInitializer.vaultURL.appendingPathComponent(result.filePath)
        let uiImage: UIImage? = {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return UIImage(data: data)
        }()

        Group {
            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(DSColor.surfaceContainerHigh)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(DSColor.onSurfaceVariant)
                    )
            }
        }
        .frame(width: 64, height: 64)
        .clipped()
        .cornerRadius(0)
    }

    /// Voice memo preview card showing duration.
    @ViewBuilder
    private func voiceCard(_ result: VoiceRecordingResult) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "mic.fill")
                .font(.system(size: 20))
                .foregroundColor(DSColor.onSurfaceVariant)
            Text(formatDuration(result.duration))
                .monoLabelStyle(size: 9)
                .foregroundColor(DSColor.onSurfaceVariant)
        }
        .frame(width: 64, height: 64)
        .background(DSColor.surfaceContainerHigh)
        .cornerRadius(0)
    }

    /// Pin/map icon button. Shows a spinner during fetch, amber when location is attached.
    @ViewBuilder
    private var locationButton: some View {
        Button(action: {
            guard !isLocating else { return }
            onFetchLocation()
        }) {
            if isLocating {
                ProgressView()
                    .tint(DSColor.amberArchival)
                    .frame(width: 36, height: 36)
            } else {
                Image(systemName: "mappin.circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(pendingLocation != nil ? DSColor.amberArchival : DSColor.onSurfaceVariant)
                    .frame(width: 36, height: 36)
            }
        }
        .disabled(isLocating || locationAuthStatus == .denied || locationAuthStatus == .restricted)
        .cornerRadius(0)
    }

    /// Microphone button to open the voice recording sheet.
    @ViewBuilder
    private var microphoneButton: some View {
        Button(action: {
            onStartVoiceRecording()
        }) {
            Image(systemName: "mic")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(DSColor.onSurfaceVariant)
                .frame(width: 36, height: 36)
        }
        .cornerRadius(0)
    }

    /// Camera/photo library button.
    /// Tap: opens photo library picker. Long-press: shows action sheet to choose camera or library.
    @ViewBuilder
    private var photoButton: some View {
        if isProcessingPhoto {
            ProgressView()
                .tint(DSColor.onSurfaceVariant)
                .frame(width: 36, height: 36)
        } else {
            PhotosPicker(
                selection: $selectedItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Image(systemName: "photo")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .cornerRadius(0)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4)
                    .onEnded { _ in showPhotoSourceDialog = true }
            )
            .confirmationDialog("选择照片来源", isPresented: $showPhotoSourceDialog, titleVisibility: .visible) {
                Button("拍照") {
                    onCapturePhoto()
                }
                Button("从相册选择") {
                    // The PhotosPicker tap gesture handles this path; trigger programmatically
                    // by toggling a dummy flag — the picker is already wired via selectedItem.
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    /// Arrow-up submit button. Enabled when there is text or at least one staged attachment.
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

    /// Removable chip showing the resolved location name (or coordinates).
    @ViewBuilder
    private func locationChipRow(loc: Memo.Location) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "mappin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DSColor.amberArchival)

            Text(locationLabel(loc))
                .monoLabelStyle(size: 10)
                .foregroundColor(DSColor.amberArchival)
                .lineLimit(1)

            Spacer()

            Button(action: onClearLocation) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
            .cornerRadius(0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(DSColor.surfaceContainerLow)
    }

    // MARK: - Helpers

    private func locationLabel(_ loc: Memo.Location) -> String {
        if let name = loc.name, !name.isEmpty {
            return name
        }
        if let lat = loc.lat, let lng = loc.lng {
            return String(format: "%.4f, %.4f", lat, lng)
        }
        return "未知位置"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

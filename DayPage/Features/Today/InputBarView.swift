import SwiftUI
import CoreLocation
import PhotosUI

// MARK: - InputBarView

/// Fixed bottom input bar for composing and submitting text/photo memos.
/// Provides a multiline TextEditor, a location pin button, a camera/photo button, and a submit button.
/// Auto-captures device info in YAML frontmatter on submit.
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

    /// Callback invoked when the user taps the location pin icon.
    var onFetchLocation: () -> Void

    /// Callback invoked when the user clears the pending location chip.
    var onClearLocation: () -> Void

    /// Callback invoked when the user selects a photo from the picker.
    var onSelectPhoto: (PhotosPickerItem) -> Void

    /// Callback invoked when the user taps the microphone icon to start recording.
    var onStartVoiceRecording: () -> Void

    /// Callback invoked when the user taps the submit button.
    var onSubmit: () -> Void

    // MARK: Private State

    @FocusState private var isFocused: Bool

    /// PhotosPicker selection binding (single item).
    @State private var selectedItem: PhotosPickerItem? = nil

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(DSColor.outline)

            // Location chip row (shown when a pending location exists)
            if let loc = pendingLocation {
                locationChipRow(loc: loc)
            }

            HStack(alignment: .bottom, spacing: 8) {
                // Location pin button
                locationButton

                // Microphone / Voice recording button
                microphoneButton

                // Camera / Photo picker button
                photoButton

                // Multiline text input
                ZStack(alignment: .topLeading) {
                    // Placeholder text
                    if text.isEmpty {
                        Text("记录想法…")
                            .bodyMDStyle()
                            .foregroundColor(DSColor.onSurfaceVariant)
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
            onSelectPhoto(item)
            // Reset picker selection so same item can be re-selected
            selectedItem = nil
        }
    }

    // MARK: - Subviews

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

    /// Camera/photo library button using PhotosPicker.
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
        }
    }

    /// Arrow-up submit button.
    @ViewBuilder
    private var submitButton: some View {
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Button(action: {
            guard !isEmpty, !isSubmitting else { return }
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
                    .foregroundColor(isEmpty ? DSColor.onSurfaceVariant : DSColor.onPrimary)
                    .frame(width: 44, height: 44)
                    .background(isEmpty ? DSColor.surfaceContainerHigh : DSColor.primary)
            }
        }
        .disabled(isEmpty || isSubmitting)
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
}

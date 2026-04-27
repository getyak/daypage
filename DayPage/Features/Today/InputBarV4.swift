import SwiftUI
import CoreLocation
import PhotosUI
import UIKit

// MARK: - InputBarV4  "Silent Press-to-Talk"
//
// Capture v2 surface. Frosted-glass capsule (ultraThinMaterial) carrying
// a visible mic-hero on the right; tap the capsule body to expand into a
// text composer; long-press the mic-hero to record.
//
// States:
//   collapsed  — capsule: "Hold to talk" hint + visible mic-hero on right
//   composing  — capsule expands to TextField; + button on left, send
//                arrow on right
//   recording  — PressToTalk overlay; capsule stays visible
//
// No bottom shelf. Capture v2 design note 03: "Notes / Attach / Camera
// labels — gone. Iconography under explicit text labels is a tell that
// the icons are not legible." Attachments live behind the `+` button
// inside the composing capsule.

struct InputBarV4: View {

    // MARK: Bindings (identical surface to V2/V3)

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
    var onPressToTalkSend: (VoiceRecordingResult) -> Void
    var onPressToTalkTranscribe: (String) -> Void
    var onAddFile: () -> Void
    var onSubmit: () -> Void

    // MARK: Private State

    @FocusState private var isFocused: Bool
    @State private var showAttachmentMenu: Bool = false
    @State private var photosPickerItem: PhotosPickerItem? = nil
    @State private var pressToTalkPhase: PressToTalkPhase = .idle
    @State private var userExpandedText: Bool = false
    /// True while a "录音太短" hint is visible. Prevents committing a
    /// meaningless one-frame recording while gracefully nudging the user
    /// toward the hold gesture.
    @State private var showTooShortToast: Bool = false

    @StateObject private var voiceService = VoiceService.shared

    @Namespace private var morphNS

    /// Recording floor below which a press-and-release is treated as
    /// accidental noise. Capture v2 boundary: respect the user's time —
    /// a sub-second silent clip carries no meaning, drop it with a hint.
    private static let minRecordingSeconds: Int = 1

    /// True when the active recording is below the meaning threshold AND
    /// the captured waveform is silent. Both gates so a brief but audible
    /// "嗯" / "对" / "好" still goes through.
    private var isRecordingTooShort: Bool {
        let belowFloor = voiceService.elapsedSeconds < Self.minRecordingSeconds
        let isSilent = voiceService.waveformHistory.allSatisfy { $0 < 0.05 }
        return belowFloor && isSilent
    }

    // MARK: Derived

    private var isComposing: Bool {
        userExpandedText || !text.isEmpty || !pendingAttachments.isEmpty || pendingLocation != nil
    }

    private var overlayMode: RecordingOverlayMode? {
        switch pressToTalkPhase {
        case .idle:           return nil
        case .recording:      return .recording
        case .cancelArmed:    return .cancelArmed
        case .transcribeArmed: return .transcribeArmed
        case .transcribing:   return .transcribing
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            if let mode = overlayMode {
                RecordingOverlayView(
                    mode: mode,
                    elapsedSeconds: voiceService.elapsedSeconds,
                    waveform: voiceService.waveformHistory
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: mode)
            }

            Rectangle()
                .fill(DSColor.outlineVariant.opacity(0.5))
                .frame(height: 0.5)

            if !pendingAttachments.isEmpty {
                attachmentPreviewRow
            }

            if let loc = pendingLocation {
                locationChipRow(loc: loc)
            }

            HStack(alignment: .bottom, spacing: 10) {
                if isComposing {
                    composingCapsule
                } else {
                    collapsedCapsule
                }
                sendButton
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isComposing)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(DSColor.backgroundWarm)
        .overlay(alignment: .top) {
            if showTooShortToast {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .semibold))
                    Text("再说久一点 · 至少 1 秒")
                        .font(.custom("Inter-Regular", size: 11))
                }
                .foregroundColor(DSColor.onSurface)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(DSColor.surfaceContainerHigh)
                .clipShape(Capsule())
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
                .padding(.top, -34)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityLabel("录音太短，请按住麦克风继续说")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showTooShortToast)
        .sheet(isPresented: $showAttachmentMenu) {
            AttachmentMenuPopover(
                onCapturePhoto: { showAttachmentMenu = false; onCapturePhoto() },
                onPickPhoto: { showAttachmentMenu = false },
                onAddFile: { showAttachmentMenu = false; onAddFile() },
                onAddLocation: { showAttachmentMenu = false; onFetchLocation() },
                isLocating: isLocating,
                hasPendingLocation: pendingLocation != nil
            )
        }
        .onChange(of: photosPickerItem) { newItem in
            guard let item = newItem else { return }
            onAddPhoto(item)
            photosPickerItem = nil
        }
    }

    // MARK: - Collapsed Capsule
    //
    // Layout: [ "Hold to talk · tap to write" pill ] [ mic-hero ]
    // - Tap the pill body → expand to text composing mode
    // - Long-press the mic-hero → press-to-talk recording flow
    //
    // The two regions are siblings, not overlaid, so the hit areas are
    // unambiguous. Previously the press-to-talk button was an invisible
    // overlay on the right quarter of the pill — users had no visual cue
    // for where to press.

    private var collapsedCapsule: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    userExpandedText = true
                }
                isFocused = true
            } label: {
                HStack(spacing: 10) {
                    Text("Hold to talk")
                        .font(.custom("SpaceGrotesk-Medium", size: 15))
                        .foregroundStyle(DSColor.onBackgroundPrimary)

                    Text("·")
                        .foregroundStyle(DSColor.onBackgroundSubtle)

                    Text("tap to write")
                        .font(.custom("SpaceGrotesk-Regular", size: 13))
                        .foregroundStyle(DSColor.onBackgroundSubtle)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(DSColor.outlineVariant.opacity(0.5), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            PressToTalkButton(
                onTap: {},
                onPressStart: handlePressToTalkStart,
                onReleaseSend: handlePressToTalkReleaseSend,
                onReleaseCancel: handlePressToTalkReleaseCancel,
                onReleaseTranscribe: handlePressToTalkReleaseTranscribe,
                onPhaseChange: { pressToTalkPhase = $0 },
                size: 48,
                idleBackgroundColor: DSColor.onBackgroundPrimary,
                idleIconColor: .white
            )
            .accessibilityLabel("按住说话")
        }
    }

    // MARK: - Composing Capsule

    private var composingCapsule: some View {
        HStack(alignment: .center, spacing: 8) {
            // + button
            Button {
                showAttachmentMenu = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DSColor.onBackgroundMuted)
                    .frame(width: 28, height: 28)
                    .background(DSColor.surfaceSunken, in: Circle())
            }
            .buttonStyle(.plain)
            .overlay {
                PhotosPicker(selection: $photosPickerItem, matching: .images, photoLibrary: .shared()) {
                    Color.clear
                }
                .opacity(0)
                .allowsHitTesting(false)
            }

            // Multi-line text field — no system inset, aligns naturally with + button
            TextField("Write something…", text: $text, axis: .vertical)
                .font(.custom("SpaceGrotesk-Regular", size: 15))
                .foregroundStyle(DSColor.onBackgroundPrimary)
                .focused($isFocused)
                .lineLimit(1...5)
                .tint(DSColor.onBackgroundPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(DSColor.outlineVariant.opacity(0.5), lineWidth: 0.5)
                )
        )
        .onTapGesture { isFocused = true }
    }

    // MARK: - Send Button

    private var sendButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button(action: handleSend) {
            Group {
                if isSubmitting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
            .background(
                hasContent ? DSColor.onBackgroundPrimary : DSColor.onBackgroundSubtle.opacity(0.3),
                in: Circle()
            )
            .animation(.easeInOut(duration: 0.18), value: hasContent)
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting || !hasContent)
    }

    // MARK: - Actions

    private func handleSend() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { userExpandedText = false }
            isFocused = false
            return
        }
        onSubmit()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { userExpandedText = false }
    }

    private func handlePressToTalkStart() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await voiceService.startRecording() }
    }

    private func handlePressToTalkReleaseSend() {
        // Boundary: a sub-second silent press is almost always a mis-tap.
        // Cancel the recording, warn-haptic, and surface the toast — don't
        // commit a meaningless 0:00 voice memo.
        if isRecordingTooShort {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            voiceService.cancelRecording()
            flashTooShortToast()
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            if let result = await voiceService.stopAndTranscribe() {
                onPressToTalkSend(result)
            }
        }
    }

    private func handlePressToTalkReleaseCancel() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        voiceService.cancelRecording()
    }

    private func handlePressToTalkReleaseTranscribe() {
        // Same floor as the send path — a transcribe gesture on a silent
        // sub-second clip would burn an API call and return nothing.
        if isRecordingTooShort {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            voiceService.cancelRecording()
            flashTooShortToast()
            // Critical: the transcribe branch in PressToTalkButton.onEnded
            // early-returns past the unconditional `.idle` reset that the
            // send/cancel paths fall through to. Without this line the
            // RecordingOverlayView stays mounted in `.transcribing` until
            // the user kicks off a new gesture.
            pressToTalkPhase = .idle
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            if let result = await voiceService.stopAndTranscribe(),
               let t = result.transcript, !t.isEmpty {
                onPressToTalkTranscribe(t)
            }
        }
    }

    private func flashTooShortToast() {
        showTooShortToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            showTooShortToast = false
        }
    }

    // MARK: - Attachment Preview

    private var attachmentPreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { att in attachmentChip(att) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private func attachmentChip(_ att: PendingAttachment) -> some View {
        let (icon, label) = chipContent(att)
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(DSColor.onBackgroundMuted)
            Text(label).font(.system(size: 12)).foregroundStyle(DSColor.onBackgroundMuted).lineLimit(1)
            Button { onRemoveAttachment(att.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DSColor.onBackgroundSubtle)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(DSColor.surfaceSunken, in: Capsule())
    }

    private func chipContent(_ att: PendingAttachment) -> (icon: String, label: String) {
        switch att {
        case .photo(let r): return ("photo", r.fileURL.lastPathComponent)
        case .voice(let r): return ("mic",   r.filePath.split(separator: "/").last.map(String.init) ?? "Voice")
        case .file(let r):  return ("doc",   r.fileName)
        }
    }

    private func locationChipRow(loc: Memo.Location) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "mappin").font(.system(size: 10, weight: .semibold)).foregroundStyle(DSColor.accentAmber)
            Text(locationLabel(loc)).font(.system(size: 12)).foregroundStyle(DSColor.accentAmber).lineLimit(1)
            Spacer()
            Button(action: onClearLocation) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(DSColor.onBackgroundSubtle)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func locationLabel(_ loc: Memo.Location) -> String {
        if let name = loc.name, !name.isEmpty { return name }
        if let lat = loc.lat, let lng = loc.lng {
            return String(format: "%.4f, %.4f", lat, lng)
        }
        return "Unknown location"
    }
}

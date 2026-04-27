import SwiftUI

// MARK: - RecordingView (placeholder)

/// Placeholder view — will be wired to AVAudioRecorder in the next iteration.
struct RecordingView: View {

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("DayPage Watch")
                .font(.headline)

            Text("Recording coming soon")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    RecordingView()
}

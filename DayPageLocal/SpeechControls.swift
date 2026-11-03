import DayPageCore
import SwiftUI

struct SpeechControls: View {
  @ObservedObject var playback: SpeechPlayback
  let text: String
  let id: String
  let accessibilityID: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Button {
          if playback.isActive(id: id) { playback.stop() }
          else { playback.speak(text, id: id) }
        } label: {
          Label(playback.isActive(id: id) ? "Stop speech" : "Read aloud",
            systemImage: playback.isActive(id: id) ? "stop.circle" : "speaker.wave.2")
            .frame(minHeight: 44)
        }.accessibilityIdentifier(accessibilityID)
        if playback.isActive(id: id), !playback.isPreparing {
          Button(playback.isPaused ? "Resume" : "Pause") {
            if playback.isPaused { playback.resume() } else { playback.pause() }
          }.frame(minWidth: 44, minHeight: 44).accessibilityIdentifier(accessibilityID + "-pause")
        }
      }.font(.caption)
      if playback.requestID == id {
        if let channel = playback.channelName {
          Text(channel).font(.caption2).foregroundStyle(.secondary)
        }
        if let error = playback.error {
          Text(error).font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier(accessibilityID + "-error")
        } else if let status = playback.status {
          Text(status).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }
}

import SwiftUI

struct FeedbackView: View {
  @AppStorage("local.feedback-draft") private var draft = ""
  @Environment(\.openURL) private var openURL
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text("A small note\nto make DayPage better.").font(NotebookTheme.reading(30))
        Text("Your feedback draft stays on this device. Nothing is sent automatically.")
          .font(.subheadline).foregroundStyle(.secondary)
        TextEditor(text: $draft)
          .frame(minHeight: 220).padding(12)
          .scrollContentBackground(.hidden)
          .background(NotebookTheme.card, in: RoundedRectangle(cornerRadius: 16))
          .accessibilityLabel("Feedback draft")
          .accessibilityIdentifier("feedback-draft")
        ShareLink(item: draft) {
          Label("Share feedback draft", systemImage: "square.and.arrow.up").frame(minHeight: 44)
        }
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button {
          var url = URLComponents(string: "https://github.com/getyak/daypage/issues/new")
          url?.queryItems = [
            URLQueryItem(name: "title", value: "DayPage Local feedback"),
            URLQueryItem(name: "body", value: String(draft.prefix(10000))),
          ]
          if let url = url?.url { openURL(url) }
        } label: {
          Label("Open GitHub feedback", systemImage: "arrow.up.right").frame(minHeight: 44)
        }
        Text(
          "You review and submit the feedback yourself. No notebook content or API keys are attached."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      .padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity)
    }
    .notebookSurface()
  }
}

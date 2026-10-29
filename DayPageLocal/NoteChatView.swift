import DayPageCore
import SwiftUI

@MainActor
private final class ChatSession: ObservableObject {
  @Published var conversation = Conversation()
  @Published var draft = ""
  @Published var sending = false
  @Published var ready = false
  @Published var error: String?
  private var revision: UInt64 = 0
  private var task: Task<Void, Never>?
  private var store: ConversationStore?
  private var lease: UUID?

  func load(notebook: NotebookModel, selectedIDs: Set<String>?) async {
    guard !ready else { return }
    let scope = selectedIDs.map { $0.sorted().joined(separator: "\n") } ?? "all-notes"
    store = notebook.conversations
    do {
      let session = try await notebook.conversations.beginSession(scope: scope)
      conversation = session.conversation
      lease = session.lease
      revision = 0
    } catch {
      self.error = String(
        localized: "The previous conversation could not be read. Its file is still on this device.")
      return
    }
    draft = conversation.draft
    ready = true
  }

  func persistDraft() {
    guard ready, !sending, let store else { return }
    conversation.draft = draft
    revision += 1
    let snapshot = conversation
    let version = revision
    let lease = lease
    Task {
      do { try await store.save(snapshot, revision: version, lease: lease) } catch {
        self.error = String(
          localized: "Your draft could not be saved. Keep this screen open and try again.")
      }
    }
  }

  func send(notebook: NotebookModel, context: NoteContext) {
    guard ready, !sending, !context.entries.isEmpty else { return }
    let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, question.count <= 4000 else { return }
    let config = notebook.configuration
    do {
      let origin = try config.origin
      _ = try config.endpoint
      let key = config.usesAPIKey ? try KeychainSecretStore.read(origin: origin) : ""
      sending = true
      error = nil
      if conversation.messages.last?.role != .user
        || conversation.messages.last?.content != question
      {
        conversation.messages.append(.init(role: .user, content: question))
      }
      conversation.draft = question
      revision += 1
      let initial = conversation
      let initialVersion = revision
      let lease = lease
      task = Task {
        defer { sending = false }
        do {
          try await notebook.conversations.save(initial, revision: initialVersion, lease: lease)
          let answer = try await AIClient().complete(
            configuration: config, apiKey: key, messages: initial.messages, context: context)
          try Task.checkCancellation()
          conversation.messages.append(.init(role: .assistant, content: answer))
          conversation.draft = ""
          draft = ""
          revision += 1
          try await notebook.conversations.save(conversation, revision: revision, lease: lease)
        } catch {
          if Task.isCancelled {
            self.error = String(localized: "Request cancelled. Your question has been kept.")
          } else if let error = error as? AIError {
            self.error = NSLocalizedString(error.localizedDescription, comment: "AI error")
          } else {
            self.error = String(
              localized:
                "Could not get a reply. Your question is saved on this device; check the connection and try again."
            )
          }
        }
      }
    } catch {
      if let keyError = error as? KeychainSecretStore.Failure {
        self.error = NSLocalizedString(keyError.localizedDescription, comment: "Keychain error")
      } else {
        self.error = String(localized: "Check your AI connection in Settings before sending.")
      }
    }
  }
  func cancel() { task?.cancel() }
}

struct NoteChatView: View {
  @EnvironmentObject private var notebook: NotebookModel
  @Environment(\.dismiss) private var dismiss
  let selectedIDs: Set<String>?
  @StateObject private var session = ChatSession()
  @State private var settingsOpen = false
  private var context: NoteContext {
    .build(entries: notebook.entries, question: session.draft, selectedIDs: selectedIDs)
  }
  private var configured: Bool { (try? notebook.configuration.endpoint) != nil }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        contextHeader
        Divider()
        messagesView
        composer
        if session.draft.count > 4000 {
          Text("Keep the question under 4,000 characters.").font(.caption).foregroundStyle(
            .secondary
          ).padding(.bottom, 8)
        }
      }
      .notebookSurface()
      .navigationTitle(selectedIDs == nil ? "Chat with notes" : "Chat about this note")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") {
            session.cancel()
            dismiss()
          }
        }
      }
    }
    .task { await session.load(notebook: notebook, selectedIDs: selectedIDs) }
    .onChange(of: session.draft) { _ in session.persistDraft() }
    .onDisappear { session.cancel() }
    .sheet(isPresented: $settingsOpen) {
      NavigationStack {
        SettingsView().navigationTitle("Settings").toolbar {
          ToolbarItem(placement: .confirmationAction) { Button("Done") { settingsOpen = false } }
        }
      }
    }
  }

  private var contextHeader: some View {
    VStack(alignment: .leading, spacing: 10) {
      if configured {
        Label(notebook.configuration.model, systemImage: "slider.horizontal.3").font(
          .caption.weight(.medium))
        Text("Only the excerpts below and this conversation will be sent when you tap Send.")
          .font(.caption).foregroundStyle(.secondary)
        DisclosureGroup("\(context.entries.count) notes included") {
          ScrollView {
            Text(context.text).font(.caption).textSelection(.enabled).frame(
              maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 220)
        }
        .font(.caption)
        .accessibilityIdentifier("chat-context")
      } else {
        Text("Connect your own AI to talk with your notes.").font(NotebookTheme.reading(22))
        Button("Set up AI in Settings") { settingsOpen = true }.frame(minHeight: 44)
          .accessibilityIdentifier("chat-setup-ai")
      }
    }
    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
  }

  private var messagesView: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 24) {
          if session.conversation.messages.isEmpty {
            Text("What would you like to revisit?").font(NotebookTheme.reading(24)).foregroundStyle(
              .secondary
            ).padding(.vertical, 36)
          }
          ForEach(session.conversation.messages) { message in
            VStack(alignment: .leading, spacing: 8) {
              Text(message.role == .user ? "You" : "Your AI").font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
              Text(message.content).font(NotebookTheme.reading(text: message.content)).lineSpacing(
                6
              ).textSelection(.enabled)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              message.role == .user ? NotebookTheme.card : .clear,
              in: RoundedRectangle(cornerRadius: 14)
            )
            .id(message.id)
          }
          if session.sending { ProgressView("Thinking…").accessibilityIdentifier("chat-thinking") }
          if let error = session.error {
            Text(error).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier(
              "chat-error")
          }
        }
        .padding(20)
      }
      .onChange(of: session.conversation.messages.count) { _ in
        if let id = session.conversation.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
      }
    }
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 12) {
      TextField("Ask about your notes…", text: $session.draft, axis: .vertical)
        .lineLimit(1...5).padding(12)
        .background(NotebookTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .disabled(!session.ready || session.sending)
        .accessibilityIdentifier("chat-question")
      if session.sending {
        Button {
          session.cancel()
        } label: {
          Image(systemName: "stop.fill").frame(width: 44, height: 44)
        }
        .accessibilityLabel("Cancel request")
        .accessibilityIdentifier("cancel-chat")
      } else {
        Button {
          session.send(notebook: notebook, context: context)
        } label: {
          Image(systemName: "arrow.up").frame(width: 44, height: 44)
        }
        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        .disabled(
          !configured || !session.ready || context.entries.isEmpty
            || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || session.draft.count > 4000
        )
        .accessibilityLabel("Send")
        .accessibilityIdentifier("send-chat")
      }
    }
    .padding(16)
  }
}

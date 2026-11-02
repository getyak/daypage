import DayPageCore
import SwiftUI
import SwiftStreamingMarkdown

struct NoteChatView: View {
  @EnvironmentObject private var notebook: NotebookModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let selectedIDs: Set<String>?
  @StateObject private var session = ChatSession()
  @State private var sheet: ChatSheet?
  @FocusState private var questionFocused: Bool
  private enum ChatSheet: String, Identifiable {
    case models, characters, history
    var id: String { rawValue }
  }
  private var context: NoteContext {
    let scope = session.conversation.scope
    let ids: Set<String>? = scope == "all-notes" ? nil : Set(scope.components(separatedBy: "\n"))
    return .build(entries: session.conversation.includesNotes == false ? [] : notebook.entries,
      question: session.draft, selectedIDs: ids)
  }
  private var configured: Bool {
    let config = notebook.configuration
    return (try? config.endpoint) != nil
      && (!AIProvider.matching(configuration: config).requiresAPIKey || config.usesAPIKey)
  }
  private var modelTitle: String {
    let config = notebook.configuration
    return config.model == AIModelCatalog.automaticModel
      ? NSLocalizedString(AIProvider.matching(configuration: config).name, comment: "AI provider")
      : config.model
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        characterHeader
        contextHeader
        Divider().overlay(NotebookTheme.line)
        ChatTranscript(session: session, hasNotes: !context.entries.isEmpty) {
          await session.recover(notebook: notebook, context: context)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) { composer }
      .notebookSurface()
      .navigationTitle("Conversation").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Close") { session.leave(); dismiss() } }
        ToolbarItemGroup(placement: .primaryAction) {
          Button { sheet = .history } label: { Image(systemName: "clock.arrow.circlepath").frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel("Conversation history").accessibilityIdentifier("chat-history")
            .disabled(session.switching)
          Button { Task { await session.newConversation() } } label: { Image(systemName: "square.and.pencil").frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel("New conversation").accessibilityIdentifier("chat-new")
            .disabled(session.sending || session.switching)
        }
      }
      .disabled(!session.ready && session.error == nil)
    }
    .task { await session.load(notebook: notebook, selectedIDs: selectedIDs) }
    .onChange(of: session.draft) { _ in session.persistDraft() }
    .onChange(of: scenePhase) { phase in if phase != .active { session.leave() } }
    .onDisappear { session.leave() }
    .sheet(item: $sheet) { destination in
      NavigationStack {
        Group {
          switch destination {
          case .models: AIModelsView()
          case .characters: ChatCharactersView(session: session)
          case .history: ChatHistoryView(session: session, store: notebook.conversations)
          }
        }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
      }
      .presentationDetents([.large])
    }
  }
  private var characterHeader: some View {
    HStack(spacing: 8) {
      Button { sheet = .characters } label: {
        HStack(spacing: 10) {
          Text(String(session.conversation.nextCharacter.name.prefix(1)))
            .font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(NotebookTheme.accent)
            .frame(width: 34, height: 34).background(NotebookTheme.accent.opacity(0.1), in: Circle())
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
              Text(session.conversation.nextCharacter.name).font(.subheadline.weight(.semibold)).lineLimit(1)
              Image(systemName: session.conversation.rotatesCharacters == true ? "arrow.triangle.2.circlepath" : "chevron.down")
                .font(.system(size: 11))
            }
            if !dynamicTypeSize.isAccessibilitySize {
              Text(session.conversation.nextCharacter.role).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
          }
        }.frame(minHeight: 44).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel("Characters").accessibilityIdentifier("chat-characters")
        .accessibilityValue("\(session.conversation.nextCharacter.name), \(session.conversation.nextCharacter.role)")
      Spacer(minLength: 0)
      Button { sheet = .models } label: {
        HStack(spacing: 5) {
          Image(systemName: "sparkles").font(.system(size: 14))
          if !dynamicTypeSize.isAccessibilitySize { Text(modelTitle).lineLimit(1).truncationMode(.middle) }
        }.font(.caption).padding(.horizontal, 10).frame(minHeight: 34)
          .background(NotebookTheme.card, in: Capsule())
          .frame(minHeight: 44).contentShape(Rectangle())
      }.buttonStyle(.plain).frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 44 : 145).accessibilityLabel("AI models")
        .accessibilityValue(modelTitle)
        .accessibilityIdentifier("chat-ai-settings").disabled(session.sending)
    }.padding(.horizontal, 16).padding(.top, 4)
      .disabled(!session.ready || session.sending || session.switching)
  }
  private var contextHeader: some View {
    VStack(alignment: .leading, spacing: 0) {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: 8) {
          Toggle("Include note excerpts", isOn: Binding(get: { session.conversation.includesNotes != false },
            set: { value in Task { await session.setIncludesNotes(value) } }))
            .disabled(session.sending).font(.subheadline)
          Text("Only these excerpts and this conversation are sent when you tap Send.")
            .font(.caption).foregroundStyle(.secondary)
          if !context.text.isEmpty {
            ScrollView { Text(context.text).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
              .frame(maxHeight: 160)
          }
        }.padding(.bottom, 10)
      } label: {
        Label("\(context.entries.count) notes included", systemImage: "text.book.closed")
          .font(.caption).foregroundStyle(.secondary).frame(minHeight: 44)
      }.accessibilityIdentifier("chat-context")
      if !configured {
        Button { sheet = .models } label: {
          HStack {
            Label("Connect your AI", systemImage: "sparkles").font(.subheadline)
            Spacer()
            Image(systemName: "arrow.up.right").font(.caption)
          }.frame(minHeight: 44)
        }.accessibilityIdentifier("chat-setup-ai")
      }
      if context.entries.isEmpty && session.conversation.includesNotes != false {
        Text("No note excerpts. You can still start a conversation.")
          .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
          .accessibilityIdentifier("chat-empty-context")
      }
    }.padding(.horizontal, 16)
  }
  private var composer: some View {
    VStack(spacing: 4) {
      HStack(alignment: .bottom, spacing: 8) {
        TextField("Ask about your notes…", text: $session.draft, axis: .vertical)
          .focused($questionFocused)
          .font(.body).lineLimit(1...6).padding(.leading, 14).padding(.vertical, 12)
          .disabled(!session.ready || session.sending || session.switching).accessibilityIdentifier("chat-question")
        Button {
          if session.sending { session.cancel() }
          else { questionFocused = false; session.send(notebook: notebook, context: context) }
        } label: {
          Image(systemName: session.sending ? "stop.fill" : "arrow.up")
            .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 44, height: 44).background(NotebookTheme.accent, in: Circle())
        }
        .disabled(session.switching || (!session.sending && (!configured || !session.ready || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.draft.count > 4000)))
        .accessibilityLabel(session.sending ? "Cancel request" : "Send")
        .accessibilityIdentifier(session.sending ? "cancel-chat" : "send-chat")
        .padding(4)
      }
      .background(NotebookTheme.card, in: RoundedRectangle(cornerRadius: 26))
      .overlay(RoundedRectangle(cornerRadius: 26).stroke(NotebookTheme.line, lineWidth: 0.7))
      if session.draft.count > 4000 {
        Text("Keep the question under 4,000 characters.").font(.caption).foregroundStyle(.secondary)
      }
    }.padding(.horizontal, 12).padding(.vertical, 8).background(NotebookTheme.paper)
  }
}

private struct ChatBottomPreference: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ChatTranscript: View {
  @ObservedObject var session: ChatSession
  let hasNotes: Bool
  let recover: () async -> Void
  @State private var followsLatest = true
  @State private var dragging = false
  @State private var bottom: CGFloat = 0
  var body: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            if session.conversation.messages.isEmpty && session.ready { greeting.id("chat-start") }
            ForEach(session.conversation.messages) { message in ChatMessageRow(message: message).id(message.id) }
            if let error = session.error {
              VStack(alignment: .leading, spacing: 4) {
                Text(error).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("chat-error")
                if session.recovery != .none {
                  Button(session.recovery == .load || session.canRetryReply ? "Try again" : "Retry saving") { Task { await recover() } }
                    .font(.subheadline).frame(minHeight: 44)
                    .disabled(session.sending).accessibilityIdentifier("chat-retry")
                }
              }
            }
            if !session.ready && session.error == nil { ProgressView().padding(.top, 24) }
            Color.clear.frame(height: 1).id("chat-bottom")
              .background(GeometryReader { anchor in
                Color.clear.preference(key: ChatBottomPreference.self, value: anchor.frame(in: .named("transcript")).maxY)
              })
          }.padding(.horizontal, 16).padding(.vertical, 14)
        }
        .coordinateSpace(name: "transcript").scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("chat-transcript")
        .simultaneousGesture(DragGesture().onChanged { _ in dragging = true; followsLatest = false }
          .onEnded { _ in dragging = false; followsLatest = bottom < geometry.size.height + 60 })
        .onPreferenceChange(ChatBottomPreference.self) { value in
          bottom = value
          if !dragging, value < geometry.size.height + 60 { followsLatest = true }
        }
        .onChange(of: session.update) { _ in
          if followsLatest, !session.conversation.messages.isEmpty { proxy.scrollTo("chat-bottom", anchor: .bottom) }
        }
        .onChange(of: session.conversation.id) { _ in
          followsLatest = true
          proxy.scrollTo(session.conversation.messages.isEmpty ? "chat-start" : "chat-bottom",
            anchor: session.conversation.messages.isEmpty ? .top : .bottom)
        }
        .overlay(alignment: .bottomTrailing) {
          if !followsLatest {
            Button { followsLatest = true; proxy.scrollTo("chat-bottom", anchor: .bottom) } label: {
              Image(systemName: "arrow.down").font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44).background(.regularMaterial, in: Circle())
            }.accessibilityLabel("Latest messages").padding(12)
          }
        }
      }
    }
  }
  private var greeting: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("A little room to think.").font(NotebookTheme.reading(25))
      Text("Start anywhere. Your conversations stay on this device.").font(.subheadline).foregroundStyle(.secondary)
      ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
        Button { session.draft = suggestion } label: {
          HStack(spacing: 8) {
            Text(suggestion).font(.subheadline).multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.left").font(.caption)
          }.padding(.horizontal, 12).frame(minHeight: 44)
            .background(NotebookTheme.card, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityIdentifier("chat-suggestion-\(index)")
      }
    }.padding(.vertical, 16)
  }
  private var suggestions: [String] {
    hasNotes ? [String(localized: "What has been on my mind lately?"), String(localized: "Find a thought I might want to revisit.")]
      : [String(localized: "Help me untangle an idea."), String(localized: "Let's think through today.")]
  }
}

private struct ChatMessageRow: View {
  let message: ChatMessage
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      if message.role == .user { Spacer(minLength: 30) }
      VStack(alignment: .leading, spacing: 7) {
        if message.role == .assistant {
          HStack(spacing: 6) {
            Image(systemName: "sparkle").foregroundStyle(NotebookTheme.accent)
            Text(message.character?.name ?? String(localized: "Your AI"))
            if message.delivery == .streaming { ProgressView().controlSize(.mini).accessibilityIdentifier("chat-thinking") }
          }.font(.caption.weight(.medium)).foregroundStyle(.secondary)
          if let reasoning = message.reasoning, !reasoning.isEmpty {
            DisclosureGroup {
              Text(reasoning).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
              Text("Thinking").frame(minHeight: 44, alignment: .leading)
            }.font(.caption).accessibilityIdentifier("chat-reasoning")
          }
          if !message.content.isEmpty {
            MarkdownView(text: message.content, config: .default.withBlockSpacing(value: 10)
              .withShouldAnimateText(value: message.delivery == .streaming && !reduceMotion))
              .frame(maxWidth: .infinity, alignment: .leading)
              .environment(\.openURL, OpenURLAction { url in
                ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
              })
          }
          if message.delivery == .interrupted {
            Label("Interrupted · saved", systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
          }
        } else {
          Text(message.content).font(.body).lineSpacing(3).textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(NotebookTheme.card, in: RoundedRectangle(cornerRadius: 18))
        }
      }
      if message.role == .assistant { Spacer(minLength: 4) }
    }.accessibilityIdentifier("chat-message-\(message.id)")
  }
}

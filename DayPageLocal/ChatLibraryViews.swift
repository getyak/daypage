import DayPageCore
import SwiftUI

struct ChatHistoryView: View {
  @ObservedObject var session: ChatSession
  let store: ConversationStore
  @Environment(\.dismiss) private var dismiss
  @State private var conversations: [Conversation] = []
  @State private var unreadable = 0
  @State private var loading = true
  @State private var error: String?
  @State private var search = ""
  var body: some View {
    List {
      if loading { ProgressView().frame(maxWidth: .infinity) }
      if let error {
        Section {
          Text(error).font(.footnote)
          Button("Try again") { Task { await load() } }.frame(minHeight: 44)
        }
      }
      if unreadable > 0 {
        Text("\(unreadable) conversations could not be read. Their original files are kept.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      ForEach(conversations.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { conversation in
        Button {
          Task {
            if await session.open(id: conversation.id) { dismiss() }
            else { error = session.error }
          }
        } label: {
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(conversation.title.isEmpty ? String(localized: "New conversation") : conversation.title)
                .font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(NotebookTheme.ink)
              Spacer(minLength: 8)
              if conversation.id == session.conversation.id { Image(systemName: "checkmark").foregroundStyle(NotebookTheme.accent) }
            }
            HStack(spacing: 6) {
              Text(conversation.characters?.first?.name ?? "DayPage")
              Text("·")
              Text("\(conversation.messages.count) messages")
              Spacer()
              if let date = conversation.updatedAt { Text(date, style: .date) }
            }.font(.caption).foregroundStyle(.secondary)
          }.padding(.vertical, 4).frame(minHeight: 44)
        }.disabled(session.sending).accessibilityIdentifier("chat-history-\(conversation.id)")
          .listRowBackground(NotebookTheme.card)
      }
      if !loading && conversations.isEmpty && error == nil {
        Text("Your conversations will appear here.").foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Conversation history").navigationBarTitleDisplayMode(.inline)
    .searchable(text: $search, prompt: "Search conversations")
    .scrollContentBackground(.hidden).notebookSurface()
    .task { await load() }
  }
  private func load() async {
    loading = true; error = nil
    do {
      if !session.sending { try await session.flush() }
      let history = try await store.history()
      conversations = history.conversations; unreadable = history.unreadableCount
    } catch { self.error = String(localized: "History could not be read. Your files are kept. Try again.") }
    loading = false
  }
}

struct ChatCharactersView: View {
  @ObservedObject var session: ChatSession
  @Environment(\.dismiss) private var dismiss
  @State private var editing: ChatCharacter?
  @State private var selected: Set<UUID> = []
  @State private var rotating = false
  private var library: [ChatCharacter] {
    let ids = Set(session.characters.map(\.id))
    return session.characters + (session.conversation.characters ?? []).filter { !ids.contains($0.id) }
  }
  var body: some View {
    List {
      if let error = session.libraryError {
        Section {
          Text(error).font(.footnote)
          Button("Try again") { Task { await session.reloadCharacters() } }
        }
      }
      Section {
        Toggle("Rotate characters", isOn: $rotating).accessibilityIdentifier("chat-rotate")
          .onChange(of: rotating) { value in
            if !value, selected.count > 1 { selected = [library.first(where: { selected.contains($0.id) })?.id ?? ChatCharacter.companion.id] }
          }
        Text("One reply per message. Selected characters take turns in the order below.")
          .font(.caption).foregroundStyle(.secondary)
      }.listRowBackground(NotebookTheme.card)
      Section("Characters") {
        ForEach(library) { character in
          HStack(spacing: 8) {
            Button {
              if rotating {
                if selected.contains(character.id) { selected.remove(character.id) }
                else { selected.insert(character.id) }
              } else { selected = [character.id] }
            } label: {
              HStack(spacing: 12) {
                Image(systemName: selected.contains(character.id) ? "checkmark.circle.fill" : "circle")
                  .foregroundStyle(NotebookTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                  Text(character.name).font(.subheadline.weight(.medium)).foregroundStyle(NotebookTheme.ink)
                  if !character.role.isEmpty { Text(character.role).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 0)
              }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("chat-character-\(character.id)")
            Button { editing = character } label: { Image(systemName: "pencil").frame(width: 44, height: 44) }
              .buttonStyle(.plain).accessibilityLabel("Edit character")
              .disabled(session.libraryError != nil)
          }.listRowBackground(NotebookTheme.card)
        }
        Button {
          editing = ChatCharacter(name: "")
        } label: { Label("New character", systemImage: "plus").frame(minHeight: 44) }
          .disabled(session.libraryError != nil || session.characters.count >= 100)
          .accessibilityIdentifier("chat-new-character")
      }
      Section {
        Button {
          Task {
            await session.selectCharacters(library.filter { selected.contains($0.id) }, rotating: rotating)
            if session.error == nil { dismiss() }
          }
        } label: { Text("Use selected characters").frame(maxWidth: .infinity, minHeight: 44) }
          .disabled(selected.isEmpty || session.sending).accessibilityIdentifier("chat-use-characters")
        if let error = session.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
      }
    }
    .navigationTitle("Characters").navigationBarTitleDisplayMode(.inline)
    .scrollContentBackground(.hidden).notebookSurface()
    .task {
      selected = Set((session.conversation.characters ?? [.companion]).map(\.id))
      rotating = session.conversation.rotatesCharacters == true
    }
    .sheet(item: $editing) { character in
      NavigationStack {
        ChatCharacterEditor(character: character) { updated in await session.saveCharacter(updated) }
      }
    }
  }
}

private struct ChatCharacterEditor: View {
  @State var character: ChatCharacter
  let save: (ChatCharacter) async -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var saving = false
  @State private var error = false
  var body: some View {
    Form {
      Section("Identity") {
        TextField("Name", text: $character.name).accessibilityIdentifier("character-name")
        TextField("Role", text: $character.role, axis: .vertical).lineLimit(1...3)
          .accessibilityIdentifier("character-role")
      }.listRowBackground(NotebookTheme.card)
      Section {
        TextEditor(text: $character.soul).frame(minHeight: 180).accessibilityIdentifier("character-soul")
      } header: { Text("Soul") } footer: {
        Text("Personality, values and speaking style. These instructions are sent with your messages.")
      }.listRowBackground(NotebookTheme.card)
      if !character.isValid {
        Text("Use a name up to 80 characters, role up to 240, and Soul up to 8,000.").font(.caption).foregroundStyle(.secondary)
      }
      if error { Text("The character could not be saved. Your edits are kept.").font(.footnote) }
      if !character.name.isEmpty {
        Button("Duplicate character") {
          character = ChatCharacter(name: character.name + String(localized: " copy"), role: character.role, soul: character.soul)
        }.disabled(saving).accessibilityIdentifier("character-duplicate")
      }
    }
    .navigationTitle("Edit character").navigationBarTitleDisplayMode(.inline)
    .scrollContentBackground(.hidden).notebookSurface().scrollDismissesKeyboard(.interactively)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          saving = true
          Task {
            if await save(character) { dismiss() } else { error = true }
            saving = false
          }
        }.disabled(!character.isValid || saving).accessibilityIdentifier("character-save")
      }
    }
    .interactiveDismissDisabled(saving)
  }
}

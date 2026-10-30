import DayPageCore
import SwiftUI

private enum ArchiveFilter: String, CaseIterable, Identifiable {
  case all, pinned, photos, voice, files
  var id: Self { self }
  var title: LocalizedStringKey {
    switch self {
    case .all: return "All notes"
    case .pinned: return "Pinned"
    case .photos: return "Photos"
    case .voice: return "Voice"
    case .files: return "Files"
    }
  }
}

struct ArchiveView: View {
  @EnvironmentObject private var notebook: NotebookModel
  @Binding var search: String
  @State private var filter: ArchiveFilter = .all
  @State private var selectedTag: String?
  @State private var selectedDay: String?
  @State private var showingCalendar = false
  @State private var showingTrash = false
  @State private var selecting = false
  @State private var selectedIDs: Set<String> = []
  @State private var chattingWithSelection = false
  @FocusState private var searchFocused: Bool

  private var entries: [NotebookEntry] {
    notebook.entries.filter { entry in
      let memo = entry.memo
      let searchable = memo.body + "\n" + entry.day + "\n"
        + memo.attachments.compactMap(\.transcript).joined(separator: "\n")
      let matchesText = search.isEmpty || searchable.localizedCaseInsensitiveContains(search)
      let matchesTag = selectedTag.map { NoteTags.values(in: memo.body).contains($0) } ?? true
      let matchesDate = selectedDay.map { entry.day == $0 } ?? true
      let matchesType: Bool
      switch filter {
      case .all: matchesType = true
      case .pinned: matchesType = memo.pinnedAt != nil
      case .photos: matchesType = memo.attachments.contains { $0.kind == "photo" }
      case .voice: matchesType = memo.attachments.contains { $0.kind == "audio" }
      case .files: matchesType = memo.attachments.contains { $0.kind == "file" }
      }
      return matchesText && matchesTag && matchesDate && matchesType
    }
  }
  private var days: [String] { Array(Set(entries.map(\.day))).sorted(by: >) }
  private var tags: [String] { Array(Set(notebook.entries.flatMap { NoteTags.values(in: $0.memo.body) })).sorted() }

  var body: some View {
    VStack(spacing: 0) {
      searchBar
      if selecting {
        HStack {
          Text("\(selectedIDs.count) selected").font(.caption).foregroundStyle(NotebookTheme.muted)
          Spacer()
          Button {
            chattingWithSelection = true
          } label: { Label("Chat with selection", systemImage: "sparkles").font(.subheadline) }
            .disabled(selectedIDs.isEmpty).accessibilityIdentifier("chat-selected-notes")
        }
        .padding(.horizontal, 20).frame(minHeight: 44)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          archiveTools
          if !tags.isEmpty { tagRow }
          if let selectedDay {
            Button {
              self.selectedDay = nil
            } label: {
              Label(NotebookDate.title(selectedDay), systemImage: "xmark.circle.fill")
                .font(.caption).padding(.vertical, 8)
            }
            .accessibilityLabel("Clear date filter")
          }
          if entries.isEmpty {
            NotebookEmptyState(icon: "magnifyingglass", title: "No matching notes",
                               detail: String(localized: "Try another word, date, or filter."))
          } else {
            ForEach(days, id: \.self) { day in
              VStack(alignment: .leading, spacing: 12) {
                HStack {
                  Text(NotebookDate.title(day)).font(NotebookTheme.mono(12))
                  Spacer()
                  Text(NotebookTheme.noteCount(entries.filter { $0.day == day }.count)).font(.caption2)
                }
                .foregroundStyle(NotebookTheme.muted)
                .padding(.top, 14).padding(.horizontal, 2)
                ForEach(entries.filter { $0.day == day }) { entry in
                  HStack(alignment: .top, spacing: 10) {
                    if selecting {
                      Button { toggleSelection(entry.id) } label: {
                        Image(systemName: selectedIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                          .font(.system(size: 22)).frame(width: 44, height: 44)
                      }
                      .accessibilityLabel("Select note")
                      .accessibilityIdentifier("select-note-" + entry.memo.id.uuidString)
                      .accessibilityAddTraits(selectedIDs.contains(entry.id) ? .isSelected : [])
                    }
                    LocalMemoCard(entry: entry).allowsHitTesting(!selecting)
                  }
                }
              }
            }
          }
          Button {
            showingTrash = true
          } label: {
            Label("Recently Deleted", systemImage: "trash")
              .font(.caption).frame(minHeight: 44)
          }
          .foregroundStyle(NotebookTheme.muted)
          .accessibilityIdentifier("recently-deleted")
          .padding(.top, 14)
        }
        .padding(.horizontal, 16).padding(.bottom, 24)
        .frame(maxWidth: 760).frame(maxWidth: .infinity)
      }
      .scrollDismissesKeyboard(.interactively)
      .refreshable { await notebook.refresh() }
      .accessibilityIdentifier("archive-list")
    }
    .notebookSurface()
    .sheet(isPresented: $showingCalendar) {
      ArchiveCalendarFilter(selectedDay: $selectedDay)
        .presentationDetents([.medium, .large])
    }
    .sheet(isPresented: $showingTrash) { RecentlyDeletedView() }
    .sheet(isPresented: $chattingWithSelection) { NoteChatView(selectedIDs: selectedIDs) }
    .onChange(of: notebook.entries.map(\.id)) { ids in selectedIDs.formIntersection(Set(ids)) }
  }

  private var searchBar: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass").foregroundStyle(NotebookTheme.muted)
      TextField("Search your notes", text: $search)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .focused($searchFocused).submitLabel(.search)
        .accessibilityIdentifier("archive-search")
      if !search.isEmpty {
        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
          .foregroundStyle(NotebookTheme.muted).accessibilityLabel("Clear search")
      }
      Button {
        selecting.toggle()
        if !selecting { selectedIDs = [] }
        searchFocused = false
      } label: {
        Text(selecting ? "Done" : "Select").font(.subheadline)
      }
      .frame(minHeight: 44).accessibilityIdentifier("select-notes")
    }
    .padding(.horizontal, 14).frame(minHeight: 44)
    .background(NotebookTheme.accentSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    .padding(.horizontal, 20).padding(.vertical, 12)
  }

  private func toggleSelection(_ id: String) {
    if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
  }

  private var archiveTools: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(ArchiveFilter.allCases) { item in
          Button {
            filter = item
          } label: {
            HStack(spacing: 5) {
              if item == .pinned { Image(systemName: "pin") }
              Text(item.title)
            }
            .font(.subheadline.weight(item == filter ? .medium : .regular))
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(item == filter ? NotebookTheme.accentSoft : .clear, in: Capsule())
            .foregroundStyle(item == filter ? NotebookTheme.readingAccent : NotebookTheme.muted)
          }
          .buttonStyle(.plain).accessibilityIdentifier("filter-" + item.rawValue)
          .accessibilityAddTraits(item == filter ? .isSelected : [])
        }
        Button { showingCalendar = true } label: {
          Image(systemName: "calendar").frame(width: 44, height: 44)
        }
        .accessibilityLabel("Filter by date").accessibilityIdentifier("archive-calendar")
      }
    }
  }

  private var tagRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        ForEach(tags, id: \.self) { tag in
          Button {
            selectedTag = selectedTag == tag ? nil : tag
          } label: {
            Text("#" + tag).font(.caption)
              .padding(.horizontal, 11).frame(minHeight: 36)
              .background(selectedTag == tag ? NotebookTheme.accentSoft : .clear, in: Capsule())
          }
          .buttonStyle(.plain).foregroundStyle(NotebookTheme.accent)
          .accessibilityIdentifier("tag-" + tag)
          .accessibilityAddTraits(selectedTag == tag ? .isSelected : [])
        }
      }
    }
  }
}

struct NotebookCalendar: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var selectedDay: String
  var onSelect: () -> Void
  @State private var selectedDate = Date()
  var body: some View {
    NavigationStack {
      VStack(spacing: 12) {
        DatePicker("Choose date", selection: $selectedDate, displayedComponents: .date)
          .datePickerStyle(.graphical)
          .accessibilityIdentifier("notebook-date-picker")
        Button {
          selectedDate = Date()
        } label: { Text("Today").frame(minHeight: 44) }
      }
      .padding(20).notebookSurface()
      .navigationTitle("Choose date").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            selectedDay = NotebookDate.day(selectedDate)
            onSelect()
            dismiss()
          }
        }
      }
    }
    .onAppear { selectedDate = NotebookDate.date(selectedDay) ?? Date() }
  }
}

private struct ArchiveCalendarFilter: View {
  @Binding var selectedDay: String?
  @State private var choice = NotebookDate.day(Date())
  var body: some View {
    NotebookCalendar(selectedDay: $choice) { selectedDay = choice }
      .onAppear { if let selectedDay { choice = selectedDay } }
  }
}

struct RecentlyDeletedView: View {
  @EnvironmentObject private var notebook: NotebookModel
  @Environment(\.dismiss) private var dismiss
  @State private var receipts: [NotebookTrashReceipt] = []
  @State private var restoring: UUID?
  @State private var loadFailed = false
  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          Text("Deleted notes stay here until you restore them. Their attachments are kept.")
            .font(.subheadline).foregroundStyle(NotebookTheme.muted).lineSpacing(4)
          if loadFailed {
            Button("Try again") { Task { await load() } }
          } else if receipts.isEmpty {
            NotebookEmptyState(icon: "trash", title: "No deleted notes",
                               detail: String(localized: "Notes you move to Trash will appear here."))
          }
          ForEach(receipts) { receipt in
            VStack(alignment: .leading, spacing: 14) {
              Text(receipt.entry.memo.body.isEmpty ? String(localized: "Attachment note") : receipt.entry.memo.body)
                .font(NotebookTheme.reading()).lineLimit(4)
              HStack {
                Text(receipt.entry.memo.created, style: .date).font(.caption).foregroundStyle(NotebookTheme.muted)
                Spacer()
                Button("Restore") {
                  restoring = receipt.id
                  Task {
                    if await notebook.restore(receipt) { await load() }
                    restoring = nil
                  }
                }
                .disabled(restoring != nil).frame(minHeight: 44)
                .accessibilityIdentifier("restore-note")
              }
            }
            .padding(18).background(NotebookTheme.card, in: RoundedRectangle(cornerRadius: 16))
          }
        }
        .padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
      }
      .notebookSurface().navigationTitle("Recently Deleted").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    .task { await load() }
  }
  private func load() async {
    do { receipts = try await notebook.store.trashReceipts(); loadFailed = false }
    catch { loadFailed = true; notebook.report(error) }
  }
}

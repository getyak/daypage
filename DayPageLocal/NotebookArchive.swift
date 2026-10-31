import DayPageCore
import SwiftUI

private extension NotebookEntryKind {
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
  var searching = false
  @State private var filter: NotebookEntryKind = .all
  @State private var selectedTag: String?
  @State private var selectedDay: String?
  @State private var showingCalendar = false
  @State private var showingTrash = false
  @State private var selecting = false
  @State private var selectedIDs: Set<String> = []
  @State private var chattingWithSelection = false
  @FocusState private var searchFocused: Bool
  private var filtered: Bool { filter != .all || selectedTag != nil || selectedDay != nil || !search.isEmpty }

  var body: some View {
    let result = notebook.catalog.search(text: search, kind: filter, tag: selectedTag, day: selectedDay)
    VStack(spacing: 0) {
      if searching { searchBar }
      if selecting { selectionBar }
      if searching, notebook.lastDeleted != nil {
        HStack {
          Text("Moved to Trash").font(.caption)
          Spacer()
          Button("Undo") { Task { await notebook.restoreLastDeleted() } }
            .frame(minHeight: 44).accessibilityIdentifier("search-undo-trash")
        }.padding(.horizontal, 20)
      }
      List {
        Group {
          if !searching { summary }
          archiveTools
          if !notebook.catalog.tags.isEmpty { tagRow }
          if filtered { activeFilters(count: result.count) }
          if notebook.isLoading {
            ProgressView("Loading notes…").frame(maxWidth: .infinity).padding(30)
          } else if let issue = notebook.loadIssue {
            NotebookEmptyState(icon: "exclamationmark.circle", title: "Couldn't read this notebook", detail: issue)
            Button("Try again") { Task { await notebook.refresh() } }
          } else if notebook.entries.isEmpty {
            NotebookEmptyState(icon: "books.vertical", title: "Your archive begins here",
              detail: String(localized: "Notes you write appear here, gathered by date. Return to Today to capture your first thought."))
          } else if result.count == 0 {
            NotebookEmptyState(icon: "magnifyingglass", title: "No matching notes",
              detail: String(localized: "Try another word, date, or filter."))
          }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
        .listRowSeparator(.hidden).listRowBackground(Color.clear)

        ForEach(result.sections) { section in
          Section {
            ForEach(section.entries) { entry in
              HStack(alignment: .top, spacing: 8) {
                if selecting {
                  Button { toggleSelection(entry.id) } label: {
                    Image(systemName: selectedIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                      .font(.system(size: 22)).frame(width: 44, height: 44)
                  }
                  .buttonStyle(.plain).accessibilityLabel("Select note")
                  .accessibilityIdentifier("select-note-" + entry.memo.id.uuidString)
                  .accessibilityAddTraits(selectedIDs.contains(entry.id) ? .isSelected : [])
                }
                LocalMemoCard(entry: entry, interactionEnabled: !selecting)
              }
              .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
              .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
          } header: {
            HStack {
              Text(dayTitle(section.day)).textCase(nil)
              Spacer()
              Text(NotebookTheme.noteCount(section.entries.count))
            }
            .font(NotebookTheme.mono(11)).foregroundStyle(NotebookTheme.muted)
            .padding(.vertical, 5)
          }
        }
        Button { showingTrash = true } label: {
          Label("Recently Deleted", systemImage: "trash").font(.subheadline)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(NotebookTheme.muted).accessibilityIdentifier("recently-deleted")
        .listRowSeparator(.hidden).listRowBackground(Color.clear)
      }
      .listStyle(.plain).scrollContentBackground(.hidden)
      .scrollDismissesKeyboard(.interactively)
      .refreshable { await notebook.refresh() }
      .accessibilityIdentifier(searching ? "search-list" : "archive-list")
    }
    .notebookSurface()
    .sheet(isPresented: $showingCalendar) {
      ArchiveCalendarFilter(selectedDay: $selectedDay).presentationDetents([.large])
    }
    .sheet(isPresented: $showingTrash) { RecentlyDeletedView() }
    .sheet(isPresented: $chattingWithSelection) { NoteChatView(selectedIDs: selectedIDs) }
    .onChange(of: notebook.entries.map(\.id)) { selectedIDs.formIntersection(Set($0)) }
    .task { if searching { searchFocused = true } }
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("A little perspective.").font(NotebookTheme.reading(28))
      Text("Revisit the moments you kept.").font(.subheadline).foregroundStyle(NotebookTheme.muted)
      HStack(spacing: 7) {
        if notebook.isLoading {
          Text("Loading notes…")
        } else {
          Text(NotebookTheme.noteCount(notebook.entries.count))
          Text("·")
          Text(NotebookTheme.dayCount(notebook.catalog.dayCounts.count))
        }
      }
      .font(.caption).foregroundStyle(NotebookTheme.muted)
      .accessibilityElement(children: .combine).accessibilityIdentifier("archive-summary")
    }.padding(.vertical, 16)
  }

  private var searchBar: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass").foregroundStyle(NotebookTheme.muted)
      TextField("Search your notes", text: $search)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .focused($searchFocused).submitLabel(.search).accessibilityIdentifier("archive-search")
        .onSubmit { searchFocused = false }
      if !search.isEmpty {
        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
          .foregroundStyle(NotebookTheme.muted).accessibilityLabel("Clear search")
      }
    }
    .padding(.leading, 14).frame(minHeight: 48)
    .background(NotebookTheme.accentSoft.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    .padding(.horizontal, 20).padding(.vertical, 12)
  }

  private var selectionBar: some View {
    HStack {
      Text("\(selectedIDs.count) selected").font(.caption).foregroundStyle(NotebookTheme.muted)
      Spacer()
      Button { chattingWithSelection = true } label: {
        Label("Chat with selection", systemImage: "sparkles").font(.subheadline)
      }
      .disabled(selectedIDs.isEmpty).accessibilityIdentifier("chat-selected-notes")
    }.padding(.horizontal, 20).frame(minHeight: 44)
  }

  private var archiveTools: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(searching ? LocalizedStringKey("Find a note") : LocalizedStringKey("Browse your notes")).font(.caption.weight(.medium))
          .foregroundStyle(NotebookTheme.muted)
        Spacer()
        Button(selecting ? "Done" : "Select") {
          selecting.toggle()
          if !selecting { selectedIDs = [] }
          searchFocused = false
        }.font(.subheadline).frame(minHeight: 44).accessibilityIdentifier("select-notes")
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 7) {
          ForEach(NotebookEntryKind.allCases) { item in
            Button { filter = item; searchFocused = false } label: {
              Text(item.title).font(.subheadline.weight(item == filter ? .medium : .regular))
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(item == filter ? NotebookTheme.accentSoft : .clear, in: Capsule())
                .foregroundStyle(item == filter ? NotebookTheme.readingAccent : NotebookTheme.muted)
            }
            .buttonStyle(.plain).accessibilityIdentifier("filter-" + item.rawValue)
            .accessibilityAddTraits(item == filter ? .isSelected : [])
          }
          Button { searchFocused = false; showingCalendar = true } label: {
            Label("Date", systemImage: "calendar").font(.subheadline)
              .padding(.horizontal, 12).frame(minHeight: 44)
          }
          .buttonStyle(.plain).accessibilityLabel("Filter by date").accessibilityIdentifier("archive-calendar")
        }
      }
    }
  }

  private var tagRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(notebook.catalog.tags, id: \.self) { tag in
          Button { selectedTag = selectedTag == tag ? nil : tag; searchFocused = false } label: {
            Text("#" + tag).font(.caption).padding(.horizontal, 11).frame(minHeight: 44)
              .background(selectedTag == tag ? NotebookTheme.accentSoft : .clear, in: Capsule())
          }
          .buttonStyle(.plain).foregroundStyle(NotebookTheme.accent)
          .accessibilityIdentifier("tag-" + tag)
          .accessibilityAddTraits(selectedTag == tag ? .isSelected : [])
        }
      }
    }
  }

  private func activeFilters(count: Int) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(NotebookTheme.noteCount(count)).font(.caption).foregroundStyle(NotebookTheme.muted)
          .accessibilityIdentifier("search-result-count")
        Spacer()
        Button("Clear filters") {
          search = ""; filter = .all; selectedTag = nil; selectedDay = nil
          searchFocused = false
        }.font(.caption).frame(minHeight: 44).accessibilityIdentifier("reset-archive-filters")
      }
      if let selectedDay { Text(dayTitle(selectedDay)).font(.caption).foregroundStyle(NotebookTheme.readingAccent) }
    }
  }

  private func toggleSelection(_ id: String) {
    if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
  }
  private func dayTitle(_ day: String) -> String {
    NotebookDate.date(day)?.formatted(.dateTime.year().month(.abbreviated).day().weekday(.abbreviated)) ?? day
  }
}

private struct ArchiveCalendarFilter: View {
  @Binding var selectedDay: String?
  @State private var choice: String
  init(selectedDay: Binding<String?>) {
    _selectedDay = selectedDay
    _choice = State(initialValue: selectedDay.wrappedValue ?? NotebookDate.day(Date()))
  }
  var body: some View {
    NotebookCalendar(selectedDay: $choice) { selectedDay = choice }
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
                .disabled(restoring != nil).frame(minHeight: 44).accessibilityIdentifier("restore-note")
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

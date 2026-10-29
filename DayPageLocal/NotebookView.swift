import DayPageCore
import SwiftUI

private enum NotebookDestination: String, CaseIterable, Identifiable {
  case archive, feedback, settings
  var id: Self { self }
  var title: LocalizedStringKey {
    switch self {
    case .archive: return "Archive"
    case .feedback: return "Feedback"
    case .settings: return "Settings"
    }
  }
  var icon: String {
    switch self {
    case .archive: return "books.vertical"
    case .feedback: return "paperplane"
    case .settings: return "gearshape"
    }
  }
}

struct NotebookView: View {
  @AppStorage("local.appearance") private var appearance = "system"
  @EnvironmentObject private var notebook: NotebookModel
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var destination: NotebookDestination = .archive
  @State private var sidebarOpen = false
  @State private var path: [String] = []

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        NavigationStack(path: $path) {
          Group {
            switch destination {
            case .archive: ArchiveView()
            case .feedback: FeedbackView()
            case .settings: SettingsView()
            }
          }
          .navigationTitle(destination.title)
          .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
              Button {
                showSidebar(true)
              } label: {
                Image(systemName: "line.3.horizontal")
              }
              .accessibilityLabel("Open sidebar")
              .accessibilityIdentifier("open-sidebar")
              .frame(minWidth: 44, minHeight: 44)
            }
          }
          .navigationDestination(for: String.self) { id in
            if let entry = notebook.entries.first(where: { $0.id == id }) {
              NoteDetailView(entry: entry)
            } else {
              Text("This note is no longer available. Reopen the archive to refresh it.").padding()
            }
          }
          .notebookSurface()
          .toolbarBackground(NotebookTheme.paper, for: .navigationBar)
          .toolbarBackground(.visible, for: .navigationBar)
        }
        .accessibilityHidden(sidebarOpen)

        if sidebarOpen {
          Color.black.opacity(0.28)
            .ignoresSafeArea()
            .onTapGesture { showSidebar(false) }
            .accessibilityHidden(true)
          sidebar
            .frame(
              width: min(geometry.size.width * (typeSize.isAccessibilitySize ? 0.94 : 0.86), 360)
            )
            .transition(.move(edge: .leading))
            .accessibilityAddTraits(.isModal)
        }
      }
    }
    .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    .alert(
      "Something needs attention",
      isPresented: Binding(get: { notebook.error != nil }, set: { if !$0 { notebook.error = nil } })
    ) {
      Button("OK", role: .cancel) { notebook.error = nil }
    } message: {
      Text(notebook.error ?? "")
    }
    .onChange(of: scenePhase) { phase in if phase == .active { Task { await notebook.refresh() } } }
    .onAppear {
      if NotebookModel.isQA, ProcessInfo.processInfo.arguments.contains("-qaOpenSidebar") {
        sidebarOpen = true
      }
    }
  }

  private var sidebar: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
              Text("daypage")
                .font(.custom("SourceSerif4-Regular", size: 36, relativeTo: .largeTitle))
                .foregroundStyle(NotebookTheme.spineInk)
              Text("A quiet local notebook")
                .font(.subheadline)
                .foregroundStyle(NotebookTheme.spineMuted)
            }
            Spacer(minLength: 8)
            Button {
              showSidebar(false)
            } label: {
              Image(systemName: "xmark").font(.body.weight(.medium)).frame(width: 44, height: 44)
            }
            .foregroundStyle(NotebookTheme.spineInk)
            .accessibilityLabel("Close sidebar")
            .accessibilityIdentifier("close-sidebar")
          }
          .padding(.bottom, 48)

          VStack(spacing: 10) {
            ForEach(NotebookDestination.allCases) { item in
              Button {
                destination = item
                path = []
                showSidebar(false)
              } label: {
                HStack(spacing: 16) {
                  Image(systemName: item.icon)
                    .font(.system(size: 21, weight: .regular))
                    .frame(width: 28)
                    .foregroundStyle(NotebookTheme.gold)
                  Text(item.title).font(.body.weight(destination == item ? .semibold : .regular))
                  Spacer(minLength: 0)
                }
                .foregroundStyle(NotebookTheme.spineInk)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(minHeight: 58)
                .background(
                  destination == item ? NotebookTheme.spineSelection : .clear,
                  in: RoundedRectangle(cornerRadius: 14)
                )
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("sidebar-" + item.rawValue)
              .accessibilityAddTraits(destination == item ? .isSelected : [])
            }
          }

          Spacer(minLength: 48)

          VStack(alignment: .leading, spacing: 24) {
            Text("Your notes stay here.\nAI joins only when you ask.")
              .font(NotebookTheme.reading(16))
              .foregroundStyle(NotebookTheme.spineMuted)
              .fixedSize(horizontal: false, vertical: true)
            Label("LOCAL NOTEBOOK", systemImage: "internaldrive")
              .font(.caption2.monospaced().weight(.medium))
              .tracking(1.2)
              .foregroundStyle(NotebookTheme.spineMuted)
          }
          .padding(.top, 28)
        }
        .frame(minHeight: max(0, geometry.size.height - 52), alignment: .topLeading)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 28)
      }
      .scrollIndicators(.hidden)
      .background {
        LinearGradient(
          colors: [NotebookTheme.spineTop, NotebookTheme.spine], startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        .ignoresSafeArea(edges: .bottom)
      }
      .overlay(alignment: .trailing) {
        Rectangle().fill(NotebookTheme.spineInk.opacity(0.08)).frame(width: 1).ignoresSafeArea()
      }
      .accessibilityIdentifier("notebook-sidebar")
      .accessibilityAction(.escape) { showSidebar(false) }
    }
  }

  private func showSidebar(_ open: Bool) {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { sidebarOpen = open }
  }
}

struct ArchiveView: View {
  @EnvironmentObject private var notebook: NotebookModel
  @State private var search = ""
  @State private var composing = false
  @State private var chatting = false
  private var entries: [NotebookEntry] {
    guard !search.isEmpty else { return notebook.entries }
    return notebook.entries.filter {
      $0.memo.body.localizedStandardContains(search) || $0.day.contains(search)
    }
  }
  private var days: [String] { Array(Set(entries.map(\.day))).sorted(by: >) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        VStack(alignment: .leading, spacing: 12) {
          Text("A place for passing thoughts.")
            .font(NotebookTheme.reading(24)).foregroundStyle(.primary)
          HStack(spacing: 8) {
            Label("On this device", systemImage: "internaldrive")
            Text("·")
            Text("\(notebook.entries.count) notes")
          }
          .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        HStack(spacing: 12) {
          Button {
            composing = true
          } label: {
            Label("Write a note", systemImage: "square.and.pencil").frame(
              maxWidth: .infinity, minHeight: 44)
          }
          .buttonStyle(.borderedProminent)
          .disabled(notebook.isLoading)
          .accessibilityIdentifier("new-note")
          Button {
            chatting = true
          } label: {
            Image(systemName: "bubble.left.and.bubble.right").frame(width: 44, height: 44)
          }
          .buttonStyle(.bordered)
          .disabled(notebook.isLoading)
          .accessibilityLabel("Chat with notes")
          .accessibilityIdentifier("chat-with-notes")
        }
        if notebook.isLoading {
          ProgressView().frame(maxWidth: .infinity).padding(50)
        } else if let issue = notebook.loadIssue {
          Text(issue).foregroundStyle(.secondary).padding(.vertical)
          Button("Try again") { Task { await notebook.refresh() } }
        } else if entries.isEmpty {
          VStack(alignment: .leading, spacing: 14) {
            Image(systemName: search.isEmpty ? "book.closed" : "magnifyingglass").font(
              .system(size: 36, weight: .ultraLight))
            Text(search.isEmpty ? "Start with one small thing." : "No matching notes")
              .font(NotebookTheme.reading(24))
            Text(
              search.isEmpty
                ? "No account. No setup. Just a thought worth keeping.\nHave an older Vault? Import a copy in Settings."
                : "Try a different word or date."
            )
            .font(.subheadline).foregroundStyle(.secondary).lineSpacing(5)
          }
          .padding(.vertical, 50)
          .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(days, id: \.self) { day in
              VStack(alignment: .leading, spacing: 12) {
                Text(day).font(.caption.monospaced()).foregroundStyle(.secondary)
                ForEach(entries.filter { $0.day == day }) { entry in
                  NavigationLink(value: entry.id) { MemoCard(entry: entry) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("note-" + entry.memo.id.uuidString)
                }
              }
            }
          }
        }
      }
      .padding(.horizontal, 24)
      .padding(.bottom, 36)
      .frame(maxWidth: 720)
      .frame(maxWidth: .infinity)
    }
    .searchable(
      text: $search, placement: .navigationBarDrawer(displayMode: .automatic),
      prompt: "Search your notes"
    )
    .refreshable { await notebook.refresh() }
    .sheet(isPresented: $composing) { NoteEditor() }
    .sheet(isPresented: $chatting) { NoteChatView(selectedIDs: nil) }
    .notebookSurface()
  }
}

private struct MemoCard: View {
  let entry: NotebookEntry
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(entry.memo.body.isEmpty ? String(localized: "Attachment note") : entry.memo.body)
        .font(NotebookTheme.reading(text: entry.memo.body)).lineSpacing(6).foregroundStyle(.primary)
        .lineLimit(6).frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 8) {
        Text(entry.memo.created, style: .time)
        if !entry.memo.attachments.isEmpty {
          Label("\(entry.memo.attachments.count)", systemImage: "paperclip")
        }
        Spacer()
        Image(systemName: "arrow.up.right").accessibilityHidden(true)
      }
      .font(.caption).foregroundStyle(.secondary)
    }
    .padding(20)
    .background(NotebookTheme.card, in: RoundedRectangle(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.04), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
  }
}

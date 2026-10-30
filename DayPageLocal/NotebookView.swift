import DayPageCore
import SwiftUI

private enum NotebookDestination: String {
  case today, archive, feedback, settings
  var title: LocalizedStringKey {
    switch self {
    case .today: return "Today"
    case .archive: return "Archive"
    case .feedback: return "Feedback"
    case .settings: return "Settings"
    }
  }
}

struct NotebookView: View {
  @AppStorage("local.appearance") private var appearance = "system"
  @EnvironmentObject private var notebook: NotebookModel
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var destination: NotebookDestination = .today
  @State private var sidebarOpen = false
  @State private var path: [String] = []
  @State private var selectedDay = NotebookDate.day(Date())
  @State private var showingCalendar = false
  @State private var search = ""

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        NavigationStack(path: $path) {
          VStack(spacing: 0) {
            header
            Rectangle().fill(NotebookTheme.line).frame(height: 0.5)
            Group {
              switch destination {
              case .today:
                NotebookTimeline(day: selectedDay, showAll: { destination = .archive })
              case .archive:
                ArchiveView(search: $search)
              case .feedback:
                FeedbackView()
              case .settings:
                SettingsView()
              }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          .toolbar(.hidden, for: .navigationBar)
          .notebookSurface()
          .safeAreaInset(edge: .bottom, spacing: 0) {
            if destination == .today || destination == .archive {
              CaptureDock()
            }
          }
          .navigationDestination(for: String.self) { id in
            if let entry = notebook.entries.first(where: { $0.id == id }) {
              NoteDetailView(entry: entry)
                .toolbar(.visible, for: .navigationBar)
            } else {
              Text("This note is no longer available. Reopen the archive to refresh it.")
                .padding().toolbar(.visible, for: .navigationBar)
            }
          }
        }
        .accessibilityHidden(sidebarOpen)
        .overlay(alignment: .leading) {
          if path.isEmpty && !sidebarOpen {
            Color.clear.frame(width: 14).contentShape(Rectangle())
              .gesture(DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.width > 65 && abs(value.translation.width) > abs(value.translation.height) * 1.5 {
                  showSidebar(true)
                }
              })
              .accessibilityHidden(true)
          }
        }

        if sidebarOpen {
          Color.black.opacity(0.22).ignoresSafeArea()
            .onTapGesture { showSidebar(false) }
            .accessibilityHidden(true)
          sidebar
            .frame(width: min(geometry.size.width * (typeSize.isAccessibilitySize ? 0.94 : 0.84), 350))
            .transition(.move(edge: .leading))
            .accessibilityAddTraits(.isModal)
            .gesture(DragGesture(minimumDistance: 24).onEnded { value in
              if value.translation.width < -65 && abs(value.translation.width) > abs(value.translation.height) * 1.5 {
                showSidebar(false)
              }
            })
        }
      }
    }
    .tint(NotebookTheme.accent)
    .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    .alert("Something needs attention",
           isPresented: Binding(get: { notebook.error != nil }, set: { if !$0 { notebook.error = nil } })) {
      Button("OK", role: .cancel) { notebook.error = nil }
    } message: { Text(notebook.error ?? "") }
    .sheet(isPresented: $showingCalendar) {
      NotebookCalendar(selectedDay: $selectedDay) { destination = .today }
        .presentationDetents([.medium, .large])
    }
    .onChange(of: scenePhase) { phase in
      if phase == .active { Task { await notebook.refresh() } }
      if phase != .active { notebook.saveDraft() }
    }
    .onAppear {
      if NotebookModel.isQA, ProcessInfo.processInfo.arguments.contains("-qaOpenSidebar") {
        sidebarOpen = true
      }
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      NotebookCircleButton(icon: "line.3.horizontal", label: "Open sidebar") { showSidebar(true) }
        .accessibilityIdentifier("open-sidebar")
      Spacer(minLength: 4)
      if destination == .today {
        Button { showingCalendar = true } label: {
          HStack(spacing: 6) {
            Text(NotebookDate.title(selectedDay)).font(NotebookTheme.reading(17))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
          }
          .foregroundStyle(NotebookTheme.muted)
          .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose date")
        .accessibilityIdentifier("choose-date")
      } else {
        Text(destination.title).font(NotebookTheme.reading(19))
      }
      Spacer(minLength: 4)
      if destination == .today || destination == .archive {
        NotebookCircleButton(icon: "magnifyingglass", label: "Search your notes") {
          destination = .archive
          search = ""
        }
        .accessibilityIdentifier("search-notes")
      } else {
        NotebookCircleButton(icon: "square.and.pencil", label: "Today") { destination = .today }
          .accessibilityIdentifier("return-today")
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .frame(maxWidth: 820)
    .frame(maxWidth: .infinity)
    .background(NotebookTheme.paper)
  }

  private var sidebar: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          NotebookCircleButton(icon: "xmark", label: "Close sidebar") { showSidebar(false) }
            .accessibilityIdentifier("close-sidebar")
            .padding(.bottom, 28)
          Button {
            destination = .today
            selectedDay = NotebookDate.day(Date())
            path = []
            showSidebar(false)
          } label: {
            HStack(spacing: 14) {
              Image(systemName: "book.closed").font(.system(size: 21))
                .frame(width: 44, height: 44)
                .background(NotebookTheme.card.opacity(0.7), in: Circle())
              VStack(alignment: .leading, spacing: 4) {
                Text("DayPage").font(NotebookTheme.reading(24))
                Text("On this device").font(.caption).foregroundStyle(NotebookTheme.muted)
              }
              Spacer()
              Image(systemName: "chevron.right").font(.caption)
            }
            .foregroundStyle(NotebookTheme.ink)
            .padding(.vertical, 8)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("notebook-home")
          .padding(.bottom, 34)

          sidebarRow(.archive, icon: "books.vertical")
          HStack(spacing: 8) {
            Text(NotebookTheme.noteCount(notebook.entries.count))
            Text("·")
            Text(NotebookTheme.dayCount(Set(notebook.entries.map(\.day)).count))
          }
          .font(.caption)
          .foregroundStyle(NotebookTheme.muted)
          .padding(.leading, 56)
          .padding(.top, 12)

          Spacer(minLength: 48)
          Divider().overlay(NotebookTheme.line).padding(.bottom, 16)
          sidebarRow(.feedback, icon: "paperplane")
          sidebarRow(.settings, icon: "gearshape")
          Text("Your notes stay here.\nAI joins only when you ask.")
            .font(.caption).foregroundStyle(NotebookTheme.muted)
            .lineSpacing(4).padding(.horizontal, 16).padding(.top, 24)
        }
        .frame(minHeight: max(0, geometry.size.height - 60), alignment: .topLeading)
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 32)
      }
      .scrollIndicators(.hidden)
      .background(NotebookTheme.spine.ignoresSafeArea())
      .overlay(alignment: .trailing) {
        Rectangle().fill(NotebookTheme.line).frame(width: 0.5).ignoresSafeArea()
      }
      .accessibilityIdentifier("notebook-sidebar")
      .accessibilityAction(.escape) { showSidebar(false) }
    }
  }

  private func sidebarRow(_ item: NotebookDestination, icon: String) -> some View {
    Button {
      destination = item
      path = []
      showSidebar(false)
    } label: {
      HStack(spacing: 16) {
        Image(systemName: icon).font(.system(size: 21)).frame(width: 24)
        Text(item.title).font(.body.weight(destination == item ? .medium : .regular))
        Spacer()
      }
      .foregroundStyle(destination == item ? NotebookTheme.readingAccent : NotebookTheme.secondary)
      .padding(.horizontal, 16).frame(minHeight: 58)
      .background(destination == item ? NotebookTheme.spineSelection : .clear,
                  in: RoundedRectangle(cornerRadius: 14))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("sidebar-" + item.rawValue)
    .accessibilityAddTraits(destination == item ? .isSelected : [])
  }

  private func showSidebar(_ open: Bool) {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { sidebarOpen = open }
  }
}

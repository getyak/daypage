import DayPageCore
import Combine
import SwiftUI

enum NotebookDestination: String {
  case today, archive, feedback, settings
  var title: LocalizedStringKey {
    switch self {
    case .today: return "Diary"
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
  @State private var observedToday = NotebookDate.day(Date())
  @State private var showingCalendar = false
  @State private var search = ""
  @State private var showingSearch = false
  @State private var searchPath: [String] = []
  @State private var jumpRevision = 0
  @State private var lastRediscoveredID: String?
  @AccessibilityFocusState private var sidebarButtonFocused: Bool

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
                NotebookTimeline(day: selectedDay, jumpRevision: jumpRevision,
                                 onToday: { jump(to: NotebookDate.day(Date())) },
                                 onOpenNote: { path.append($0) })
              case .archive:
                ArchiveView(search: .constant(""), onOpenNote: { path.append($0) })
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
        .accessibilityHidden(sidebarOpen || showingSearch)
        .allowsHitTesting(!sidebarOpen)
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
            .transition(.opacity)
          NotebookSidebar(destination: destination, selectedDay: selectedDay,
            onHome: { jump(to: NotebookDate.day(Date())); showSidebar(false) },
            onNavigate: { destination = $0; path = []; showSidebar(false) },
            onMonth: { jump(to: $0); showSidebar(false); selectionFeedback() },
            onRediscover: rediscover,
            onClose: { showSidebar(false) })
            .frame(width: min(geometry.size.width * (typeSize.isAccessibilitySize ? 0.94 : 0.84), 350))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(color: .black.opacity(0.12), radius: 24, x: 8)
            .padding(.vertical, 4)
            .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
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
      NotebookCalendar(selectedDay: $selectedDay) {
        // An explicit date choice has fresh intent, including the brief window
        // after midnight before the periodic Today refresh has fired.
        observedToday = NotebookDate.day(Date())
        destination = .today
        jumpRevision += 1
      }
        .presentationDetents([.large])
    }
    .sheet(isPresented: $showingSearch) {
      NavigationStack(path: $searchPath) {
        ArchiveView(search: $search, searching: true, onOpenNote: { searchPath.append($0) })
          .navigationTitle("Search").navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Close") { showingSearch = false }
                .accessibilityIdentifier("close-search")
            }
          }
          .navigationDestination(for: String.self) { id in
            if let entry = notebook.entries.first(where: { $0.id == id }) {
              NoteDetailView(entry: entry)
            } else {
              NotebookEmptyState(icon: "doc", title: "Note unavailable",
                detail: String(localized: "Close search and refresh your notebook."))
            }
          }
      }
      .presentationDetents([.large])
    }
    .onChange(of: scenePhase) { phase in
      if phase == .active {
        refreshTodaySelection()
        Task { await notebook.refresh() }
      }
      if phase != .active { notebook.saveDraft() }
    }
    .onChange(of: notebook.entries.first?.id) { _ in refreshTodaySelection() }
    .onChange(of: notebook.lastCapturedNoteID) { id in
      guard id != nil else { return }
      jump(to: NotebookDate.day(Date()))
    }
    .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
      refreshTodaySelection()
    }
    .onAppear {
      #if DEBUG
      if NotebookModel.isQA {
        let previous = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        if ProcessInfo.processInfo.arguments.contains("-qaForegroundPreviousDay") {
          selectedDay = NotebookDate.day(previous)
          observedToday = selectedDay
        } else if ProcessInfo.processInfo.arguments.contains("-qaBrowsePreviousDay") {
          selectedDay = NotebookDate.day(previous)
        }
      }
      #endif
      if NotebookModel.isQA, ProcessInfo.processInfo.arguments.contains("-qaOpenSidebar") {
        sidebarOpen = true
      }
    }
  }

  private var header: some View {
    ZStack {
      Group {
        if destination == .today {
          Button { showingCalendar = true } label: {
            HStack(spacing: 6) {
              Text("Diary").font(NotebookTheme.reading(19))
              Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(NotebookTheme.muted).frame(minHeight: 44)
          }
          .buttonStyle(.plain).accessibilityLabel("Choose date")
          .accessibilityIdentifier("choose-date").accessibilityValue(selectedDay)
        } else {
          Text(destination.title).font(NotebookTheme.reading(19))
            .lineLimit(1).minimumScaleFactor(0.8)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, destination == .today ? 56 : 100)

      HStack(spacing: 12) {
        NotebookCircleButton(icon: "line.3.horizontal", label: "Open sidebar") { showSidebar(true) }
          .accessibilityIdentifier("open-sidebar")
          .accessibilityFocused($sidebarButtonFocused)
        if destination != .today {
          NotebookCircleButton(icon: "chevron.left", label: "Today") {
            jump(to: NotebookDate.day(Date()))
          }
          .accessibilityIdentifier("return-today")
        }
        Spacer(minLength: 4)
        if destination == .today || destination == .archive {
          NotebookCircleButton(icon: "magnifyingglass", label: "Search your notes") {
            search = ""
            searchPath = []
            showingSearch = true
          }
          .accessibilityIdentifier("search-notes")
        } else {
          Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .frame(maxWidth: 820)
    .frame(maxWidth: .infinity)
    .background(NotebookTheme.paper)
  }

  private func showSidebar(_ open: Bool) {
    withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.36, dampingFraction: 0.88)) {
      sidebarOpen = open
    }
    if !open { sidebarButtonFocused = true }
  }

  private func jump(to day: String) {
    selectedDay = day
    observedToday = NotebookDate.day(Date())
    destination = .today
    path = []
    jumpRevision += 1
  }

  private func rediscover() {
    let candidates = notebook.entries.filter { $0.day < NotebookDate.day(Date()) }
    let fresh = candidates.filter { $0.id != lastRediscoveredID }
    guard let entry = (fresh.isEmpty ? candidates : fresh).randomElement() else { return }
    lastRediscoveredID = entry.id
    path = [entry.id]
    showSidebar(false)
    selectionFeedback()
  }

  private func selectionFeedback() {
    UISelectionFeedbackGenerator().selectionChanged()
  }

  private func refreshTodaySelection() {
    let today = NotebookDate.day(Date())
    if selectedDay == observedToday { selectedDay = today }
    observedToday = today
  }
}

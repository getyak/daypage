import SwiftUI

struct AppInformationView: View {
  enum Page: Equatable { case privacy, about }
  let page: Page
  @Environment(\.locale) private var locale
  @State private var information = AppInformation.bundled()
  @State private var isOnline = false
  @State private var failed = false
  @State private var fetchTask: Task<Void, Never>?
  @State private var requestID: UUID?

  private var language: AppInformation.Language? {
    information.languages[locale.identifier.hasPrefix("zh") ? "zh-Hans" : "en"]
  }

  var body: some View {
    List {
      if page == .about {
        Section {
          Text("DayPage · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
            .accessibilityIdentifier("app-information-installed-version")
        }
      }
      if let language {
        content(page == .privacy ? language.privacy : language.about)
        if page == .about { content(language.support) }
      }
      Section {
        Text(isOnline ? "Latest information from DayPage" : "Information included with this app")
          .font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("app-information-source")
        Text("Updated: \(information.revisionDate)").font(.caption).foregroundStyle(.secondary)
        if failed {
          Text("Could not check for updates. The included information is still available.")
            .font(.callout).foregroundStyle(.secondary)
            .accessibilityIdentifier("app-information-failure")
        }
        Button(action: checkLatest) {
          HStack {
            Text("Check latest information")
            if fetchTask != nil { Spacer(); ProgressView() }
          }.frame(minHeight: 44)
        }
        .disabled(fetchTask != nil)
        .accessibilityIdentifier("app-information-check-latest")
      }
    }
    .textSelection(.enabled)
    .navigationTitle(page == .privacy ? "Privacy policy" : "About & support")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("app-information-page")
    .onDisappear {
      requestID = nil
      fetchTask?.cancel()
      fetchTask = nil
    }
  }

  @ViewBuilder private func content(_ sections: [AppInformation.Section]) -> some View {
    ForEach(sections.indices, id: \.self) { index in
      Section {
        ForEach(sections[index].paragraphs.indices, id: \.self) { paragraph in
          // Verbatim prevents Markdown/link interpretation of remote text.
          Text(verbatim: sections[index].paragraphs[paragraph])
            .fixedSize(horizontal: false, vertical: true)
        }
      } header: { Text(verbatim: sections[index].title) }
    }
  }

  @MainActor private func checkLatest() {
    guard fetchTask == nil else { return }
    let id = UUID()
    requestID = id
    failed = false
    fetchTask = Task { @MainActor in
      defer { if requestID == id { fetchTask = nil } }
      do {
        let latest = try await AppInformationService().fetch()
        guard !Task.isCancelled, requestID == id else { return }
        information = latest
        isOnline = true
      } catch {
        guard !Task.isCancelled, requestID == id else { return }
        information = AppInformation.bundled()
        isOnline = false
        failed = true
      }
    }
  }
}

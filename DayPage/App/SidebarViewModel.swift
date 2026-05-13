import SwiftUI

// MARK: - RecentDay

/// One row in the sidebar "Recent" section: a date string (`YYYY-MM-DD`) and
/// the count of memos recorded that day. Memo count drives the trailing badge
/// so the user can spot heavy-input days at a glance.
struct RecentDay: Identifiable, Equatable {
    let dateString: String  // YYYY-MM-DD
    let memoCount: Int

    var id: String { dateString }
}

// MARK: - SidebarViewModel

/// Derives display-ready account info from the current auth session and
/// surfaces the last few days that contain memos, so the sidebar can act as a
/// fast jump list ("commit history") into Archive.
@MainActor
final class SidebarViewModel: ObservableObject {

    @Published var isLoggedIn: Bool = false
    @Published var accountEmail: String = ""
    @Published var accountInitial: String = "?"

    /// Most recent days (descending) with at least one memo, capped to 7.
    @Published var recentDays: [RecentDay] = []

    private var authStateTask: Task<Void, Never>?

    func bind(authService: AuthService) {
        // Reflect current state immediately.
        updateFrom(authService: authService)

        // Stream subsequent changes via authStateChanges so the sidebar
        // stays in sync without polling or Combine.
        authStateTask?.cancel()
        authStateTask = Task { [weak self, weak authService] in
            guard let authService else { return }
            for await (_, session) in authService.supabase.auth.authStateChanges {
                if Task.isCancelled { break }
                let email = session?.user.email ?? ""
                await MainActor.run {
                    self?.isLoggedIn = session != nil
                    self?.accountEmail = email
                    self?.accountInitial = email.first.map { String($0).uppercased() } ?? "?"
                }
            }
        }
    }

    /// Re-scan `vault/raw/*.md` and publish the most recent 7 days off the
    /// main actor. Safe to call repeatedly (e.g. whenever the sidebar opens).
    func refreshRecentDays() {
        Task { [weak self] in
            let days = await Self.scanRecentDays(limit: 7)
            await MainActor.run { self?.recentDays = days }
        }
    }

    private func updateFrom(authService: AuthService) {
        let email = authService.session?.user.email ?? ""
        isLoggedIn = authService.session != nil
        accountEmail = email
        accountInitial = email.first.map { String($0).uppercased() } ?? "?"
    }

    deinit {
        authStateTask?.cancel()
    }

    // MARK: - Vault Scan

    /// Reads `vault/raw/YYYY-MM-DD.md`, counts memos per day (memos are
    /// separated by `\n\n---\n\n`), and returns the most recent `limit` days
    /// in descending order. Missing/unreadable files are skipped silently.
    nonisolated private static func scanRecentDays(limit: Int) async -> [RecentDay] {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let rawDir = VaultInitializer.vaultURL.appendingPathComponent("raw")
            guard let entries = try? fm.contentsOfDirectory(atPath: rawDir.path) else {
                return []
            }

            // Keep only YYYY-MM-DD.md filenames; sort descending.
            let dateStrings: [String] = entries.compactMap { name in
                guard name.hasSuffix(".md") else { return nil }
                let base = String(name.dropLast(3))
                guard base.count == 10,
                      base[base.index(base.startIndex, offsetBy: 4)] == "-",
                      base[base.index(base.startIndex, offsetBy: 7)] == "-" else { return nil }
                let digits = base.replacingOccurrences(of: "-", with: "")
                guard digits.count == 8, digits.allSatisfy({ $0.isNumber }) else { return nil }
                return base
            }
            .sorted(by: >)

            var out: [RecentDay] = []
            for dateStr in dateStrings.prefix(limit) {
                let url = rawDir.appendingPathComponent("\(dateStr).md")
                let count = countMemos(at: url, fileManager: fm)
                if count > 0 {
                    out.append(RecentDay(dateString: dateStr, memoCount: count))
                }
            }
            return out
        }.value
    }

    /// Count memos in a single raw daily file. Memos are separated by the
    /// canonical `<!-- daypage-memo-separator -->` delimiter (see
    /// RawStorage.swift). Empty file or read failure → 0.
    nonisolated private static func countMemos(at url: URL, fileManager: FileManager) -> Int {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return 0 }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        // Try the canonical separator first, fall back to the legacy `---` form.
        let modern = trimmed.components(separatedBy: RawStorage.memoSeparator)
        if modern.count > 1 { return modern.count }
        return trimmed.components(separatedBy: RawStorage.legacyMemoSeparator).count
    }
}

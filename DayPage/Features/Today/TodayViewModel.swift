import Foundation
import SwiftUI
import UIKit

// MARK: - TodayViewModel

/// Manages state for TodayView: loading today's memos, tracking compiled state.
@MainActor
final class TodayViewModel: ObservableObject {

    // MARK: Published State

    /// Today's memos in reverse-chronological order (newest first).
    @Published var memos: [Memo] = []

    /// Whether the Daily Page for today has been compiled.
    @Published var isDailyPageCompiled: Bool = false

    /// A brief excerpt from the compiled Daily Page (if compiled).
    @Published var dailyPageSummary: String? = nil

    /// Whether the view is currently loading memos.
    @Published var isLoading: Bool = false

    /// Error message to display if loading fails.
    @Published var errorMessage: String? = nil

    /// Whether a memo submission is in progress.
    @Published var isSubmitting: Bool = false

    /// Transient submit error shown as a toast/alert.
    @Published var submitError: String? = nil

    // MARK: Private

    private let date: Date

    // MARK: Init

    init(date: Date = Date()) {
        self.date = date
    }

    // MARK: - Load Memos

    /// Loads today's memos from the raw storage file and checks compiled status.
    func load() {
        isLoading = true
        errorMessage = nil

        do {
            let loaded = try RawStorage.read(for: date)
            // Newest first
            memos = loaded.sorted { $0.created > $1.created }
        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
            memos = []
        }

        checkDailyPage()
        isLoading = false
    }

    // MARK: - Submit Text Memo

    /// Creates and persists a text memo from the given body string.
    /// Automatically attaches timestamp, device info.
    /// Location and weather are filled in by US-005 / US-006 respectively.
    func submitTextMemo(body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSubmitting = true
        submitError = nil

        let memo = Memo(
            type: .text,
            created: Date(),
            location: nil,      // filled by US-005
            weather: nil,       // filled by US-006
            device: deviceDescription(),
            attachments: [],
            body: trimmed
        )

        do {
            try RawStorage.append(memo)
            // Insert at front (newest first)
            memos.insert(memo, at: 0)
        } catch {
            submitError = "保存失败：\(error.localizedDescription)"
        }

        isSubmitting = false
    }

    // MARK: - Compile Trigger (placeholder)

    /// Triggers manual compilation (placeholder until US-014 is implemented).
    func compile() {
        // Implemented in US-014 / US-010.
    }

    // MARK: - Private Helpers

    // MARK: - Device Info

    /// Returns a human-readable device description string for the frontmatter.
    private func deviceDescription() -> String {
        let device = UIDevice.current
        return "\(device.model) (\(device.systemName) \(device.systemVersion))"
    }

    // MARK: - Private Helpers

    private func checkDailyPage() {
        let dailyURL = dailyPageURL(for: date)
        guard FileManager.default.fileExists(atPath: dailyURL.path) else {
            isDailyPageCompiled = false
            dailyPageSummary = nil
            return
        }

        isDailyPageCompiled = true

        // Extract summary from frontmatter if available
        if let content = try? String(contentsOf: dailyURL, encoding: .utf8) {
            dailyPageSummary = extractSummary(from: content)
        }
    }

    private func dailyPageURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateStr = formatter.string(from: date)
        return VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("daily")
            .appendingPathComponent("\(dateStr).md")
    }

    /// Parses the `summary:` frontmatter field from a Daily Page file.
    private func extractSummary(from content: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("summary:") {
                let value = String(trimmed.dropFirst("summary:".count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}

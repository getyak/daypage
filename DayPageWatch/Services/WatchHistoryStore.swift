import Foundation
import Combine
import SwiftUI

// MARK: - WatchHistoryStore

/// Observable model behind the watch history page.
///
/// P1 defines the shape and the in-flight tracking API; `WatchTransferService`
/// reports enqueue / success / failure into it in P2. P3 adds a `recent`
/// section fed by transcript metadata the phone returns over `transferUserInfo`.
///
/// `@MainActor` — drives SwiftUI. In-flight items are keyed by the source file
/// URL so the transfer service can update a specific clip's status.
@MainActor
final class WatchHistoryStore: ObservableObject {

    static let shared = WatchHistoryStore()

    // MARK: In-flight item

    /// A recording that has not yet been confirmed delivered to the phone.
    struct InFlightItem: Identifiable, Equatable {
        let id: URL           // source file URL — stable key for status updates
        let duration: Int     // seconds
        let createdAt: Date
        var status: Status

        var durationText: String {
            let m = duration / 60
            let s = duration % 60
            return String(format: "%d:%02d", m, s)
        }
    }

    // MARK: Status

    enum Status: Equatable {
        case sending
        case failed

        var label: String {
            switch self {
            case .sending: return "发送中…"
            case .failed:  return "发送失败 · 点击重试"
            }
        }

        var tint: Color {
            switch self {
            case .sending: return .cyan
            case .failed:  return .orange
            }
        }
    }

    // MARK: Recent (synced) item

    /// A clip the phone has confirmed synced + transcribed, fed back over
    /// `transferUserInfo`. The watch stores only this lightweight metadata —
    /// never the audio itself.
    struct RecentItem: Identifiable, Equatable {
        let id: String        // source filename — correlation key from the phone
        let duration: Int     // seconds (0 if the phone didn't send one)
        let summary: String
        let syncedAt: Date

        var durationText: String {
            let m = duration / 60
            let s = duration % 60
            return String(format: "%d:%02d", m, s)
        }
    }

    // MARK: State

    /// Newest first.
    @Published private(set) var inFlight: [InFlightItem] = []

    /// Newest first. Capped to the most recent `recentLimit` items.
    @Published private(set) var recent: [RecentItem] = []

    private let recentLimit = 20

    /// Injected by `WatchTransferService` so a retry tap can re-queue a failed
    /// transfer without the store importing WatchConnectivity itself.
    var retryHandler: ((URL) -> Void)?

    private init() {}

    // MARK: - Mutations (called by WatchTransferService, P2)

    /// Record a newly-queued transfer as in-flight.
    func markSending(fileURL: URL, duration: Int, createdAt: Date = Date()) {
        let item = InFlightItem(id: fileURL, duration: duration, createdAt: createdAt, status: .sending)
        // De-dupe on the same URL (a retry re-marks an existing item).
        if let idx = inFlight.firstIndex(where: { $0.id == fileURL }) {
            inFlight[idx] = item
        } else {
            inFlight.insert(item, at: 0)
        }
    }

    /// The transfer confirmed delivered — drop it from the in-flight list.
    func markDelivered(fileURL: URL) {
        inFlight.removeAll { $0.id == fileURL }
    }

    /// The transfer failed — flip it to the retryable failed state.
    func markFailed(fileURL: URL) {
        guard let idx = inFlight.firstIndex(where: { $0.id == fileURL }) else { return }
        inFlight[idx].status = .failed
    }

    // MARK: - Synced (called from the phone's reverse channel, P3)

    /// The phone confirmed this clip is synced + transcribed. Add it to the
    /// "recent" feed and drop any lingering in-flight entry with the same
    /// source filename. Keyed by filename because the phone only knows the
    /// filename, not the watch's original file URL.
    func markSynced(filename: String, summary: String, duration: Int, syncedAt: Date = Date()) {
        // Remove any in-flight item whose file URL ends in this filename.
        inFlight.removeAll { $0.id.lastPathComponent == filename }

        let item = RecentItem(id: filename, duration: duration, summary: summary, syncedAt: syncedAt)
        // De-dupe on filename (a resend could report twice).
        recent.removeAll { $0.id == filename }
        recent.insert(item, at: 0)
        if recent.count > recentLimit {
            recent.removeLast(recent.count - recentLimit)
        }
    }

    // MARK: - Retry (called by the history UI)

    func retry(_ item: InFlightItem) {
        guard item.status == .failed else { return }
        if let idx = inFlight.firstIndex(where: { $0.id == item.id }) {
            inFlight[idx].status = .sending
        }
        retryHandler?(item.id)
    }
}

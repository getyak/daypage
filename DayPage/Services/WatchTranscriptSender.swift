import Foundation
import WatchConnectivity

// MARK: - WatchTranscriptSender

/// Phone → watch reverse channel. After the phone transcribes a watch-sourced
/// voice clip, it sends a compact summary back to the watch so the watch's
/// history page can show the clip under "最近已同步".
///
/// Uses `transferUserInfo` (ordered, background-delivered queue) rather than
/// `sendMessage` — the watch app is almost never reachable at transcription
/// time, and every synced clip matters, in order. The payload is tiny metadata
/// (filename, a truncated summary, duration); the audio itself never travels
/// back.
///
/// `WCSession` activation + delegation is owned by `WatchReceiveService`; this
/// type only enqueues outbound transfers.
@MainActor
final class WatchTranscriptSender {

    static let shared = WatchTranscriptSender()

    /// Cap the summary so the reverse payload stays small — the watch only
    /// shows a one-line preview.
    private let summaryLimit = 60

    private init() {}

    func send(filename: String, summary: String, duration: Double?) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        // Only meaningful if a watch app is installed to receive it.
        guard session.activationState == .activated, session.isWatchAppInstalled else { return }

        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = trimmed.count > summaryLimit
            ? String(trimmed.prefix(summaryLimit)) + "…"
            : trimmed

        var info: [String: Any] = [
            "type": "watchTranscript",
            "filename": filename,
            "summary": preview,
            "syncedAt": Date().timeIntervalSince1970,
        ]
        if let duration { info["duration"] = duration }

        session.transferUserInfo(info)
    }
}

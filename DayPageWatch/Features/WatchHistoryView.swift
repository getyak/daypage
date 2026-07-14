import SwiftUI

// MARK: - WatchHistoryView

/// The history page — the top page of the three-page vertical TabView.
///
/// P1 ships the scaffold with an empty state. P2 fills the "在途" (in-flight)
/// section from the watch's local transfer queue; P3 adds a "最近" (recently
/// synced) section fed by transcript metadata the phone sends back over
/// `transferUserInfo`.
struct WatchHistoryView: View {

    @ObservedObject var history: WatchHistoryStore

    var body: some View {
        Group {
            if history.inFlight.isEmpty && history.recent.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("最近")
        .containerBackground(.teal.gradient, for: .navigation)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("没有待同步的录音")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("录音会自动发送到 iPhone")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .accessibilityElement(children: .combine)
    }

    // MARK: - List

    private var list: some View {
        List {
            if !history.inFlight.isEmpty {
                Section("在途") {
                    ForEach(history.inFlight) { item in
                        inFlightRow(item)
                    }
                }
            }
            if !history.recent.isEmpty {
                Section("最近") {
                    ForEach(history.recent) { item in
                        recentRow(item)
                    }
                }
            }
        }
    }

    private func recentRow(_ item: WatchHistoryStore.RecentItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.durationText)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(item.syncedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.caption)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("已同步，\(item.durationText)，\(item.summary)")
    }

    private func inFlightRow(_ item: WatchHistoryStore.InFlightItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(item.status.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.durationText)
                    .font(.body.monospacedDigit())
                Text(item.status.label)
                    .font(.caption2)
                    .foregroundStyle(item.status.tint)
            }
            Spacer(minLength: 0)
            if item.status == .failed {
                Button {
                    history.retry(item)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("重试发送")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.durationText)，\(item.status.label)")
    }
}

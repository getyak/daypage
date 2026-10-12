import Foundation

// MARK: - DiagnosticsEventGate

/// Pure, SDK-independent admission helper for diagnostics events (issue #928).
///
/// Confirmed source-level race in the pinned Sentry 8.58.4 chain: a deferred
/// raw-crash conversion can carry the OLD crash timestamp into a NEW consent
/// epoch's Hub after revoke → regrant (the queued sink block captures the raw
/// report in memory and routes through the current global Hub). The transport
/// gate and envelope allowlist cannot see this because the event is created
/// fresh. The mitigation is a timestamp admission floor persisted with the
/// consent epoch and checked in the real beforeSend before the field scrubber.
///
/// This is a SOURCE-PROVEN race, not an observed production upload. The helper
/// never starts the SDK and never reads crash or cache data — callers deliver
/// synthetic or in-memory timestamps only.
public enum DiagnosticsEventGate {

    /// Admits an event only when ALL hold:
    ///   1. diagnostics consent is live-true,
    ///   2. a captured epoch snapshot exists,
    ///   3. the current epoch matches the captured snapshot exactly,
    ///   4. the event timestamp is present and finite,
    ///   5. the timestamp is at or after the captured floor.
    ///
    /// There is deliberately NO pre-floor grace window: the SDK truncates
    /// crash times to whole seconds, so a timestamp strictly before the floor
    /// is conservatively rejected. The floor is the persistent epoch start —
    /// never the SDK start time — so prior-launch crashes under continuous
    /// consent remain eligible.
    public static func admit(
        timestamp: Date?,
        snapshot: DiagnosticsConsent.EpochSnapshot?,
        currentEpoch: UUID?,
        isOptedIn: Bool
    ) -> Bool {
        guard isOptedIn,
              let snapshot,
              let currentEpoch,
              currentEpoch == snapshot.id,
              let timestamp else {
            return false
        }
        let eventTime = timestamp.timeIntervalSince1970
        let floor = snapshot.startedAt.timeIntervalSince1970
        guard eventTime.isFinite, floor.isFinite else { return false }
        return eventTime >= floor
    }
}

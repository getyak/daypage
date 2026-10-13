import Foundation

// MARK: - DiagnosticsConsent

/// Persisted, opt-in consent for remote crash diagnostics (issue #922).
///
/// Consent is FAIL CLOSED: a missing or unreadable value means "not opted in".
/// The live Sentry SDK must never start — and must stop when already running —
/// unless this says yes AND a DSN is configured. The setting is written from
/// the in-app Privacy & data screen (Settings → About) and is cleared back to
/// the default (off) by the "Clear local data" wipe.
///
/// Scope of the upload when enabled: filtered crash reports and finite
/// operational fields — never note text, attachments, transcripts, or secrets
/// (see `DiagnosticsEnvelopeSanitizer`, `OperationalEvent`). Events already uploaded cannot
/// be recalled from the device by revoking consent; revocation only prevents
/// future events.
public enum DiagnosticsConsent {

    /// Centralized defaults key — see `AppSettings.Keys.crashDiagnosticsConsent`.
    public static let defaultsKey = AppSettings.Keys.crashDiagnosticsConsent

    // MARK: Change handler (app wires live SDK start/close)

    // Read, persistence, and notification are one serialized transition. The
    // recursive lock lets a synchronous revocation handler re-read consent.
    private static let lock = NSRecursiveLock()
    private static let epochKey = "settings.crashDiagnosticsEpoch"
    private static let epochStartKey = "settings.crashDiagnosticsEpochStart"
    nonisolated(unsafe) private static var _changeHandler: (@Sendable (Bool) -> Void)?

    /// Registered once at app launch. Invoked synchronously after persistence
    /// to cut off transport on revocation. SDK start/close is scheduled on its
    /// MainActor owner outside this lock. Kit never imports Sentry itself.
    public static var changeHandler: (@Sendable (Bool) -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _changeHandler
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _changeHandler = newValue
        }
    }

    // MARK: Consent state

    /// Live consent for the standard defaults store. Unset → false.
    public nonisolated static var isOptedIn: Bool {
        isOptedIn(in: .standard)
    }

    /// Consent state read from an explicit store (testable). Unset or a
    /// non-boolean value → false, so a corrupted value can never opt the user in.
    public nonisolated static func isOptedIn(in store: UserDefaults) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let stored = store.object(forKey: defaultsKey) as? NSNumber,
              CFGetTypeID(stored) == CFBooleanGetTypeID() else { return false }
        return stored.boolValue
    }

    /// Persists the consent decision and fires `changeHandler` with the new
    /// value. Setting false (or clearing the key elsewhere) revokes consent:
    /// the handler must close the SDK and every event gate must refuse.
    ///
    /// Granting reuses an existing VALID (UUID, floor) pair — the floor is
    /// immutable for the life of the epoch — and conservatively rotates both
    /// values when either is missing or malformed (issue #928).
    public nonisolated static func setOptedIn(
        _ optedIn: Bool,
        in store: UserDefaults = .standard,
        now: Date = Date()
    ) {
        lock.lock(); defer { lock.unlock() }
        if optedIn {
            let hasValidPair = isOptedIn(in: store)
                && UUID(uuidString: store.string(forKey: epochKey) ?? "") != nil
                && validFloor(store.object(forKey: epochStartKey)) != nil
            if !hasValidPair {
                store.set(UUID().uuidString, forKey: epochKey)
                store.set(now, forKey: epochStartKey)
            }
        } else {
            store.removeObject(forKey: epochKey)
            store.removeObject(forKey: epochStartKey)
        }
        store.set(optedIn, forKey: defaultsKey)
        _changeHandler?(optedIn)
    }

    /// Cache isolation follows the persisted consent epoch, including across
    /// app restarts. Revocation permanently abandons the old cache directory.
    public nonisolated static func epoch(in store: UserDefaults = .standard) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard isOptedIn(in: store), let value = store.string(forKey: epochKey) else { return nil }
        return UUID(uuidString: value)
    }

    /// Gives legacy opted-in installations a new isolated cache once.
    public nonisolated static func prepareEpoch(in store: UserDefaults = .standard) -> UUID? {
        prepareEpochSnapshot(in: store)?.id
    }

    // MARK: - Epoch start floor (issue #928)

    /// Immutable identity of one consent epoch: the cache-isolation UUID and
    /// the persistent admission floor. Prior-launch crashes dated at or after
    /// `startedAt` stay eligible under continuous consent; anything older (or
    /// nil) is rejected in beforeSend.
    public struct EpochSnapshot: Sendable, Equatable {
        public let id: UUID
        public let startedAt: Date
        public init(id: UUID, startedAt: Date) {
            self.id = id
            self.startedAt = startedAt
        }
    }

    /// Strict floor validation: only a finite `Date` counts. Everything else
    /// (wrong type, nil, NaN/inf) is untrusted and forces a rotation.
    private nonisolated static func validFloor(_ value: Any?) -> Date? {
        guard let date = value as? Date else { return nil }
        let interval = date.timeIntervalSince1970
        guard interval.isFinite else { return nil }
        return date
    }

    /// Read-only view of the current (UUID, floor) pair. Requires live consent
    /// and a fully valid pair — never synthesizes or rotates.
    public nonisolated static func epochSnapshot(in store: UserDefaults = .standard) -> EpochSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard isOptedIn(in: store),
              let id = UUID(uuidString: store.string(forKey: epochKey) ?? ""),
              let floor = validFloor(store.object(forKey: epochStartKey)) else { return nil }
        return EpochSnapshot(id: id, startedAt: floor)
    }

    /// Returns the persisted pair for the CURRENT consent epoch, rotating to a
    /// fresh (UUID, floor) when the stored pair is legacy or malformed. Runs
    /// inside the same serialized transition as persistence.
    public nonisolated static func prepareEpochSnapshot(
        in store: UserDefaults = .standard,
        now: Date = Date()
    ) -> EpochSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard isOptedIn(in: store) else { return nil }
        if let id = UUID(uuidString: store.string(forKey: epochKey) ?? ""),
           let floor = validFloor(store.object(forKey: epochStartKey)) {
            return EpochSnapshot(id: id, startedAt: floor)
        }
        let fresh = EpochSnapshot(id: UUID(), startedAt: now)
        store.set(fresh.id.uuidString, forKey: epochKey)
        store.set(fresh.startedAt, forKey: epochStartKey)
        return fresh
    }

    /// A short synchronous permit for epoch verification and session creation,
    /// carrying the immutable snapshot (UUID + floor).
    /// SDK.start/close must run OUTSIDE it: startup-crash recovery can synchronously
    /// flush background transport work that itself needs the consent lock.
    public nonisolated static func withCurrentEpochSnapshot<Result>(
        in store: UserDefaults = .standard,
        now: Date = Date(),
        _ operation: (EpochSnapshot) throws -> Result
    ) rethrows -> Result? {
        lock.lock(); defer { lock.unlock() }
        guard let snapshot = prepareEpochSnapshot(in: store, now: now) else { return nil }
        return try operation(snapshot)
    }

    /// A short synchronous permit for epoch verification and session creation.
    /// SDK.start/close must run OUTSIDE it: startup-crash recovery can synchronously
    /// flush background transport work that itself needs the consent lock.
    public nonisolated static func withCurrentEpoch<Result>(
        in store: UserDefaults = .standard,
        _ operation: (UUID) throws -> Result
    ) rethrows -> Result? {
        lock.lock(); defer { lock.unlock() }
        guard let epoch = prepareEpoch(in: store) else { return nil }
        return try operation(epoch)
    }

    /// Final transport registration shares the same linearization point as
    /// persistence. The callback may take the gate lock only AFTER this lock;
    /// it must synchronously re-read its consent predicate before resume.
    nonisolated static func withSerializedTransition<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        lock.lock(); defer { lock.unlock() }
        return try operation()
    }
}

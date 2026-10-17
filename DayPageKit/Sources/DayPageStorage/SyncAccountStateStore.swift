import Foundation

/// Account binding and pull-cursor metadata for one local Vault.
///
/// A Vault is bound to exactly one realm — the (normalized HTTPS backend
/// origin, user UUID) pair of the first authenticated account that syncs it.
/// A later login for another user OR another backend origin fails closed
/// instead of uploading the previous account's pending notes to a different
/// project. The sidecar keeps the historical `account-v1.json` filename on
/// purpose (a rename must never bypass detection of pre-realm state); the
/// content is explicitly versioned and binds BOTH origin and UUID.
///
/// Compatibility / recovery boundary (ADR-0024):
///
///   - Schema-v1 state (no origin), corrupt state, and first claims over
///     unproven legacy cloud transfer obligations all fail closed with a
///     bounded error and leave every byte of the account file, cursor, raw
///     YAML/Markdown, outbox, transfers and partial files untouched. There is
///     no automatic rebind, clearing, reset or migration — recovery of legacy
///     Vault state is an explicit, parent-owned decision.
///   - A genuinely first, unclaimed local Vault binds normally and keeps its
///     offline outbox so queued notes upload unchanged.
public enum SyncAccountStateError: LocalizedError, Equatable {
    case accountMismatch(expected: UUID, actual: UUID)
    case originMismatch(expected: String, actual: String)
    case legacyRealmUnverified
    case invalidState

    public var errorDescription: String? {
        switch self {
        case .accountMismatch:
            return "此本地 Vault 已绑定到另一个 DayPage 账户"
        case .originMismatch:
            return "此本地 Vault 已绑定到另一个同步项目"
        case .legacyRealmUnverified:
            return "此本地 Vault 存在无法证明来源的旧同步状态，已暂停同步以保护数据"
        case .invalidState:
            return "本地同步账户状态已损坏"
        }
    }
}

public enum SyncAccountStateStore {
    private struct State: Codable {
        var schemaVersion: Int = 2
        var origin: String
        var userID: UUID
        var pullCursor: Int64 = 0

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case origin
            case userID = "user_id"
            case pullCursor = "pull_cursor"
        }
    }

    private static let queue = DispatchQueue(label: "com.daypage.sync-account-state")

    /// The historical filename is retained so a rename can never bypass
    /// detection of schema-v1 / pre-realm state.
    public static var stateURL: URL {
        SyncTransferSidecarBinding.syncDirectory(vaultRoot: VaultInitializer.vaultURL)
            .appendingPathComponent("account-v1.json")
    }

    /// Claims an unbound Vault for `realm`, or validates an existing binding.
    ///
    /// Returns the current monotonic pull cursor. Claims never rewrite an
    /// existing file and never touch the outbox: offline queued notes of a
    /// genuine first bind are preserved and uploaded as-is.
    @discardableResult
    public static func bind(to realm: SyncRealmIdentity) throws -> Int64 {
        try queue.sync {
            if let state = try loadIfPresent() {
                try verify(state, matches: realm)
                return state.pullCursor
            }
            // No account sidecar yet: only a genuine first claim may bind.
            // Existing cloud transfer/resume/partial state of unknown origin
            // proves this is NOT an unclaimed Vault and must be held.
            switch SyncTransferSidecarBinding.inspect(
                vaultRoot: VaultInitializer.vaultURL,
                expecting: realm
            ) {
            case .claimable, .proven:
                break
            case .foreign:
                throw SyncAccountStateError.legacyRealmUnverified
            case .unproven:
                throw SyncAccountStateError.legacyRealmUnverified
            }
            let state = State(origin: realm.normalizedOrigin, userID: realm.userID)
            try save(state)
            return state.pullCursor
        }
    }

    /// The currently bound realm, when a valid binding exists. Legacy (v1),
    /// corrupt or otherwise unverifiable state throws instead of guessing.
    public static func boundRealm() throws -> SyncRealmIdentity? {
        try queue.sync {
            guard let state = try loadIfPresent() else { return nil }
            return SyncRealmIdentity(
                origin: try SyncRealmOrigin(validating: state.origin),
                userID: state.userID
            )
        }
    }

    /// True only for a Vault with no account binding AND no cloud transfer
    /// obligations of any kind. The legacy uploader fallback may only ever be
    /// a candidate for such a Vault.
    public static func isUnclaimedVault() -> Bool {
        queue.sync {
            do {
                if try loadIfPresent() != nil { return false }
            } catch {
                // Corrupt or legacy state is never treated as unclaimed.
                return false
            }
            return SyncTransferSidecarBinding.isUnclaimed(vaultRoot: VaultInitializer.vaultURL)
        }
    }

    public static func pullCursor(for realm: SyncRealmIdentity) throws -> Int64 {
        try queue.sync {
            guard let state = try loadIfPresent() else {
                throw SyncAccountStateError.invalidState
            }
            try verify(state, matches: realm)
            return state.pullCursor
        }
    }

    /// Cursor updates are monotonic so a delayed page can never move a device
    /// backwards and replay already-applied changes indefinitely.
    public static func advancePullCursor(to cursor: Int64, for realm: SyncRealmIdentity) throws {
        try queue.sync {
            guard var state = try loadIfPresent() else {
                throw SyncAccountStateError.invalidState
            }
            try verify(state, matches: realm)
            guard cursor >= state.pullCursor else { return }
            state.pullCursor = cursor
            try save(state)
        }
    }

    private static func verify(_ state: State, matches realm: SyncRealmIdentity) throws {
        guard state.origin == realm.normalizedOrigin else {
            throw SyncAccountStateError.originMismatch(
                expected: state.origin,
                actual: realm.normalizedOrigin
            )
        }
        guard state.userID == realm.userID else {
            throw SyncAccountStateError.accountMismatch(
                expected: state.userID,
                actual: realm.userID
            )
        }
    }

    /// Lenient shape probe used only to CLASSIFY unreadable/legacy state
    /// without ever reinterpreting it as an empty or migratable binding.
    private struct ShapeProbe: Codable {
        var schemaVersion: Int?
        var origin: String?
        var userID: UUID?
        var pullCursor: Int64?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case origin
            case userID = "user_id"
            case pullCursor = "pull_cursor"
        }
    }

    /// Strict reader: every unreadable or pre-realm shape fails closed while
    /// leaving the file untouched on disk.
    private static func loadIfPresent() throws -> State? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: stateURL)
        } catch {
            // Unreadable state is never assumed absent.
            throw SyncAccountStateError.invalidState
        }
        let probe: ShapeProbe
        do {
            probe = try JSONDecoder().decode(ShapeProbe.self, from: data)
        } catch {
            // Corrupt or undecodable state is never repaired or replaced here.
            throw SyncAccountStateError.invalidState
        }
        if probe.schemaVersion == 1 || probe.origin == nil {
            // Schema v1 has no origin binding: this is legacy state, never
            // auto-migrated or bypassed.
            throw SyncAccountStateError.legacyRealmUnverified
        }
        guard probe.schemaVersion == 2 else {
            // Unknown future versions are not guessed either.
            throw SyncAccountStateError.invalidState
        }
        let state: State
        do {
            state = try JSONDecoder().decode(State.self, from: data)
        } catch {
            throw SyncAccountStateError.invalidState
        }
        let origin = try SyncRealmOrigin(validating: state.origin)
        guard origin.normalized == state.origin, state.pullCursor >= 0 else {
            throw SyncAccountStateError.invalidState
        }
        return state
    }

    private static func save(_ state: State) throws {
        let url = stateURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: [.atomic])
    }
}

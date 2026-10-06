import Foundation
import DayPageModels

public enum MemoRecordStoreError: LocalizedError, Equatable, Sendable {
    case notFound(UUID)
    case emptyBody
    case invalidDay(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "The memo is no longer available."
        case .emptyBody:
            return "A memo body cannot be empty."
        case .invalidDay:
            return "The memo's owning day is invalid."
        }
    }
}

/// Stable ID-based read and mutation boundary for memo detail surfaces.
///
/// Navigation carries only `(memoID, owning day)`.  The destination resolves the
/// current record here rather than depending on whichever mutable list happened
/// to build the route.  Mutations use `RawStorage.mutate`, keeping the read,
/// transform, write, outbox update, and cache notification in one serialized
/// critical section.
///
/// The `dayString:` overloads are the canonical path: the owning raw file is
/// selected directly from a validated `YYYY-MM-DD` key, so a preferred-time-zone
/// change after navigation can never retarget the operation. The legacy `day:`
/// overloads stay source-compatible for existing callers.
public actor MemoRecordStore {
    public static let shared = MemoRecordStore()

    public init() {}

    private static func validatedDayString(_ dayString: String) throws -> String {
        guard RawStorage.isValidDayString(dayString) else {
            throw MemoRecordStoreError.invalidDay(dayString)
        }
        return dayString
    }

    public func memo(id: UUID, day: Date, vaultRoot: URL = VaultInitializer.vaultURL) throws -> Memo {
        guard let memo = try RawStorage.read(for: day, vaultRoot: vaultRoot).first(where: { $0.id == id }) else {
            throw MemoRecordStoreError.notFound(id)
        }
        return memo
    }

    public func memo(id: UUID, dayString: String, vaultRoot: URL = VaultInitializer.vaultURL) throws -> Memo {
        let dayString = try Self.validatedDayString(dayString)
        guard let memo = try RawStorage.read(dayString: dayString, vaultRoot: vaultRoot).first(where: { $0.id == id }) else {
            throw MemoRecordStoreError.notFound(id)
        }
        return memo
    }

    @discardableResult
    public func updateBody(id: UUID, day: Date, body: String, vaultRoot: URL = VaultInitializer.vaultURL) throws -> Memo {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MemoRecordStoreError.emptyBody }

        var result: Memo?
        try RawStorage.mutate(for: day, vaultRoot: vaultRoot) { memos in
            guard let index = memos.firstIndex(where: { $0.id == id }) else { return nil }
            var updated = memos
            updated[index].body = body
            result = updated[index]
            return updated
        }
        guard let result else { throw MemoRecordStoreError.notFound(id) }
        return result
    }

    @discardableResult
    public func updateBody(id: UUID, dayString: String, body: String, vaultRoot: URL = VaultInitializer.vaultURL) throws -> Memo {
        let dayString = try Self.validatedDayString(dayString)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MemoRecordStoreError.emptyBody }

        var result: Memo?
        try RawStorage.mutate(dayString: dayString, vaultRoot: vaultRoot) { memos in
            guard let index = memos.firstIndex(where: { $0.id == id }) else { return nil }
            var updated = memos
            updated[index].body = body
            result = updated[index]
            return updated
        }
        guard let result else { throw MemoRecordStoreError.notFound(id) }
        return result
    }

    @discardableResult
    public func delete(id: UUID, day: Date, vaultRoot: URL = VaultInitializer.vaultURL) throws -> Memo {
        var deleted: Memo?
        try RawStorage.mutate(for: day, vaultRoot: vaultRoot) { memos in
            guard let latest = memos.first(where: { $0.id == id }) else { return nil }
            deleted = latest
            return memos.filter { $0.id != id }
        }
        guard let deleted else { throw MemoRecordStoreError.notFound(id) }
        return deleted
    }

    @discardableResult
    public func delete(id: UUID, dayString: String, vaultRoot: URL = VaultInitializer.vaultURL) throws -> Memo {
        let dayString = try Self.validatedDayString(dayString)
        var deleted: Memo?
        try RawStorage.mutate(dayString: dayString, vaultRoot: vaultRoot) { memos in
            guard let latest = memos.first(where: { $0.id == id }) else { return nil }
            deleted = latest
            return memos.filter { $0.id != id }
        }
        guard let deleted else { throw MemoRecordStoreError.notFound(id) }
        return deleted
    }

    /// Restores a previously deleted record without duplicating an ID that may
    /// already have been recreated by sync. The raw file keeps chronological
    /// order so every existing read surface receives the same stable sequence.
    public func restore(_ memo: Memo, day: Date, vaultRoot: URL = VaultInitializer.vaultURL) throws {
        try RawStorage.mutate(for: day, vaultRoot: vaultRoot) { memos in
            guard !memos.contains(where: { $0.id == memo.id }) else { return nil }
            return (memos + [memo]).sorted { $0.created < $1.created }
        }
    }

    public func restore(_ memo: Memo, dayString: String, vaultRoot: URL = VaultInitializer.vaultURL) throws {
        let dayString = try Self.validatedDayString(dayString)
        try RawStorage.mutate(dayString: dayString, vaultRoot: vaultRoot) { memos in
            guard !memos.contains(where: { $0.id == memo.id }) else { return nil }
            return (memos + [memo]).sorted { $0.created < $1.created }
        }
    }

    /// Changes only pin metadata on the latest record, preserving edits and
    /// attachments written by other surfaces since the list was loaded.
    @discardableResult
    public func setPinnedAt(id: UUID, day: Date, pinnedAt: Date?, vaultRoot: URL = VaultInitializer.vaultURL) throws -> Memo {
        var result: Memo?
        try RawStorage.mutate(for: day, vaultRoot: vaultRoot) { memos in
            guard let index = memos.firstIndex(where: { $0.id == id }) else { return nil }
            var updated = memos
            updated[index].pinnedAt = pinnedAt
            result = updated[index]
            return updated
        }
        guard let result else { throw MemoRecordStoreError.notFound(id) }
        return result
    }

    @discardableResult
    public func setPinnedAt(id: UUID, dayString: String, pinnedAt: Date?, vaultRoot: URL = VaultInitializer.vaultURL) throws -> Memo {
        let dayString = try Self.validatedDayString(dayString)
        var result: Memo?
        try RawStorage.mutate(dayString: dayString, vaultRoot: vaultRoot) { memos in
            guard let index = memos.firstIndex(where: { $0.id == id }) else { return nil }
            var updated = memos
            updated[index].pinnedAt = pinnedAt
            result = updated[index]
            return updated
        }
        guard let result else { throw MemoRecordStoreError.notFound(id) }
        return result
    }
}

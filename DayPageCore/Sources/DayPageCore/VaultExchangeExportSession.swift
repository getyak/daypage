import Foundation

public struct VaultExchangeExportSelection: Equatable, Sendable {
  public enum Scope: String, Sendable { case all, day, week }
  public let scope: Scope
  public let date: Date
  public let timeZoneID: String
  public init(scope: String, date: Date, timeZone: TimeZone) throws {
    guard let scope = Scope(rawValue: scope), date.timeIntervalSince1970.isFinite else { throw VaultExchangeError.invalid }
    self.scope = scope; self.date = date; timeZoneID = timeZone.identifier
  }
}

public struct VaultExchangeExportTicket: Sendable {
  public let id: UUID
  public let selection: VaultExchangeExportSelection
}

public struct VaultExchangeExportPreview: Sendable {
  public let ticket: VaultExchangeExportTicket
  public let snapshot: VaultExchangeSnapshot
}

private final class ExchangeExportAuthority: @unchecked Sendable {
  private let lock = NSLock()
  private var current: VaultExchangeExportTicket?
  func begin(_ selection: VaultExchangeExportSelection) -> VaultExchangeExportTicket {
    lock.lock(); defer { lock.unlock() }
    let ticket = VaultExchangeExportTicket(id: UUID(), selection: selection)
    current = ticket
    return ticket
  }
  func invalidate() { lock.lock(); current = nil; lock.unlock() }
  func matches(_ ticket: VaultExchangeExportTicket) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return current?.id == ticket.id && current?.selection == ticket.selection
  }
}

/// A scope change revokes authorization synchronously, even if a queued actor
/// read or an uncooperative file provider finishes later. A preview is usable
/// only by its exact still-current selection and request identity.
public actor VaultExchangeExportSession {
  public typealias Reader = @Sendable (VaultExchangeExportSelection) async throws -> VaultExchangeSnapshot
  private let reader: Reader
  private let authority = ExchangeExportAuthority()
  public init(store: NotebookStore) {
    reader = { selection in
      let ids: Set<String>?
      if selection.scope == .all { ids = nil }
      else {
        guard let zone = TimeZone(identifier: selection.timeZoneID) else { throw VaultExchangeError.invalid }
        let period = try ReviewPeriod(kind: selection.scope == .day ? .day : .week, anchor: selection.date, timeZone: zone)
        ids = Set(try await store.exchangeEntries(period: period).map(\.id))
      }
      return try await store.exchangeSnapshot(selectedIDs: ids)
    }
  }
  public init(reader: @escaping Reader) { self.reader = reader }
  public nonisolated func begin(_ selection: VaultExchangeExportSelection) -> VaultExchangeExportTicket { authority.begin(selection) }
  public nonisolated func invalidate() { authority.invalidate() }
  public nonisolated func isCurrent(_ preview: VaultExchangeExportPreview) -> Bool { authority.matches(preview.ticket) }
  public nonisolated func canExport(_ preview: VaultExchangeExportPreview, selection: VaultExchangeExportSelection) -> Bool {
    preview.ticket.selection == selection && authority.matches(preview.ticket)
  }
  public func prepare(_ ticket: VaultExchangeExportTicket) async throws -> VaultExchangeExportPreview {
    try Task.checkCancellation()
    guard authority.matches(ticket) else { throw VaultExchangeError.changed }
    let snapshot = try await reader(ticket.selection)
    try Task.checkCancellation()
    guard authority.matches(ticket) else { throw VaultExchangeError.changed }
    try snapshot.validated()
    guard authority.matches(ticket) else { throw VaultExchangeError.changed }
    return VaultExchangeExportPreview(ticket: ticket, snapshot: snapshot)
  }
}

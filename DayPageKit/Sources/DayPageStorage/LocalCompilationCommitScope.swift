import Foundation

/// Admission and asynchronous drain for local compilation effects. The lock
/// protects bookkeeping only; callers never run I/O or callbacks under it.
public final class LocalCompilationCommitScope: @unchecked Sendable {
    public static let shared = LocalCompilationCommitScope()

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var active: Set<UUID> = []
    private var transitions: Set<UUID> = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public struct Token: Sendable {
        fileprivate let scope: LocalCompilationCommitScope
        fileprivate let generation: UInt64
        public let vaultRoot: URL
        public var isCurrent: Bool { scope.isCurrent(generation) }
    }

    public struct Commit: Sendable {
        fileprivate let scope: LocalCompilationCommitScope
        fileprivate let id: UUID
        public func finish() { scope.finishCommit(id) }
    }

    public struct Transition: Sendable {
        fileprivate let scope: LocalCompilationCommitScope
        fileprivate let id: UUID
        fileprivate let generation: UInt64
        public var isCurrent: Bool { scope.isCurrentTransition(id, generation: generation) }
        public var isDrained: Bool { !scope.hasActiveCommits }
        public func waitForDrain() async { await scope.waitForDrain() }
        public func finish() { scope.finishTransition(id) }
    }

    public var hasActiveCommits: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !active.isEmpty
    }

    public func capture(vaultRoot: URL) throws -> Token {
        let root = vaultRoot.standardizedFileURL
        lock.lock()
        defer { lock.unlock() }
        guard transitions.isEmpty else { throw CancellationError() }
        return Token(scope: self, generation: generation, vaultRoot: root)
    }

    public func beginCommit(_ token: Token) throws -> Commit {
        lock.lock()
        defer { lock.unlock() }
        guard token.scope === self, token.generation == generation, transitions.isEmpty else {
            throw CancellationError()
        }
        let id = UUID()
        active.insert(id)
        return Commit(scope: self, id: id)
    }

    /// Synchronous refusal boundary, called before scheduling a transition task.
    public func close() -> Transition {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        let id = UUID()
        transitions.insert(id)
        return Transition(scope: self, id: id, generation: generation)
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation && transitions.isEmpty
    }

    private func isCurrentTransition(_ id: UUID, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation && transitions.contains(id)
    }

    private func waitForDrain() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if active.isEmpty {
                lock.unlock()
                continuation.resume()
            } else {
                drainWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func finishCommit(_ id: UUID) {
        lock.lock()
        active.remove(id)
        let waiters: [CheckedContinuation<Void, Never>]
        if active.isEmpty {
            waiters = drainWaiters
            drainWaiters.removeAll()
        } else {
            waiters = []
        }
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    private func finishTransition(_ id: UUID) {
        lock.lock()
        transitions.remove(id)
        lock.unlock()
    }
}

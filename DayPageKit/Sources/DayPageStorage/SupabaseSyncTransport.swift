// SupabaseSyncTransport.swift — sync-only constrained HTTP transport.
//
// Used ONLY by the Supabase sync components (uploader / puller / downloader).
// It is deliberately separate from `HTTPTransports.shared`: the LLM/ASR and
// other services keep their existing transport behavior untouched. The global
// `HTTPTransport.swift` interface is not modified.
//
// Three hard constraints:
//
//   1. Redirects are refused BEFORE they can be followed. On the production
//      `URLSession` path a task-level delegate returns `nil` from
//      `willPerformHTTPRedirection`, so a 3xx can never cause the bearer token
//      to be re-sent to another authority. Wrapped fakes (test seam) have any
//      3xx result refused as well.
//   2. Every request URL must already be the configured realm origin before
//      any header (apikey / Authorization) is attached and sent.
//   3. The ACTUAL request start (URLSession task creation + resume) is
//      synchronous and runs inside the session lease's validity gate via
//      `SyncSessionNetwork` — a caller-side `assertValid` immediately before
//      an `await` is NOT a send boundary. Invalidation linearized before the
//      start means zero request starts; a request that already started may
//      finish but its result can never commit local state.

import Foundation

// MARK: - SyncResumableEndpoint

/// Validation for saved and newly issued TUS resumable upload URLs.
///
/// Both the persisted `resumable_url` and a fresh `Location` header value must
/// pass this check BEFORE any HEAD/PATCH (or bearer) is sent: same normalized
/// origin and exactly the canonical resumable path
/// `/storage/v1/upload/resumable/<upload-id>` with one safe id segment. No
/// userinfo, query, fragment, percent-encoding, duplicate slashes or path
/// escape is allowed.
public enum SyncResumableEndpoint {
    public static func validated(
        _ url: URL,
        origin: SyncRealmOrigin
    ) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              origin.matchesRoot(url) else {
            throw SyncRealmError.invalidResumableURL
        }
        let pieces = components.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard pieces.count == 6,
              pieces[0].isEmpty,
              pieces[1] == "storage",
              pieces[2] == "v1",
              pieces[3] == "upload",
              pieces[4] == "resumable",
              isSafeUploadID(String(pieces[5])) else {
            throw SyncRealmError.invalidResumableURL
        }
        return url
    }

    /// Upload ids are opaque single path segments. Restricting the alphabet
    /// blocks percent-encoded traversal and double-encoding tricks.
    static func isSafeUploadID(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

// MARK: - Transient download ownership

/// Transient ownership for network-downloaded bytes.
///
/// `URLSession.downloadTask(with:completionHandler:)` hands back a temporary
/// file whose lifetime Apple only guarantees for the duration of the
/// completion callback — it must be opened/moved before the callback returns.
/// `adopt` synchronously copies the bytes into a uniquely owned,
/// permission-restricted transient location INSIDE the callback, before the
/// URL is ever published to consumers. Consumers call `discard` when finished
/// (success, failure or stale lease). These files are transient transport
/// data only: never Vault obligations, never persistent staging, never a
/// bypass of the generation gate.
public enum SyncNetworkTempFile {
    private static let namespace = "daypage-sync-net"

    /// Copies `source` into an owned transient file (0700 directory, 0600
    /// file) and returns the owned URL. The source may disappear afterwards.
    public static func adopt(_ source: URL) throws -> URL {
        let owner = rootDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var adopted = false
        defer {
            if !adopted { try? FileManager.default.removeItem(at: owner) }
        }
        try FileManager.default.createDirectory(
            at: owner,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = owner.appendingPathComponent(sanitized(source.lastPathComponent))
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
        adopted = true
        return destination
    }

    /// Removes an owned transient file and its owned directory. A no-op for
    /// any URL outside the owned namespace (test fixture URLs are preserved).
    public static func discard(_ url: URL) {
        guard isOwned(url) else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    public static func isOwned(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let grandparent = parent.deletingLastPathComponent().standardizedFileURL
        return grandparent.lastPathComponent == namespace
            && parent.lastPathComponent != namespace
            && grandparent.path.hasPrefix(rootDirectory().standardizedFileURL.path)
    }

    static func rootDirectory() -> URL {
        #if DEBUG
        // XCTest may replace TMPDIR; keep explicit guarded test artifacts
        // under the caller's registered root without changing Vault storage.
        if let root = ProcessInfo.processInfo.environment["DAYPAGE_TEST_VAULT_ROOT"],
           !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(namespace, isDirectory: true)
        }
        #endif
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
    }

    private static func sanitized(_ name: String) -> String {
        let filtered = String(name.map { character -> Character in
            character.isLetter || character.isNumber
                || character == "-" || character == "." || character == "_"
                ? character : "-"
        })
        return filtered.isEmpty ? "download.bin" : filtered
    }
}

// MARK: - Pending results and send starters

/// A request whose START (task creation + resume) already happened
/// synchronously; only its RESULT is awaited later.
public final class SyncPendingResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var waiters: [CheckedContinuation<Value, Error>] = []
    private var retainedWork: Any?

    public init() {}

    /// Eagerly starts `body` (synchronously creating its task) and delivers
    /// its outcome. Used to adapt legacy async test fakes.
    public static func started(
        _ body: @escaping @Sendable () async throws -> Value
    ) -> SyncPendingResult<Value> {
        let pending = SyncPendingResult<Value>()
        let task = Task {
            do {
                pending.fulfill(.success(try await body()))
            } catch {
                pending.fulfill(.failure(error))
            }
        }
        pending.retain(task)
        return pending
    }

    public func fulfill(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume(with: result)
        }
    }

    public func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func retain(_ work: Any) {
        lock.lock()
        retainedWork = work
        lock.unlock()
    }
}

/// Conformance implemented by the real sync transport (and by test fakes that
/// model real send semantics): each request is STARTED synchronously — task
/// created and resumed before returning — so the caller can linearize the
/// start inside the session lease gate.
public protocol SyncRequestStarter: Sendable {
    func startData(
        _ request: URLRequest
    ) throws -> SyncPendingResult<(Data, URLResponse)>
    func startUpload(
        _ request: URLRequest,
        from fileURL: URL
    ) throws -> SyncPendingResult<(Data, URLResponse)>
    func startDownload(
        _ request: URLRequest
    ) throws -> SyncPendingResult<(URL, URLResponse)>
}

/// Adapts legacy async fakes (`HTTPTransport` / `AttachmentFileTransport`)
/// behind the starter seam. The adapter creates its task eagerly (a
/// synchronous start at this layer); production uses
/// `SupabaseSyncTransport`'s exact URLSession-task start instead.
struct SyncRequestStarterAdapter: SyncRequestStarter {
    let data: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let upload: @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)
    let download: @Sendable (URLRequest) async throws -> (URL, URLResponse)

    init(dataTransport: HTTPTransport, fileTransport: AttachmentFileTransport) {
        self.data = { try await dataTransport.data(for: $0) }
        self.upload = { try await fileTransport.uploadFile(for: $0, from: $1) }
        self.download = { try await fileTransport.downloadFile(for: $0) }
    }

    func startData(
        _ request: URLRequest
    ) throws -> SyncPendingResult<(Data, URLResponse)> {
        let send = data
        return .started { try await send(request) }
    }

    func startUpload(
        _ request: URLRequest,
        from fileURL: URL
    ) throws -> SyncPendingResult<(Data, URLResponse)> {
        let send = upload
        return .started { try await send(request, fileURL) }
    }

    func startDownload(
        _ request: URLRequest
    ) throws -> SyncPendingResult<(URL, URLResponse)> {
        let send = download
        return .started {
            let (url, response) = try await send(request)
            let owned = try SyncNetworkTempFile.adopt(url)
            return (owned, response)
        }
    }
}

/// Adapts a file-transfer-only fake/transport (`AttachmentFileTransport`)
/// behind the starter seam; `data` is unused on that path.
struct SyncFileRequestStarterAdapter: SyncRequestStarter {
    let upload: @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)
    let download: @Sendable (URLRequest) async throws -> (URL, URLResponse)

    init(fileTransport: AttachmentFileTransport) {
        self.upload = { try await fileTransport.uploadFile(for: $0, from: $1) }
        self.download = { try await fileTransport.downloadFile(for: $0) }
    }

    func startData(
        _ request: URLRequest
    ) throws -> SyncPendingResult<(Data, URLResponse)> {
        .started { throw MemoSyncError.invalidResponse }
    }

    func startUpload(
        _ request: URLRequest,
        from fileURL: URL
    ) throws -> SyncPendingResult<(Data, URLResponse)> {
        let send = upload
        return .started { try await send(request, fileURL) }
    }

    func startDownload(
        _ request: URLRequest
    ) throws -> SyncPendingResult<(URL, URLResponse)> {
        let send = download
        return .started {
            let (url, response) = try await send(request)
            let owned = try SyncNetworkTempFile.adopt(url)
            return (owned, response)
        }
    }
}

/// Session-scoped network executor for sync components. Every actual request
/// start is synchronously linearized with lease invalidation: after
/// invalidation linearized, no request can start at all; a request that
/// already started may finish, but its result is re-checked before any
/// durable effect commits.
public struct SyncSessionNetwork: Sendable {
    public let lease: SyncSessionLease
    private let dataStarter: SyncRequestStarter
    private let fileStarter: SyncRequestStarter

    public init(lease: SyncSessionLease, starter: SyncRequestStarter) {
        self.lease = lease
        self.dataStarter = starter
        self.fileStarter = starter
    }

    public init(
        lease: SyncSessionLease,
        dataTransport: HTTPTransport,
        fileTransport: AttachmentFileTransport
    ) {
        let dataStarter = (dataTransport as? SyncRequestStarter)
            ?? SyncRequestStarterAdapter(dataTransport: dataTransport, fileTransport: fileTransport)
        let fileStarter = (fileTransport as? SyncRequestStarter)
            ?? SyncRequestStarterAdapter(dataTransport: dataTransport, fileTransport: fileTransport)
        self.lease = lease
        self.dataStarter = dataStarter
        self.fileStarter = fileStarter
    }

    /// File-transfer-only executor (downloaders).
    public init(lease: SyncSessionLease, fileTransport: AttachmentFileTransport) {
        let starter = (fileTransport as? SyncRequestStarter)
            ?? SyncFileRequestStarterAdapter(fileTransport: fileTransport)
        self.lease = lease
        self.dataStarter = starter
        self.fileStarter = starter
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let pending = try lease.withValidity { try dataStarter.startData(request) }
        return try await pending.value()
    }

    public func uploadFile(
        for request: URLRequest,
        from fileURL: URL
    ) async throws -> (Data, URLResponse) {
        let pending = try lease.withValidity { try fileStarter.startUpload(request, from: fileURL) }
        return try await pending.value()
    }

    public func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse) {
        let pending = try lease.withValidity { try fileStarter.startDownload(request) }
        return try await pending.value()
    }
}

// MARK: - SupabaseSyncTransport

/// Realm-pinned transport for Supabase sync traffic.
///
/// The `URLSession` production path refuses redirects at the task delegate
/// before the follow-up request (and its bearer header) can be created, and
/// starts each task synchronously so `SyncSessionNetwork` can linearize the
/// start with lease invalidation. The wrapped-inner variant is the test seam.
public final class SupabaseSyncTransport: HTTPTransport, AttachmentFileTransport, SyncRequestStarter, @unchecked Sendable {
    public let origin: SyncRealmOrigin

    private let starters: Starters
    private let session: URLSession?

    private struct Starters {
        var data: @Sendable (URLRequest) throws -> SyncPendingResult<(Data, URLResponse)>
        var upload: @Sendable (URLRequest, URL) throws -> SyncPendingResult<(Data, URLResponse)>
        var download: @Sendable (URLRequest) throws -> SyncPendingResult<(URL, URLResponse)>
    }

    /// Production initializer: dedicated session that refuses redirects and
    /// starts each task synchronously inside the caller's lease gate.
    public init(origin: SyncRealmOrigin) {
        self.origin = origin
        let delegate = RedirectRefusingDelegate()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        delegate.retainSelf = delegate
        self.session = session
        self.starters = Starters(
            data: { request in
                let pending = SyncPendingResult<(Data, URLResponse)>()
                let task = session.dataTask(with: request) { data, response, error in
                    SupabaseSyncTransport.settle(
                        pending,
                        data: data,
                        response: response,
                        error: error,
                        fileURL: nil
                    )
                }
                task.resume()
                return pending
            },
            upload: { request, fileURL in
                let pending = SyncPendingResult<(Data, URLResponse)>()
                let task = session.uploadTask(with: request, fromFile: fileURL) { data, response, error in
                    SupabaseSyncTransport.settle(
                        pending,
                        data: data,
                        response: response,
                        error: error,
                        fileURL: nil
                    )
                }
                task.resume()
                return pending
            },
            download: { request in
                let pending = SyncPendingResult<(URL, URLResponse)>()
                let task = session.downloadTask(with: request) { url, response, error in
                    SupabaseSyncTransport.settle(
                        pending,
                        data: nil,
                        response: response,
                        error: error,
                        fileURL: url
                    )
                }
                task.resume()
                return pending
            }
        )
    }

    /// Test seam: wraps injected async fakes behind the same pre-send guards.
    /// Redirects in faked results are refused outright.
    public convenience init(
        origin: SyncRealmOrigin,
        wrapping dataTransport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        upload: @escaping @Sendable (URLRequest, URL) async throws -> (Data, URLResponse) = { _, _ in
            throw AttachmentSyncError.network
        },
        download: @escaping @Sendable (URLRequest) async throws -> (URL, URLResponse) = { _ in
            throw AttachmentSyncError.network
        }
    ) {
        self.init(origin: origin, raw: (dataTransport, upload, download))
    }

    /// Convenience seam for fakes that implement the narrow protocols.
    public convenience init(origin: SyncRealmOrigin, transport: HTTPTransport) {
        self.init(origin: origin, wrapping: { try await transport.data(for: $0) })
    }

    private typealias RawHandlers = (
        data: @Sendable (URLRequest) async throws -> (Data, URLResponse),
        upload: @Sendable (URLRequest, URL) async throws -> (Data, URLResponse),
        download: @Sendable (URLRequest) async throws -> (URL, URLResponse)
    )

    private init(origin: SyncRealmOrigin, raw: RawHandlers) {
        self.origin = origin
        self.session = nil
        self.starters = Starters(
            data: { request in
                .started {
                    let (data, response) = try await raw.data(request)
                    try Self.assertNotRedirect(response)
                    return (data, response)
                }
            },
            upload: { request, fileURL in
                .started {
                    let (data, response) = try await raw.upload(request, fileURL)
                    try Self.assertNotRedirect(response)
                    return (data, response)
                }
            },
            download: { request in
                .started {
                    let (url, response) = try await raw.download(request)
                    try Self.assertNotRedirect(response)
                    // Same ownership contract as the production callback.
                    let owned = try SyncNetworkTempFile.adopt(url)
                    return (owned, response)
                }
            }
        )
    }

    /// One redirect-refusing transport per origin. Sync components default to
    /// this instead of `HTTPTransports.shared` / `URLSession.shared`, so sync
    /// bearer tokens can never follow a redirect off the realm origin.
    public static func shared(for origin: SyncRealmOrigin) -> SupabaseSyncTransport {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = cache[origin.normalized] { return existing }
        let created = SupabaseSyncTransport(origin: origin)
        cache[origin.normalized] = created
        return created
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: SupabaseSyncTransport] = [:]

    // MARK: SyncRequestStarter (synchronous start)

    public func startData(
        _ request: URLRequest
    ) throws -> SyncPendingResult<(Data, URLResponse)> {
        try prevalidate(request)
        return try starters.data(request)
    }

    public func startUpload(
        _ request: URLRequest,
        from fileURL: URL
    ) throws -> SyncPendingResult<(Data, URLResponse)> {
        try prevalidate(request)
        return try starters.upload(request, fileURL)
    }

    public func startDownload(
        _ request: URLRequest
    ) throws -> SyncPendingResult<(URL, URLResponse)> {
        try prevalidate(request)
        return try starters.download(request)
    }

    // MARK: Legacy async seams (delegate to the synchronous starts)

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await startData(request).value()
    }

    public func uploadFile(
        for request: URLRequest,
        from fileURL: URL
    ) async throws -> (Data, URLResponse) {
        try await startUpload(request, from: fileURL).value()
    }

    public func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await startDownload(request).value()
    }

    /// Runs before any header-bearing request leaves this process.
    private func prevalidate(_ request: URLRequest) throws {
        guard let url = request.url, origin.matchesRoot(url) else {
            throw SyncRealmError.realmMismatch
        }
    }

    /// The production delegate refuses to follow redirects; fakes must not be
    /// able to hand a 3xx back as a consumable success either.
    private static func assertNotRedirect(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, (300...399).contains(http.statusCode) {
            throw SyncRealmError.redirectRefused
        }
    }

    private static func settle(
        _ pending: SyncPendingResult<(Data, URLResponse)>,
        data: Data?,
        response: URLResponse?,
        error: Error?,
        fileURL: URL?
    ) {
        if let error {
            pending.fulfill(.failure(error))
            return
        }
        guard let response else {
            pending.fulfill(.failure(MemoSyncError.invalidResponse))
            return
        }
        do {
            try assertNotRedirect(response)
        } catch {
            pending.fulfill(.failure(error))
            return
        }
        if let data {
            pending.fulfill(.success((data, response)))
        } else {
            pending.fulfill(.failure(MemoSyncError.invalidResponse))
        }
    }

    private static func settle(
        _ pending: SyncPendingResult<(URL, URLResponse)>,
        data: Data?,
        response: URLResponse?,
        error: Error?,
        fileURL: URL?
    ) {
        if let error {
            pending.fulfill(.failure(error))
            return
        }
        guard let response, let fileURL else {
            pending.fulfill(.failure(MemoSyncError.invalidResponse))
            return
        }
        do {
            try assertNotRedirect(response)
        } catch {
            pending.fulfill(.failure(error))
            return
        }
        do {
            // The download callback owns `fileURL` only while it runs: retain
            // the bytes in an owned transient copy BEFORE publishing.
            let owned = try SyncNetworkTempFile.adopt(fileURL)
            pending.fulfill(.success((owned, response)))
        } catch {
            pending.fulfill(.failure(error))
        }
    }
}

// MARK: - Redirect refusal

/// Cancels the redirect handshake instead of forwarding the original request
/// (with its `Authorization`/`apikey` headers) to the redirect target.
private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
    /// Keeps the delegate alive for the URLSession's lifetime (URLSession
    /// retains its delegate weakly on some platform versions).
    var retainSelf: RedirectRefusingDelegate?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Refuse BEFORE the follow-up request is formed: no bearer forwarding.
        completionHandler(nil)
    }
}

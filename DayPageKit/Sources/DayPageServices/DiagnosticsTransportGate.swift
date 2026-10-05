import Foundation

/// The final network gate, after Sentry's cache/flush machinery. Each outer
/// session is bound to one generation. Revocation cancels registered forwarding
/// tasks before SDK.close can flush, and old sessions cannot acquire a new lease.
public final class DiagnosticsTransportGate: @unchecked Sendable {
    public static let shared = DiagnosticsTransportGate()
    private static let generationHeader = "X-DayPage-Diagnostics-Generation"
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: WeakGate] = [:]

    private final class WeakGate {
        weak var value: DiagnosticsTransportGate?
        init(_ value: DiagnosticsTransportGate) { self.value = value }
    }
    private let lock = NSRecursiveLock()
    private var generation: String?
    private var endpoint: URL?
    private var authHeader: String?
    private var consent: (@Sendable () -> Bool)?
    private var inner: URLSession?
    private var tasks: [UUID: URLSessionDataTask] = [:]
    private let innerConfiguration: @Sendable () -> URLSessionConfiguration
    enum ForwardingTaskEvent: Sendable {
        case registered(UUID)
        case completed(UUID)
    }
    private let taskObserver: (@Sendable (ForwardingTaskEvent) -> Void)?
    private let redirects = NoRedirects()

    public init() {
        innerConfiguration = { URLSessionConfiguration.ephemeral }
        taskObserver = nil
    }

    // Test-only injection: actual URLSession forwarding, without external IO.
    init(innerConfiguration: @escaping @Sendable () -> URLSessionConfiguration,
         taskObserver: (@Sendable (ForwardingTaskEvent) -> Void)? = nil) {
        self.innerConfiguration = innerConfiguration
        self.taskObserver = taskObserver
    }

    /// Call from the serialized SDK owner. This deliberately does not invalidate
    /// old outer sessions: SDK.close may still create tasks on them, which must
    /// be refused by the protocol rather than raise an invalid-session exception.
    public func makeSession(endpoint: URL, authHeader: String, consent: @escaping @Sendable () -> Bool) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        revoke()
        let token = UUID().uuidString
        generation = token
        self.endpoint = endpoint
        self.authHeader = authHeader
        self.consent = consent
        let configuration = innerConfiguration()
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = nil
        inner = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
        Self.registryLock.lock()
        Self.registry[token] = WeakGate(self)
        Self.registryLock.unlock()
        let outer = URLSessionConfiguration.ephemeral
        outer.protocolClasses = [DiagnosticsURLProtocol.self]
        outer.httpAdditionalHeaders = [Self.generationHeader: token]
        outer.httpCookieStorage = nil
        outer.urlCredentialStorage = nil
        outer.urlCache = nil
        outer.httpShouldSetCookies = false
        return URLSession(configuration: outer)
    }

    /// Synchronous cutoff. Request registration/resume and this cancellation are
    /// serialized under the same lock; no queued upload may resume after cutoff.
    public func revoke() {
        lock.lock(); defer { lock.unlock() }
        if let generation {
            Self.registryLock.lock()
            Self.registry.removeValue(forKey: generation)
            Self.registryLock.unlock()
        }
        generation = nil
        consent = nil
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        inner?.invalidateAndCancel()
        inner = nil
        endpoint = nil
        authHeader = nil
    }

    private static func gate(for token: String) -> DiagnosticsTransportGate? {
        registryLock.lock(); defer { registryLock.unlock() }
        return registry[token]?.value
    }

    private func forward(_ loader: DiagnosticsURLProtocol, token: String) {
        lock.lock()
        let liveConsent = consent
        lock.unlock()
        // Never acquire the consent-store lock while holding the transport lock:
        // mutation synchronously calls revoke in the reverse direction.
        guard liveConsent?() == true,
              loader.request.httpMethod == "POST", let body = Self.body(of: loader.request),
              let safeBody = DiagnosticsEnvelopeSanitizer.sanitize(body, contentEncoding: loader.request.value(forHTTPHeaderField: "Content-Encoding")) else {
            loader.reject(); return
        }
        DiagnosticsConsent.withSerializedTransition {
            // Parsing runs outside the transition lock. The FINAL consent re-read
            // and registration/resume run inside it, in consent → gate lock order.
            guard liveConsent?() == true else { loader.reject(); return }
            lock.lock(); defer { lock.unlock() }
            guard token == generation, let endpoint, loader.request.url == endpoint,
                  endpoint.scheme == "https", endpoint.query == nil, endpoint.user == nil, endpoint.password == nil,
                  let inner, let authHeader else { loader.reject(); return }
            var clean = URLRequest(url: endpoint)
            clean.httpMethod = "POST"
            clean.timeoutInterval = 15
            clean.httpBody = safeBody
            clean.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
            clean.setValue(authHeader, forHTTPHeaderField: "X-Sentry-Auth")
            clean.setValue("sentry.cocoa/8.58.4", forHTTPHeaderField: "User-Agent")
            // Send canonical identity encoding after the bounded gzip decode.
            let id = UUID()
            let taskObserver = self.taskObserver
            let task = inner.dataTask(with: clean) { [weak self, weak loader] _, response, error in
                // Test accounting follows the actual inner task completion,
                // including early returns after generation revocation.
                defer { taskObserver?(.completed(id)) }
                guard let self else { loader?.reject(); return }
                self.lock.lock()
                self.tasks.removeValue(forKey: id)
                let allowed = self.generation == token
                self.lock.unlock()
                guard allowed else { loader?.reject(); return }
                if let error { loader?.fail(error) }
                else if let response { loader?.finish(response) }
                else { loader?.reject() }
            }
            tasks[id] = task
            loader.bind(task)
            taskObserver?(.registered(id))
            task.resume()
        }
    }

    /// Foundation can expose even SDK httpBody Data as a body stream to a
    /// URLProtocol. Consume at most the same compressed-byte limit before any
    /// forwarding. Never interpolate stream errors or content into diagnostics.
    static func body(of request: URLRequest) -> Data? {
        if let data = request.httpBody {
            return data.count <= DiagnosticsEnvelopeSanitizer.maximumBytes ? data : nil
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return result }
            guard count > 0, count <= DiagnosticsEnvelopeSanitizer.maximumBytes - result.count else { return nil }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private final class DiagnosticsURLProtocol: URLProtocol, @unchecked Sendable {
        private let taskLock = NSRecursiveLock()
        private var forwardedTask: URLSessionDataTask?
        private var stopped = false
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let token = request.value(forHTTPHeaderField: generationHeader), let gate = gate(for: token) else {
                reject(); return
            }
            gate.forward(self, token: token)
        }
        override func stopLoading() {
            taskLock.lock(); defer { taskLock.unlock() }
            stopped = true
            forwardedTask?.cancel()
            forwardedTask = nil
        }
        func bind(_ task: URLSessionDataTask) {
            taskLock.lock(); defer { taskLock.unlock() }
            if stopped { task.cancel() } else { forwardedTask = task }
        }
        func reject() { fail(URLError(.cancelled)) }
        func fail(_ error: Error) {
            taskLock.lock(); defer { taskLock.unlock() }
            guard !stopped else { return }
            stopped = true
            client?.urlProtocol(self, didFailWithError: error)
        }
        func finish(_ response: URLResponse) {
            taskLock.lock(); defer { taskLock.unlock() }
            guard !stopped else { return }
            stopped = true
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Ingestor response bodies are unnecessary and may echo rejected data.
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

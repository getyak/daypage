import Foundation
import DayPageModels
import DayPageStorage

/// Shared with synchronous store commits so revocation remains observable
/// after a hop from the coordinator to a bound store actor.
private final class ScreenshotConsentEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var version = 0
    var current: Int { lock.lock(); defer { lock.unlock() }; return version }
    func advance() { lock.lock(); version &+= 1; lock.unlock() }
}

public extension Notification.Name {
    static let screenshotCaptureDidUpdate = Notification.Name("daypage.screenshotCaptureDidUpdate")
}

/// Orchestrates durable ingest, deterministic evidence extraction, optional
/// cloud understanding, and exact memo/file reconciliation.
///
/// Every multi-step operation captures one Vault root at entry and runs every
/// store and RawStorage step against that captured root, so a Vault root switch
/// (migration, locator swap) can never split one operation across two vaults —
/// including delete/undo finalization.
public actor ScreenshotCaptureCoordinator {
    public static let shared = ScreenshotCaptureCoordinator()

    private let store: ScreenshotCaptureStore
    private let evidenceExtractor: any ScreenshotEvidenceExtracting
    private var understandingProvider: (any ScreenshotUnderstandingProvider)?
    /// Live screenshot-cloud policy re-read at request and acceptance time.
    private let cloudConsent: AIConsentChecking
    /// Test-only seam awaited inside the preflight window (after the in-flight
    /// reservation, before any provider request) to make overlapping passes
    /// deterministic. nil in production.
    private let preflightGate: (@Sendable () async -> Void)?
    /// Test-only seam awaited immediately before irreversible deletion
    /// finalization. nil in production.
    private let finalizeGate: (@Sendable () async -> Void)?
    /// Test-only seam before the awaited response commit. nil in production.
    private let resultCommitGate: (@Sendable () async -> Void)?

    /// Bumped whenever cloud processing is observed disabled or a capture's
    /// consent is revoked. Provider completions started under an older epoch
    /// are stale and get discarded instead of accepted.
    private let cloudConsentEpoch = ScreenshotConsentEpoch()
    /// In-flight provider work keyed by (resolved Vault root, capture ID) so
    /// concurrent recovery/retry passes cannot double-request, while a copied
    /// capture UUID in a different Vault processes independently.
    private struct InFlightKey: Hashable {
        let rootPath: String
        let captureID: UUID
    }
    private var inFlightUnderstanding: Set<InFlightKey> = []

    public init(
        store: ScreenshotCaptureStore = ScreenshotCaptureStore(),
        evidenceExtractor: any ScreenshotEvidenceExtracting = VisionScreenshotEvidenceExtractor(),
        understandingProvider: (any ScreenshotUnderstandingProvider)? = nil,
        cloudConsent: AIConsentChecking = LiveScreenshotCloudConsent(),
        preflightGate: (@Sendable () async -> Void)? = nil,
        finalizeGate: (@Sendable () async -> Void)? = nil,
        resultCommitGate: (@Sendable () async -> Void)? = nil
    ) {
        self.store = store
        self.evidenceExtractor = evidenceExtractor
        self.understandingProvider = understandingProvider
        self.cloudConsent = cloudConsent
        self.preflightGate = preflightGate
        self.finalizeGate = finalizeGate
        self.resultCommitGate = resultCommitGate
    }

    public func configure(understandingProvider: (any ScreenshotUnderstandingProvider)?) {
        self.understandingProvider = understandingProvider
    }

    /// Settings revoke hook (issue #928): turning screenshot cloud analysis or
    /// the master AI switch off invalidates every pending/in-flight capture
    /// epoch so late completions are discarded without waiting for a
    /// foreground event.
    public func noteCloudConsentRevoked() {
        cloudConsentEpoch.advance()
    }

    // MARK: - Vault binding

    private struct VaultBinding {
        let store: ScreenshotCaptureStore
        let vaultRoot: URL
    }

    /// Captures one Vault root and pins every store call of the operation to
    /// it. An explicit root (Today's delete/undo context) always wins.
    private func binding(vaultRoot explicitRoot: URL?) async -> VaultBinding {
        let root: URL
        if let explicitRoot {
            root = explicitRoot
        } else {
            root = await store.currentVaultRoot()
        }
        return VaultBinding(store: await store.bound(to: root), vaultRoot: root)
    }

    /// Exactly-once memo delivery keyed by the manifest's owning day string.
    /// The read-check-append runs in one actor turn against the captured root,
    /// so concurrent callers and crash replays cannot append twice.
    private func appendMemoIfNeeded(
        _ memo: Memo,
        dayString: String,
        vaultRoot: URL
    ) throws {
        guard RawStorage.isValidDayString(dayString) else { return }
        let existing = try RawStorage.read(dayString: dayString, vaultRoot: vaultRoot)
        guard !existing.contains(where: { $0.id == memo.id }) else { return }
        try RawStorage.mutate(
            dayString: dayString,
            vaultRoot: vaultRoot,
            transform: { memos in
                memos.contains(where: { $0.id == memo.id }) ? nil : memos + [memo]
            }
        )
    }

    private func screenshotMemo(for manifest: ScreenshotCaptureManifest) -> Memo {
        Memo(
            id: manifest.memoID,
            type: .photo,
            created: manifest.createdAt,
            attachments: [Memo.Attachment(file: manifest.originalPath, kind: "photo")],
            body: ""
        )
    }

    // MARK: - Ingest and recovery

    /// Saves the original and memo first, then performs only local evidence
    /// extraction. Cloud work is left queued for an app-active/background pass.
    public func ingest(
        data: Data,
        declaredContentType: String,
        source: ScreenshotCaptureSource,
        cloudAnalysisAllowed: Bool,
        stableID: UUID? = nil
    ) async throws -> ScreenshotCaptureOutcome {
        if !cloudAnalysisAllowed { cloudConsentEpoch.advance() }
        let bound = await binding(vaultRoot: nil)
        var outcome = try await bound.store.receive(
            data: data,
            declaredContentType: declaredContentType,
            source: source,
            cloudConsentAtCapture: cloudAnalysisAllowed,
            stableID: stableID
        )
        if outcome.isDuplicate {
            // Replay-safe reconciliation (share handoff / crash replays): the
            // memo UUID makes the append idempotent, so a crash between
            // manifest durability and memo append is repaired without ever
            // creating a second capture, memo, or original.
            try? appendMemoIfNeeded(
                screenshotMemo(for: outcome.manifest),
                dayString: outcome.manifest.memoDayString,
                vaultRoot: bound.vaultRoot
            )
            return outcome
        }

        let manifest = outcome.manifest
        do {
            try appendMemoIfNeeded(
                screenshotMemo(for: manifest),
                dayString: manifest.memoDayString,
                vaultRoot: bound.vaultRoot
            )
            outcome.manifest = try await bound.store.update(manifest.id) { value in
                value.phase = .ingested
                value.failureReason = nil
            }
        } catch {
            outcome.manifest = try await bound.store.update(manifest.id) { value in
                value.phase = .ingestPending
                value.failureReason = "memo-ingest-failed"
            }
            postUpdate(outcome.manifest)
            return outcome
        }

        outcome.manifest = await extractLocalEvidence(
            captureID: manifest.id,
            vaultRoot: bound.vaultRoot,
            cloudAnalysisAllowed: cloudAnalysisAllowed
        )
        postUpdate(outcome.manifest)
        return outcome
    }

    /// Foreground/background recovery pass. Adopts every phase a crash can
    /// leave behind — `stored`/`ingestPending` memo gaps, `ingested`/
    /// `extracting` evidence gaps, and `understanding` provider gaps — using
    /// the exact memo UUID so recovery is idempotent and exactly-once.
    public func processPending(cloudAnalysisAllowed: Bool) async {
        if !cloudAnalysisAllowed { cloudConsentEpoch.advance() }
        let bound = await binding(vaultRoot: nil)
        await reconcilePendingMemoIngests(
            bound: bound,
            cloudAnalysisAllowed: cloudAnalysisAllowed
        )
        guard let manifests = try? await bound.store.allManifests() else { return }
        for manifest in manifests {
            switch manifest.phase {
            case .stored, .ingestPending:
                // Memo reconciliation above is the recovery path for these.
                continue
            case .ingested, .extracting:
                guard manifest.evidence == nil || manifest.phase == .extracting else { continue }
                _ = await extractLocalEvidence(
                    captureID: manifest.id,
                    vaultRoot: bound.vaultRoot,
                    cloudAnalysisAllowed: cloudAnalysisAllowed
                )
            case .queued, .pendingNetwork, .needsConsent, .understanding:
                _ = await process(
                    captureID: manifest.id,
                    vaultRoot: bound.vaultRoot,
                    cloudAnalysisAllowed: cloudAnalysisAllowed
                )
            case .localOnly, .ready, .failed:
                continue
            }
        }
    }

    @discardableResult
    public func retry(
        captureID: UUID,
        cloudAnalysisAllowed: Bool
    ) async -> ScreenshotCaptureManifest? {
        if !cloudAnalysisAllowed { cloudConsentEpoch.advance() }
        let bound = await binding(vaultRoot: nil)
        guard var manifest = try? await bound.store.manifest(for: captureID) else { return nil }
        // Evidence extraction changes phase. Repair the durable memo gap
        // first, or a crash-interrupted capture would become terminal without
        // ever delivering its memo to Today.
        if manifest.phase == .ingestPending || manifest.phase == .stored {
            await reconcilePendingMemoIngests(
                bound: bound,
                cloudAnalysisAllowed: cloudAnalysisAllowed
            )
            guard let recovered = try? await bound.store.manifest(for: captureID) else { return nil }
            guard recovered.phase != .ingestPending, recovered.phase != .stored else { return recovered }
            manifest = recovered
        }
        if manifest.evidence == nil {
            manifest = await extractLocalEvidence(
                captureID: captureID,
                vaultRoot: bound.vaultRoot,
                cloudAnalysisAllowed: cloudAnalysisAllowed
            )
        }
        return await process(
            captureID: captureID,
            vaultRoot: bound.vaultRoot,
            cloudAnalysisAllowed: cloudAnalysisAllowed
        )
    }

    /// Groups manifests by the same preferred-time-zone day contract as
    /// RawStorage and Today, so a preferred-zone setting change moves memos
    /// and their manifests together.
    public func manifests(for date: Date) async -> [ScreenshotCaptureManifest] {
        let bound = await binding(vaultRoot: nil)
        guard let manifests = try? await bound.store.allManifests() else { return [] }
        let targetDay = RawStorage.dayString(for: date)
        return manifests.filter { $0.memoDayString == targetDay }
    }

    public func manifest(forMemoID memoID: UUID) async -> ScreenshotCaptureManifest? {
        try? await store.manifest(forMemoID: memoID)
    }

    public func updateUserMeaning(captureID: UUID, body: String) async throws {
        let bound = await binding(vaultRoot: nil)
        let manifest = try await bound.store.manifest(for: captureID)
        guard RawStorage.isValidDayString(manifest.memoDayString) else { return }
        try RawStorage.mutate(
            dayString: manifest.memoDayString,
            vaultRoot: bound.vaultRoot,
            transform: { memos in
                guard let index = memos.firstIndex(where: { $0.id == manifest.memoID }) else { return nil }
                var updated = memos
                updated[index].body = body
                return updated
            }
        )
        postUpdate(manifest)
    }

    public func keepLocal(captureID: UUID) async throws {
        cloudConsentEpoch.advance()
        let bound = await binding(vaultRoot: nil)
        let manifest = try await bound.store.update(captureID) { value in
            value.cloudConsentAtCapture = false
            value.phase = .localOnly
            value.failureReason = nil
        }
        postUpdate(manifest)
    }

    public func delete(captureID: UUID, vaultRoot: URL? = nil) async throws {
        let bound = await binding(vaultRoot: vaultRoot)
        let manifest = try await bound.store.manifest(for: captureID)
        if RawStorage.isValidDayString(manifest.memoDayString) {
            try RawStorage.mutate(
                dayString: manifest.memoDayString,
                vaultRoot: bound.vaultRoot,
                transform: { memos in
                    let updated = memos.filter { $0.id != manifest.memoID }
                    return updated.count == memos.count ? nil : updated
                }
            )
        }
        try await bound.store.deleteFiles(for: captureID)
        NotificationCenter.default.post(name: .screenshotCaptureDidUpdate, object: captureID)
    }

    /// Finalizes TodayView's undoable deletion. Files are removed only when
    /// the raw memo is still absent after the undo window, preventing an
    /// optimistic UI delete or failed rewrite from destroying the original.
    /// `vaultRoot` binds the whole check-and-delete to the vault captured when
    /// the deletion started; when nil the store's current vault is captured.
    /// The memo check and the file deletion always run against one and the
    /// same captured vault.
    public func finalizeDeletionIfMemoMissing(
        captureID: UUID,
        vaultRoot: URL? = nil
    ) async throws {
        let bound = await binding(vaultRoot: vaultRoot)
        let manifest = try await bound.store.manifest(for: captureID)
        // Fail safe: without a usable owning day key the memo cannot be
        // verified, so the files are kept.
        guard RawStorage.isValidDayString(manifest.memoDayString) else { return }
        let memos = try RawStorage.read(
            dayString: manifest.memoDayString,
            vaultRoot: bound.vaultRoot
        )
        guard !memos.contains(where: { $0.id == manifest.memoID }) else { return }
        // Undo may be accepted while finalization runs: the optional gate is
        // awaited BEFORE the irreversible step, then cancellation is honored
        // and the memo absence is re-checked, so an accepted restore can never
        // be followed by a file deletion that destroys its screenshot.
        if let finalizeGate { await finalizeGate() }
        guard !Task.isCancelled else { return }
        let refreshed = (try? RawStorage.read(
            dayString: manifest.memoDayString,
            vaultRoot: bound.vaultRoot
        )) ?? []
        guard !refreshed.contains(where: { $0.id == manifest.memoID }) else { return }
        try await bound.store.deleteFiles(for: captureID)
        NotificationCenter.default.post(name: .screenshotCaptureDidUpdate, object: captureID)
    }

    // MARK: - Local and provider work

    private func extractLocalEvidence(
        captureID: UUID,
        vaultRoot: URL,
        cloudAnalysisAllowed: Bool
    ) async -> ScreenshotCaptureManifest {
        let store = await store.bound(to: vaultRoot)
        do {
            _ = try await store.update(captureID) { value in
                value.phase = .extracting
                value.failureReason = nil
            }
            let data = try await store.originalData(for: captureID)
            let evidence = try await evidenceExtractor.extract(from: data)
            return try await store.update(captureID) { value in
                value.evidence = evidence
                if cloudAnalysisAllowed && evidence.riskIndicators.isEmpty {
                    value.phase = .queued
                } else {
                    value.phase = .localOnly
                }
                value.failureReason = evidence.riskIndicators.isEmpty
                    ? nil
                    : "sensitive-content-review-required"
            }
        } catch {
            return (try? await store.update(captureID) { value in
                value.phase = .failed
                value.failureReason = "local-evidence-failed"
            }) ?? fallbackManifest(captureID: captureID)
        }
    }

    private func process(
        captureID: UUID,
        vaultRoot: URL,
        cloudAnalysisAllowed: Bool
    ) async -> ScreenshotCaptureManifest? {
        // Single-flight reservation BEFORE the first awaited preflight step:
        // an actor turn is atomic up to the first await, so two overlapping
        // contenders can never both pass the check. The key includes the
        // resolved Vault root so a copied capture UUID in another vault is
        // not suppressed.
        let key = InFlightKey(
            rootPath: URL(fileURLWithPath: vaultRoot.path)
                .resolvingSymlinksInPath().standardizedFileURL.path,
            captureID: captureID
        )
        guard !inFlightUnderstanding.contains(key) else {
            return try? await store.bound(to: vaultRoot).manifest(for: captureID)
        }
        inFlightUnderstanding.insert(key)
        defer { inFlightUnderstanding.remove(key) }
        let epochAtRequest = cloudConsentEpoch.current

        let store = await store.bound(to: vaultRoot)
        guard cloudAnalysisAllowed else {
            let value = try? await store.update(captureID) { manifest in
                if manifest.phase != .ready {
                    manifest.phase = .localOnly
                    manifest.failureReason = nil
                }
            }
            if let value { postUpdate(value) }
            return value
        }
        guard let provider = understandingProvider else {
            let value = try? await store.update(captureID) { manifest in
                manifest.phase = .needsConsent
                manifest.failureReason = "provider-not-configured"
            }
            if let value { postUpdate(value) }
            return value
        }

        do {
            var manifest = try await store.manifest(for: captureID)
            guard manifest.phase != .ingestPending, manifest.phase != .stored else {
                return manifest
            }
            // Durable per-capture consent: a revoked capture is never re-sent.
            guard manifest.cloudConsentAtCapture else {
                manifest = try await store.update(captureID) { value in
                    value.phase = .localOnly
                    value.failureReason = nil
                }
                postUpdate(manifest)
                return manifest
            }
            // Local evidence is a REQUIRED prerequisite for any cloud request
            // (root review finding 7): a capture whose extraction failed has no
            // evidence and must never be sent. The durable local failure stays
            // retryable and nothing is overwritten here.
            guard let evidence = manifest.evidence else {
                return manifest
            }
            guard evidence.riskIndicators.isEmpty else {
                manifest = try await store.update(captureID) { value in
                    value.phase = .localOnly
                    value.failureReason = "sensitive-content-review-required"
                }
                postUpdate(manifest)
                return manifest
            }
            let original = try await store.originalData(for: captureID)
            let derivative = try ScreenshotAnalysisImage.makeJPEG(from: original)
            manifest = try await store.persistAnalysisDerivative(derivative, for: captureID)
            manifest = try await store.update(captureID) { value in
                guard value.cloudConsentAtCapture, value.phase != .localOnly, value.phase != .ready else { return }
                value.phase = .understanding
                value.failureReason = nil
            }
            postUpdate(manifest)

            // Live policy re-check immediately before the request: a pass that
            // captured cloudAnalysisAllowed earlier must not send after the
            // user turned the switches off (issue #928).
            if let preflightGate { await preflightGate() }
            let current = try await store.manifest(for: captureID)
            guard cloudConsentEpoch.current == epochAtRequest,
                  current.phase == .understanding, current.cloudConsentAtCapture,
                  let requestEvidence = current.evidence, requestEvidence.riskIndicators.isEmpty else {
                let value = try await store.update(captureID) { value in
                    if value.phase == .understanding { value.phase = .localOnly; value.failureReason = nil }
                }
                postUpdate(value)
                return value
            }
            // No await remains between this live check and provider invocation.
            try cloudConsent.authorize()
            let understanding: ScreenshotUnderstandingResult
            do {
                let request = ScreenshotUnderstandingRequest(
                    captureID: captureID,
                    imageData: derivative,
                    imageMIMEType: "image/jpeg",
                    evidence: requestEvidence,
                    localeIdentifier: Locale.current.identifier
                )
                understanding = try await provider.understand(request)
            } catch {
                throw error
            }

            // Stale-completion gate: consent may have been revoked (keep-local
            // or a global cloud disable) while the request was in flight. A
            // late response is discarded, never accepted — including when the
            // live setting is off without any foreground event.
            if let resultCommitGate { await resultCommitGate() }
            let epoch = cloudConsentEpoch
            let consent = cloudConsent
            manifest = try await store.update(captureID) { value in
                // Check the latest durable state INSIDE the atomic store
                // mutation, after every asynchronous response/commit boundary.
                guard epoch.current == epochAtRequest,
                      (try? consent.authorize()) != nil,
                      value.phase == .understanding, value.cloudConsentAtCapture else {
                    if value.phase == .understanding { value.phase = .localOnly; value.failureReason = nil }
                    return
                }
                value.understanding = understanding
                value.phase = .ready
                value.failureReason = nil
            }
            postUpdate(manifest)
            return manifest
        } catch {
            let isNetwork = Self.isRetryable(error)
            let value = try? await store.update(captureID) { manifest in
                // Late failures can never overwrite durable localOnly/deleted
                // state — only a still-understanding capture may be marked.
                guard manifest.phase == .understanding else { return }
                if error is AIAuthorizationError {
                    manifest.phase = .localOnly
                    manifest.failureReason = nil
                } else {
                    manifest.phase = isNetwork ? .pendingNetwork : .failed
                    manifest.failureReason = isNetwork ? "network-unavailable" : "understanding-failed"
                }
            }
            if let value { postUpdate(value) }
            return value
        }
    }

    /// Recovers every durable capture whose memo ingest may be incomplete —
    /// including the `stored` state a crash between manifest durability and
    /// memo append leaves behind. The memo check uses the exact memo UUID so a
    /// replay after a crash between append and phase update never duplicates.
    private func reconcilePendingMemoIngests(
        bound: VaultBinding,
        cloudAnalysisAllowed: Bool
    ) async {
        guard let manifests = try? await bound.store.allManifests() else { return }
        for manifest in manifests where manifest.phase == .stored || manifest.phase == .ingestPending {
            // A legacy sidecar whose owning day cannot be resolved (missing or
            // ambiguous identity) keeps its interrupted state: never marked
            // ingested/queued without the memo append actually landing.
            guard RawStorage.isValidDayString(manifest.memoDayString) else { continue }
            do {
                try appendMemoIfNeeded(
                    screenshotMemo(for: manifest),
                    dayString: manifest.memoDayString,
                    vaultRoot: bound.vaultRoot
                )
                // Verify the memo really exists before advancing the phase.
                let memos = try RawStorage.read(
                    dayString: manifest.memoDayString,
                    vaultRoot: bound.vaultRoot
                )
                guard memos.contains(where: { $0.id == manifest.memoID }) else { continue }
                if manifest.evidence == nil {
                    _ = await extractLocalEvidence(
                        captureID: manifest.id,
                        vaultRoot: bound.vaultRoot,
                        cloudAnalysisAllowed: cloudAnalysisAllowed
                    )
                } else {
                    _ = try await bound.store.update(manifest.id) { value in
                        if cloudAnalysisAllowed && value.evidence?.riskIndicators.isEmpty != false {
                            value.phase = .queued
                        } else {
                            value.phase = .localOnly
                        }
                        value.failureReason = nil
                    }
                }
            } catch {
                // The manifest and original remain durable for the next pass.
                continue
            }
        }
    }

    private func postUpdate(_ manifest: ScreenshotCaptureManifest) {
        NotificationCenter.default.post(name: .screenshotCaptureDidUpdate, object: manifest.id)
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case ScreenshotUnderstandingProviderError.httpStatus(let status) = error {
            return status == 408 || status == 429 || (500...599).contains(status)
        }
        return false
    }

    private func fallbackManifest(captureID: UUID) -> ScreenshotCaptureManifest {
        let now = Date()
        return ScreenshotCaptureManifest(
            id: captureID,
            memoID: UUID(),
            memoDayString: "",
            createdAt: now,
            updatedAt: now,
            source: .appImport,
            phase: .failed,
            originalPath: "",
            contentType: "",
            sha256: "",
            originalByteCount: 0,
            pixelWidth: 0,
            pixelHeight: 0,
            cloudConsentAtCapture: false,
            failureReason: "manifest-unavailable"
        )
    }
}

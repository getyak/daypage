import AppIntents
import CryptoKit
import Foundation
import WidgetKit
#if canImport(UIKit) && !EXTENSION
import UIKit
#endif
#if !EXTENSION
import DayPageModels
import DayPageStorage
#endif

// MARK: - Redacted proposal entity

/// The only proposal representation exposed to Siri, Spotlight, Shortcuts and
/// widgets. The app writes these summaries to its App Group after applying the
/// proposal's lock-screen redaction policy; payloads and rationale never cross
/// this boundary.
struct SystemActionProposalEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "DayPage 动作提案",
        numericFormat: "\(placeholder: .int) 条 DayPage 动作提案"
    )
    static let defaultQuery = SystemActionProposalEntityQuery()

    let id: String
    let displayTitle: String
    let kind: String
    let state: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayTitle)",
            subtitle: "\(Self.localizedKind(kind))",
            image: .init(systemName: Self.symbol(kind))
        )
    }

    private static func localizedKind(_ kind: String) -> String {
        switch kind {
        case "calendar_event": return NSLocalizedString("日历", comment: "")
        case "reminder": return NSLocalizedString("提醒事项", comment: "")
        case "contact_draft": return NSLocalizedString("联系人", comment: "")
        case "notification": return NSLocalizedString("通知", comment: "")
        case "route": return NSLocalizedString("路线", comment: "")
        case "capture": return NSLocalizedString("采集", comment: "")
        case "focus_session": return NSLocalizedString("专注", comment: "")
        case "moment": return "Moment"
        case "local_context_attachment": return NSLocalizedString("本地上下文", comment: "")
        default: return NSLocalizedString("系统动作", comment: "")
        }
    }

    private static func symbol(_ kind: String) -> String {
        switch kind {
        case "calendar_event": return "calendar"
        case "reminder": return "checklist"
        case "contact_draft": return "person.crop.circle.badge.plus"
        case "notification": return "bell"
        case "route": return "map"
        case "capture": return "viewfinder"
        case "focus_session": return "timer"
        case "moment": return "sparkles.rectangle.stack"
        default: return "wand.and.stars"
        }
    }
}

struct SystemActionProposalEntityQuery: EntityStringQuery {
    func entities(for identifiers: [SystemActionProposalEntity.ID]) async throws -> [SystemActionProposalEntity] {
        let requested = Set(identifiers)
        return SystemActionSharedSummaryStore.pendingEntities().filter { requested.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SystemActionProposalEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SystemActionSharedSummaryStore.pendingEntities() }
        return SystemActionSharedSummaryStore.pendingEntities().filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
                || $0.kind.localizedCaseInsensitiveContains(query)
        }
    }

    func suggestedEntities() async throws -> [SystemActionProposalEntity] {
        Array(SystemActionSharedSummaryStore.pendingEntities().prefix(8))
    }
}

/// App-group schema intentionally stays tiny and versioned. Main-app UI is the
/// only writer. Corrupt, future-version or oversized snapshots fail closed.
enum SystemActionSharedSummaryStore {
    static let appGroupIdentifier = appGroupIdentifier(for: Bundle.main.bundleIdentifier)

    /// Simulator preferences can resolve named suites without a usable App
    /// Group entitlement. Dedicated QA identities must never name the user's suite.
    static func appGroupIdentifier(for bundleIdentifier: String?) -> String {
        #if DEBUG
        switch bundleIdentifier {
        case "com.daypage.app.qa-unit", "com.daypage.app.qa-unit.DayPageWidget":
            return "group.com.daypage.qa-unit"
        case "com.daypage.app.qa-ui", "com.daypage.app.qa-ui.DayPageWidget":
            return "group.com.daypage.qa-ui"
        default: break
        }
        #endif
        return "group.com.daypage"
    }
    static let snapshotKey = "system-actions.redacted-summaries.v1"
    static let openCenterRequestKey = "system-actions.open-center-request.v1"
    static let focusDraftRequestKey = "system-actions.focus-draft-request.v1"
    static let focusControlRequestKey = "system-actions.focus-control-request.v1"
    static let shareInboxHandoffKey = "system-actions.share-inbox-handoff.v1"
    static let widgetKind = "com.daypage.widget.system-actions"
    static let spotlightDomainIdentifier = "com.daypage.system-actions"
    static let maximumSnapshotBytes = 64 * 1_024

    struct Snapshot: Codable {
        let schemaVersion: Int
        let generatedAt: Date
        let proposals: [Summary]
    }

    struct Summary: Codable {
        let id: String
        let redactedTitle: String
        let kind: String
        let state: String
    }

    struct FocusDraftRequest: Codable, Equatable {
        let schemaVersion: Int
        let title: String
        let durationMinutes: Int
    }

    enum FocusControlOperation: String, Codable, Equatable {
        case pause
        case resume
        case end
    }

    /// A one-shot command from a Live Activity extension to the foreground
    /// app. The extension updates the visible activity immediately, while the
    /// app owns cancellation/re-arming of notification and AlarmKit surfaces.
    struct FocusControlRequest: Codable, Equatable {
        let schemaVersion: Int
        let actionID: UUID
        let operation: FocusControlOperation
        /// Captured by the extension before it updates the Live Activity. The
        /// app must not infer this after a resume update, because the extension
        /// has already cleared the paused content state by then.
        let remainingSeconds: Int?
        let requestedAt: Date
    }

    /// Reference-only bridge owned jointly with #876. The Share Extension
    /// retains raw ingress truth; this envelope can only create a reviewable
    /// capture proposal and cannot carry bytes, OCR, URLs, or executable text.
    struct ShareInboxEnvelope: Codable, Equatable, Identifiable {
        let schemaVersion: Int
        let id: UUID
        let captureReference: String
        let captureKind: String
        let boundedTitle: String
        let createdAt: Date
        let attachesToSource: Bool
    }

    static func pendingEntities() -> [SystemActionProposalEntity] {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = defaults.data(forKey: snapshotKey),
              data.count <= maximumSnapshotBytes,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.schemaVersion == 1 else {
            return []
        }
        return snapshot.proposals
            .filter { $0.state == "pending_review" || $0.state == "needs_review" }
            .prefix(32)
            .map {
                SystemActionProposalEntity(
                    id: $0.id,
                    displayTitle: $0.redactedTitle.isEmpty
                        ? NSLocalizedString("待处理的系统动作", comment: "")
                        : $0.redactedTitle,
                    kind: $0.kind,
                    state: $0.state
                )
            }
    }

    /// Extension-safe one-shot navigation bridge. ControlWidget AppIntents
    /// cannot call UIApplication.open, so they leave only a bounded proposal
    /// UUID (or an empty center request) for the foreground app to consume.
    static func requestOpenCenter(proposalID: String?) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        let boundedID = proposalID.flatMap(UUID.init(uuidString:))?.uuidString.lowercased() ?? ""
        defaults.set(boundedID, forKey: openCenterRequestKey)
    }

    static func consumeOpenCenterRequest() -> (requested: Bool, proposalID: UUID?) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              defaults.object(forKey: openCenterRequestKey) != nil else {
            return (false, nil)
        }
        let value = defaults.string(forKey: openCenterRequestKey)
        defaults.removeObject(forKey: openCenterRequestKey)
        return (true, value.flatMap(UUID.init(uuidString:)))
    }

    static func requestFocusDraft(
        title: String,
        durationMinutes: Int,
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)
    ) {
        guard let defaults else { return }
        let boundedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .systemActionPrefixUTF8Bytes(160)
        let request = FocusDraftRequest(
            schemaVersion: 1,
            title: boundedTitle.isEmpty ? NSLocalizedString("专注", comment: "") : boundedTitle,
            durationMinutes: min(max(durationMinutes, 1), 1_440)
        )
        guard let data = try? JSONEncoder().encode(request), data.count <= 1_024 else { return }
        defaults.set(data, forKey: focusDraftRequestKey)
    }

    static func consumeFocusDraftRequest(
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)
    ) -> FocusDraftRequest? {
        guard let defaults else { return nil }
        defer { defaults.removeObject(forKey: focusDraftRequestKey) }
        guard let data = defaults.data(forKey: focusDraftRequestKey),
              data.count <= 1_024,
              let request = try? JSONDecoder().decode(FocusDraftRequest.self, from: data),
              request.schemaVersion == 1,
              !request.title.isEmpty,
              request.title.utf8.count <= 160,
              (1...1_440).contains(request.durationMinutes) else { return nil }
        return request
    }

    static func requestFocusControl(
        actionID: UUID,
        operation: FocusControlOperation,
        remainingSeconds: Int? = nil,
        requestedAt: Date = Date(),
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)
    ) {
        guard let defaults else { return }
        let request = FocusControlRequest(
            schemaVersion: 1,
            actionID: actionID,
            operation: operation,
            remainingSeconds: remainingSeconds.map { min(max($0, 0), 86_400) },
            requestedAt: requestedAt
        )
        guard let data = try? JSONEncoder().encode(request), data.count <= 1_024 else { return }
        defaults.set(data, forKey: focusControlRequestKey)
    }

    static func consumeFocusControlRequest(
        now: Date = Date(),
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)
    ) -> FocusControlRequest? {
        guard let request = pendingFocusControlRequest(now: now, defaults: defaults) else { return nil }
        acknowledgeFocusControlRequest(request, defaults: defaults)
        return request
    }

    /// Peeks without consuming so the main app can acknowledge only after all
    /// ActivityKit and end-alert effects have completed successfully.
    static func pendingFocusControlRequest(
        now: Date = Date(),
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)
    ) -> FocusControlRequest? {
        guard let defaults else { return nil }
        guard let data = defaults.data(forKey: focusControlRequestKey),
              data.count <= 1_024,
              let request = try? JSONDecoder().decode(FocusControlRequest.self, from: data),
              request.schemaVersion == 1,
              request.remainingSeconds.map({ (0...86_400).contains($0) }) ?? true,
              request.requestedAt <= now.addingTimeInterval(60),
              request.requestedAt >= now.addingTimeInterval(-10 * 60) else {
            defaults.removeObject(forKey: focusControlRequestKey)
            return nil
        }
        return request
    }

    static func acknowledgeFocusControlRequest(
        _ request: FocusControlRequest,
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)
    ) {
        guard let defaults,
              let data = defaults.data(forKey: focusControlRequestKey),
              let current = try? JSONDecoder().decode(FocusControlRequest.self, from: data),
              current == request else { return }
        defaults.removeObject(forKey: focusControlRequestKey)
    }

    static func enqueueShareInboxEnvelope(
        _ envelope: ShareInboxEnvelope,
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)
    ) {
        guard validate(envelope),
              let defaults else { return }
        var values = pendingShareInboxEnvelopes(defaults: defaults)
        guard !values.contains(where: { $0.id == envelope.id }) else { return }
        values.append(envelope)
        values = Array(values.sorted { $0.createdAt < $1.createdAt }.suffix(32))
        guard let data = try? JSONEncoder().encode(values), data.count <= 32 * 1_024 else { return }
        defaults.set(data, forKey: shareInboxHandoffKey)
    }

    static func pendingShareInboxEnvelopes(
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)
    ) -> [ShareInboxEnvelope] {
        guard let defaults,
              let data = defaults.data(forKey: shareInboxHandoffKey),
              data.count <= 32 * 1_024,
              let values = try? JSONDecoder().decode([ShareInboxEnvelope].self, from: data) else {
            return []
        }
        return Array(values.filter(validate).prefix(32))
    }

    static func acknowledgeShareInboxEnvelope(
        id: UUID,
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)
    ) {
        guard let defaults else { return }
        let remaining = pendingShareInboxEnvelopes(defaults: defaults).filter { $0.id != id }
        if remaining.isEmpty {
            defaults.removeObject(forKey: shareInboxHandoffKey)
        } else if let data = try? JSONEncoder().encode(remaining), data.count <= 32 * 1_024 {
            defaults.set(data, forKey: shareInboxHandoffKey)
        }
    }

    private static func validate(_ envelope: ShareInboxEnvelope) -> Bool {
        let kinds: Set<String> = ["photo", "camera", "document", "text_scan", "file"]
        return envelope.schemaVersion == 1
            && kinds.contains(envelope.captureKind)
            && !envelope.captureReference.isEmpty
            && envelope.captureReference.utf8.count <= 160
            && !envelope.boundedTitle.isEmpty
            && envelope.boundedTitle.utf8.count <= 160
            && envelope.createdAt.timeIntervalSince1970.isFinite
    }

    static func clear(defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)) {
        defaults?.removeObject(forKey: snapshotKey)
        defaults?.removeObject(forKey: openCenterRequestKey)
        defaults?.removeObject(forKey: focusDraftRequestKey)
        defaults?.removeObject(forKey: focusControlRequestKey)
        defaults?.removeObject(forKey: shareInboxHandoffKey)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }
}

// MARK: - Intent parameters

enum SystemActionIntentKind: String, AppEnum {
    case calendarEvent = "calendar_event"
    case reminder
    case contactDraft = "contact_draft"
    case notification
    case route
    case capture
    case focusSession = "focus_session"
    case moment

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "动作类型"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .calendarEvent: "日历日程",
        .reminder: "提醒事项",
        .contactDraft: "联系人草稿",
        .notification: "本地通知",
        .route: "路线",
        .capture: "采集",
        .focusSession: "专注会话",
        .moment: "Moment"
    ]
}

// MARK: - High-value system actions

@available(iOS 16.0, *)
struct OpenSystemActionCenterIntent: AppIntent {
    static let title: LocalizedStringResource = "打开动作中心"
    static let description = IntentDescription(
        "查看、修改、批准或拒绝 DayPage 的系统动作提案。",
        categoryName: "System Actions",
        searchKeywords: ["approve", "proposal", "calendar", "审批", "提案", "系统动作"]
    )
    static let openAppWhenRun = true

    @Parameter(title: "提案")
    var proposal: SystemActionProposalEntity?

    static func buildURL(proposalID: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "daypage"
        components.host = "actions"
        if let proposalID, !proposalID.isEmpty {
            components.queryItems = [URLQueryItem(name: "proposal", value: proposalID)]
        }
        return components.url
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if EXTENSION
        // A ControlWidget cannot open UIApplication. Leave one bounded,
        // one-shot request for the foreground app instead.
        SystemActionSharedSummaryStore.requestOpenCenter(proposalID: proposal?.id)
        #else
        // The app target opens the canonical deep link directly. Writing the
        // bridge here as well caused RootView to consume a second stale
        // selection when the scene became active.
        if let url = Self.buildURL(proposalID: proposal?.id) {
            #if canImport(UIKit)
            await UIApplication.shared.open(url)
            #endif
        }
        #endif
        return .result()
    }
}

@available(iOS 16.0, *)
struct DraftSystemActionIntent: AppIntent {
    static let title: LocalizedStringResource = "起草系统动作"
    static let description = IntentDescription(
        "在 DayPage 中起草一个系统动作并打开确认页；不会直接修改系统数据。",
        categoryName: "System Actions",
        searchKeywords: ["draft", "calendar", "reminder", "草稿", "日程", "提醒"]
    )
    static let openAppWhenRun = true

    @Parameter(title: "类型")
    var kind: SystemActionIntentKind

    @Parameter(title: "标题")
    var actionTitle: String

    @Parameter(title: "补充说明")
    var notes: String?

    static func buildURL(kind: SystemActionIntentKind, title: String, notes: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "daypage"
        components.host = "actions"
        components.path = "/new"
        components.queryItems = [
            URLQueryItem(name: "kind", value: kind.rawValue),
            URLQueryItem(name: "title", value: title.systemActionPrefixUTF8Bytes(160)),
            URLQueryItem(name: "notes", value: notes.map { $0.systemActionPrefixUTF8Bytes(500) })
        ].filter { $0.value?.isEmpty == false }
        return components.url
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !EXTENSION
        if let url = Self.buildURL(kind: kind, title: actionTitle, notes: notes) {
            #if canImport(UIKit)
            await UIApplication.shared.open(url)
            #endif
        }
        #endif
        return .result()
    }
}

@available(iOS 16.0, *)
struct DraftFocusSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "准备专注会话"
    static let description = IntentDescription(
        "打开 DayPage 的专注确认页；确认后才会启动 Live Activity 和结束提醒。",
        categoryName: "Focus",
        searchKeywords: ["focus", "timer", "live activity", "专注", "计时"]
    )
    static let openAppWhenRun = true

    @Parameter(title: "名称", default: "专注")
    var focusTitle: String

    @Parameter(title: "分钟", default: 25, inclusiveRange: (1, 1_440))
    var durationMinutes: Int

    init() {
        focusTitle = "专注"
        durationMinutes = 25
    }

    static func buildURL(title: String, durationMinutes: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "daypage"
        components.host = "focus"
        components.path = "/new"
        components.queryItems = [
            URLQueryItem(name: "title", value: title.systemActionPrefixUTF8Bytes(160)),
            URLQueryItem(name: "minutes", value: String(min(max(durationMinutes, 1), 1_440)))
        ]
        return components.url
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if EXTENSION
        SystemActionSharedSummaryStore.requestFocusDraft(
            title: focusTitle,
            durationMinutes: durationMinutes
        )
        #else
        if let url = Self.buildURL(title: focusTitle, durationMinutes: durationMinutes) {
            #if canImport(UIKit)
            await UIApplication.shared.open(url)
            #endif
        }
        #endif
        return .result()
    }
}

// MARK: - Privacy-minimized read-only entities

/// A bounded App Group snapshot for Siri, Shortcuts and Spotlight discovery.
/// It contains stable identifiers and coarse metadata only: never memo bodies,
/// transcripts, entity names, place slugs, coordinates or action approvals.
enum DayPageReadOnlyEntitySnapshotStore {
    static let appGroupIdentifier = SystemActionSharedSummaryStore.appGroupIdentifier
    static let snapshotKey = "read-only-entities.snapshot.v1"
    static let navigationRequestKey = "read-only-entities.navigation-request.v1"
    static let privatePlaceMapKey = "read-only-entities.private-place-map.v1"
    static let privatePlaceIdentifierKey = "read-only-entities.private-place-identifier-key.v1"
    static let spotlightDomainIdentifier = "com.daypage.read-only-entities"
    static let maximumSnapshotBytes = 64 * 1_024
    static let maximumEntityCountPerKind = 32

    enum Kind: String, Codable, Sendable {
        case memo
        case dailyPage = "daily_page"
        case place
    }

    struct MemoSummary: Codable, Equatable, Sendable {
        let id: String
        let dateString: String
        let type: String
    }

    struct DailyPageSummary: Codable, Equatable, Sendable {
        let id: String
        let memoCount: Int
    }

    struct PlaceSummary: Codable, Equatable, Sendable {
        let id: String
    }

    struct Snapshot: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let generatedAt: Date
        let memos: [MemoSummary]
        let dailyPages: [DailyPageSummary]
        let places: [PlaceSummary]
    }

    struct NavigationRequest: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let kind: Kind
        let identifier: String
        let dateString: String?

        var url: URL? {
            var components = URLComponents()
            components.scheme = "daypage"
            switch kind {
            case .memo:
                guard UUID(uuidString: identifier) != nil,
                      let dateString,
                      Self.validDateString(dateString) else { return nil }
                components.host = "memo"
                components.path = "/open"
                components.queryItems = [
                    URLQueryItem(name: "id", value: identifier),
                    URLQueryItem(name: "date", value: dateString),
                ]
            case .dailyPage:
                guard Self.validDateString(identifier) else { return nil }
                components.host = "daily"
                components.queryItems = [URLQueryItem(name: "date", value: identifier)]
            case .place:
                guard Self.validOpaqueIdentifier(identifier) else { return nil }
                components.host = "place"
                components.queryItems = [URLQueryItem(name: "id", value: identifier)]
            }
            return components.url
        }

        private static func validDateString(_ value: String) -> Bool {
            DayPageReadOnlyEntitySnapshotStore.validDateString(value)
        }

        private static func validOpaqueIdentifier(_ value: String) -> Bool {
            DayPageReadOnlyEntitySnapshotStore.validOpaqueIdentifier(value)
        }
    }

    static func snapshot(
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)
    ) -> Snapshot? {
        guard let data = defaults?.data(forKey: snapshotKey),
              data.count <= maximumSnapshotBytes,
              let value = try? JSONDecoder().decode(Snapshot.self, from: data),
              value.schemaVersion == 1,
              value.memos.count <= maximumEntityCountPerKind,
              value.dailyPages.count <= maximumEntityCountPerKind,
              value.places.count <= maximumEntityCountPerKind,
              value.memos.allSatisfy({
                  UUID(uuidString: $0.id) != nil
                      && validDateString($0.dateString)
                      && ["text", "voice", "photo", "location", "mixed"].contains($0.type)
              }),
              value.dailyPages.allSatisfy({
                  validDateString($0.id) && (0...100_000).contains($0.memoCount)
              }),
              value.places.allSatisfy({ validOpaqueIdentifier($0.id) }) else {
            return nil
        }
        return value
    }

    @discardableResult
    static func write(
        _ snapshot: Snapshot,
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)
    ) -> Bool {
        let bounded = Snapshot(
            schemaVersion: 1,
            generatedAt: snapshot.generatedAt,
            memos: Array(snapshot.memos.prefix(maximumEntityCountPerKind)),
            dailyPages: Array(snapshot.dailyPages.prefix(maximumEntityCountPerKind)),
            places: Array(snapshot.places.prefix(maximumEntityCountPerKind))
        )
        guard let defaults,
              let data = try? JSONEncoder().encode(bounded),
              data.count <= maximumSnapshotBytes else { return false }
        defaults.set(data, forKey: snapshotKey)
        return true
    }

    static func requestOpen(
        kind: Kind,
        identifier: String,
        dateString: String? = nil,
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)
    ) {
        let request = NavigationRequest(
            schemaVersion: 1,
            kind: kind,
            identifier: String(identifier.prefix(128)),
            dateString: dateString.map { String($0.prefix(10)) }
        )
        guard request.url != nil,
              let data = try? JSONEncoder().encode(request),
              data.count <= 1_024 else { return }
        defaults?.set(data, forKey: navigationRequestKey)
    }

    static func consumeNavigationRequest(
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)
    ) -> NavigationRequest? {
        guard let defaults,
              let data = defaults.data(forKey: navigationRequestKey) else { return nil }
        defaults.removeObject(forKey: navigationRequestKey)
        guard data.count <= 1_024,
              let request = try? JSONDecoder().decode(NavigationRequest.self, from: data),
              request.schemaVersion == 1,
              request.url != nil else { return nil }
        return request
    }

    static func clear(
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier),
        privateDefaults: UserDefaults = .standard
    ) {
        defaults?.removeObject(forKey: snapshotKey)
        defaults?.removeObject(forKey: navigationRequestKey)
        privateDefaults.removeObject(forKey: privatePlaceMapKey)
        privateDefaults.removeObject(forKey: privatePlaceIdentifierKey)
    }

    #if !EXTENSION
    static func writePrivatePlaceMap(_ values: [String: String], defaults: UserDefaults = .standard) {
        let bounded: [String: String] = Dictionary(
            uniqueKeysWithValues: values.prefix(maximumEntityCountPerKind).compactMap { key, value in
                guard validOpaqueIdentifier(key),
                      !value.isEmpty,
                      value.utf8.count <= 120,
                      !value.contains("/"),
                      !value.contains("\\") else { return nil }
                return (key, value)
            }
        )
        defaults.set(bounded, forKey: privatePlaceMapKey)
    }

    static func placeIdentifierKey(defaults: UserDefaults = .standard) -> Data {
        if let existing = defaults.data(forKey: privatePlaceIdentifierKey), existing.count == 32 {
            return existing
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        defaults.set(data, forKey: privatePlaceIdentifierKey)
        return data
    }

    static func opaquePlaceIdentifier(slug: String, keyData: Data) -> String? {
        guard !slug.isEmpty,
              slug.utf8.count <= 120,
              keyData.count == 32 else { return nil }
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data(slug.utf8),
            using: SymmetricKey(data: keyData)
        )
        return authenticationCode.map { String(format: "%02x", $0) }.joined()
    }

    static func resolvePlaceSlug(_ identifier: String, defaults: UserDefaults = .standard) -> String? {
        guard validOpaqueIdentifier(identifier),
              let values = defaults.dictionary(forKey: privatePlaceMapKey) as? [String: String],
              let slug = values[identifier],
              !slug.isEmpty,
              slug.utf8.count <= 120,
              !slug.contains("/"),
              !slug.contains("\\") else { return nil }
        return slug
    }
    #endif

    static func validDateString(_ value: String) -> Bool {
        let fields = value.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0].count == 4,
              fields[1].count == 2,
              fields[2].count == 2,
              let year = Int(fields[0]),
              let month = Int(fields[1]),
              let day = Int(fields[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else { return false }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        return resolved.year == year && resolved.month == month && resolved.day == day
    }

    private static func validOpaqueIdentifier(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

struct DayPageMemoEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "DayPage Memo",
        numericFormat: "\(placeholder: .int) DayPage Memos"
    )
    static let defaultQuery = DayPageMemoEntityQuery()

    let id: String
    let dateString: String
    let type: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(Self.title(dateString))",
            subtitle: "\(Self.typeLabel(type))",
            image: .init(systemName: "note.text")
        )
    }

    private static func title(_ dateString: String) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("read_entity.memo.title", value: "Memo · %@", comment: ""),
            dateString
        )
    }

    private static func typeLabel(_ value: String) -> String {
        switch value {
        case "voice": return NSLocalizedString("语音 Memo", comment: "")
        case "photo": return NSLocalizedString("照片 Memo", comment: "")
        case "location": return NSLocalizedString("地点 Memo", comment: "")
        case "mixed": return NSLocalizedString("混合 Memo", comment: "")
        default: return NSLocalizedString("文本 Memo", comment: "")
        }
    }
}

struct DayPageMemoEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [DayPageMemoEntity] {
        let requested = Set(identifiers)
        return Self.values().filter { requested.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [DayPageMemoEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Self.values() }
        return Self.values().filter {
            $0.dateString.localizedCaseInsensitiveContains(query)
                || $0.type.localizedCaseInsensitiveContains(query)
        }
    }

    func suggestedEntities() async throws -> [DayPageMemoEntity] { Self.values() }

    private static func values() -> [DayPageMemoEntity] {
        (DayPageReadOnlyEntitySnapshotStore.snapshot()?.memos ?? []).map {
            DayPageMemoEntity(id: $0.id, dateString: $0.dateString, type: $0.type)
        }
    }
}

struct DayPageDailyPageEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "DayPage Daily Page",
        numericFormat: "\(placeholder: .int) DayPage Daily Pages"
    )
    static let defaultQuery = DayPageDailyPageEntityQuery()

    let id: String
    let memoCount: Int

    var displayRepresentation: DisplayRepresentation {
        let title = String.localizedStringWithFormat(
            NSLocalizedString("read_entity.daily.title", value: "Daily Page · %@", comment: ""),
            id
        )
        let subtitle = String.localizedStringWithFormat(
            NSLocalizedString("read_entity.daily.memo_count", value: "%lld memos", comment: ""),
            memoCount
        )
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)",
            image: .init(systemName: "calendar")
        )
    }
}

struct DayPageDailyPageEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [DayPageDailyPageEntity] {
        let requested = Set(identifiers)
        return Self.values().filter { requested.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [DayPageDailyPageEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Self.values() }
        return Self.values().filter { $0.id.localizedCaseInsensitiveContains(query) }
    }

    func suggestedEntities() async throws -> [DayPageDailyPageEntity] { Self.values() }

    private static func values() -> [DayPageDailyPageEntity] {
        (DayPageReadOnlyEntitySnapshotStore.snapshot()?.dailyPages ?? []).map {
            DayPageDailyPageEntity(id: $0.id, memoCount: $0.memoCount)
        }
    }
}

struct DayPagePlaceEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "DayPage Place",
        numericFormat: "\(placeholder: .int) DayPage Places"
    )
    static let defaultQuery = DayPagePlaceEntityQuery()

    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(NSLocalizedString("已保存地点", comment: ""))",
            subtitle: "\(NSLocalizedString("私密地点引用", comment: ""))",
            image: .init(systemName: "mappin.and.ellipse")
        )
    }
}

struct DayPagePlaceEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [DayPagePlaceEntity] {
        let requested = Set(identifiers)
        return Self.values().filter { requested.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [DayPagePlaceEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty
                || NSLocalizedString("已保存地点", comment: "").localizedCaseInsensitiveContains(query) else {
            return []
        }
        return Self.values()
    }

    func suggestedEntities() async throws -> [DayPagePlaceEntity] { Self.values() }

    private static func values() -> [DayPagePlaceEntity] {
        (DayPageReadOnlyEntitySnapshotStore.snapshot()?.places ?? []).map {
            DayPagePlaceEntity(id: $0.id)
        }
    }
}

@available(iOS 18.0, *)
extension DayPageMemoEntity: IndexedEntity {}
@available(iOS 18.0, *)
extension DayPageDailyPageEntity: IndexedEntity {}
@available(iOS 18.0, *)
extension DayPagePlaceEntity: IndexedEntity {}

@available(iOS 16.0, *)
struct OpenMemoEntityIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 Memo"
    static let description = IntentDescription("在 DayPage 中打开所选 Memo。此动作只导航，不读取 Memo 内容。")
    static let openAppWhenRun = true

    @Parameter(title: "Memo") var memo: DayPageMemoEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let request = DayPageReadOnlyEntitySnapshotStore.NavigationRequest(
            schemaVersion: 1,
            kind: .memo,
            identifier: memo.id,
            dateString: memo.dateString
        )
        #if EXTENSION
        DayPageReadOnlyEntitySnapshotStore.requestOpen(
            kind: .memo,
            identifier: memo.id,
            dateString: memo.dateString
        )
        #else
        if let url = request.url {
            #if canImport(UIKit)
            await UIApplication.shared.open(url)
            #endif
        }
        #endif
        return .result()
    }
}

@available(iOS 16.0, *)
struct OpenDailyPageEntityIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 Daily Page"
    static let description = IntentDescription("在 DayPage 中打开所选日期；系统入口只看到日期与 Memo 数量。")
    static let openAppWhenRun = true

    @Parameter(title: "Daily Page") var dailyPage: DayPageDailyPageEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let request = DayPageReadOnlyEntitySnapshotStore.NavigationRequest(
            schemaVersion: 1,
            kind: .dailyPage,
            identifier: dailyPage.id,
            dateString: nil
        )
        #if EXTENSION
        DayPageReadOnlyEntitySnapshotStore.requestOpen(kind: .dailyPage, identifier: dailyPage.id)
        #else
        if let url = request.url {
            #if canImport(UIKit)
            await UIApplication.shared.open(url)
            #endif
        }
        #endif
        return .result()
    }
}

@available(iOS 16.0, *)
struct OpenPlaceEntityIntent: AppIntent {
    static let title: LocalizedStringResource = "打开已保存地点"
    static let description = IntentDescription("在 DayPage 中打开私密地点引用；名称与坐标不会提供给系统入口。")
    static let openAppWhenRun = true

    @Parameter(title: "地点") var place: DayPagePlaceEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let request = DayPageReadOnlyEntitySnapshotStore.NavigationRequest(
            schemaVersion: 1,
            kind: .place,
            identifier: place.id,
            dateString: nil
        )
        #if EXTENSION
        DayPageReadOnlyEntitySnapshotStore.requestOpen(kind: .place, identifier: place.id)
        #else
        if let url = request.url {
            #if canImport(UIKit)
            await UIApplication.shared.open(url)
            #endif
        }
        #endif
        return .result()
    }
}

#if !EXTENSION
enum DayPageReadOnlyEntitySnapshotPublisher {
    struct Publication: Sendable {
        let snapshot: DayPageReadOnlyEntitySnapshotStore.Snapshot
        let privatePlaceMap: [String: String]
    }

    private static let maximumDayFileBytes = 2 * 1_024 * 1_024

    @MainActor
    static func refresh(
        vaultRoot: URL = VaultInitializer.vaultURL,
        spotlightEnabled: Bool = true
    ) async {
        let placeIdentifierKey = DayPageReadOnlyEntitySnapshotStore.placeIdentifierKey()
        let publication = await Task.detached(priority: .utility) {
            buildPublication(vaultRoot: vaultRoot, placeIdentifierKey: placeIdentifierKey)
        }.value
        guard DayPageReadOnlyEntitySnapshotStore.write(publication.snapshot) else { return }
        DayPageReadOnlyEntitySnapshotStore.writePrivatePlaceMap(publication.privatePlaceMap)
        await publishSpotlight(spotlightEnabled ? publication.snapshot : .init(
            schemaVersion: 1,
            generatedAt: publication.snapshot.generatedAt,
            memos: [],
            dailyPages: [],
            places: []
        ))
    }

    nonisolated static func buildPublication(vaultRoot: URL, placeIdentifierKey: Data) -> Publication {
        let fileManager = FileManager.default
        let rawDirectory = vaultRoot.appendingPathComponent("raw", isDirectory: true)
        let names = (try? fileManager.contentsOfDirectory(atPath: rawDirectory.path)) ?? []
        let dates = names.compactMap { name -> String? in
            guard name.hasSuffix(".md") else { return nil }
            let value = String(name.dropLast(3))
            return DayPageReadOnlyEntitySnapshotStore.validDateString(value) ? value : nil
        }.sorted(by: >)

        var memos: [DayPageReadOnlyEntitySnapshotStore.MemoSummary] = []
        var dailyPages: [DayPageReadOnlyEntitySnapshotStore.DailyPageSummary] = []
        for date in dates.prefix(DayPageReadOnlyEntitySnapshotStore.maximumEntityCountPerKind) {
            let url = rawDirectory.appendingPathComponent("\(date).md")
            guard let data = try? readBounded(url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let values = RawStorage.parse(fileContent: text)
            guard !values.isEmpty else { continue }
            dailyPages.append(.init(id: date, memoCount: min(values.count, 100_000)))
            for memo in values.sorted(by: { $0.created > $1.created }) {
                guard memos.count < DayPageReadOnlyEntitySnapshotStore.maximumEntityCountPerKind else { break }
                memos.append(.init(id: memo.id.uuidString.lowercased(), dateString: date, type: memo.type.rawValue))
            }
        }

        let placeDirectory = vaultRoot
            .appendingPathComponent("wiki", isDirectory: true)
            .appendingPathComponent("places", isDirectory: true)
        let placeNames = ((try? fileManager.contentsOfDirectory(atPath: placeDirectory.path)) ?? [])
            .filter { $0.hasSuffix(".md") }
            .sorted()
            .prefix(DayPageReadOnlyEntitySnapshotStore.maximumEntityCountPerKind)
        var places: [DayPageReadOnlyEntitySnapshotStore.PlaceSummary] = []
        var privatePlaceMap: [String: String] = [:]
        for name in placeNames {
            let slug = String(name.dropLast(3))
            guard !slug.isEmpty, slug.utf8.count <= 120 else { continue }
            guard let identifier = DayPageReadOnlyEntitySnapshotStore.opaquePlaceIdentifier(
                slug: slug,
                keyData: placeIdentifierKey
            ) else { continue }
            places.append(.init(id: identifier))
            privatePlaceMap[identifier] = slug
        }

        return Publication(
            snapshot: .init(
                schemaVersion: 1,
                generatedAt: Date(),
                memos: memos,
                dailyPages: dailyPages,
                places: places
            ),
            privatePlaceMap: privatePlaceMap
        )
    }

    nonisolated private static func readBounded(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumDayFileBytes else { throw CocoaError(.fileReadTooLarge) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumDayFileBytes + 1) ?? Data()
        guard data.count <= maximumDayFileBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    @MainActor
    private static func publishSpotlight(_ snapshot: DayPageReadOnlyEntitySnapshotStore.Snapshot) async {
        let indexer = AppleSpotlightIndexer()
        let domain = DayPageReadOnlyEntitySnapshotStore.spotlightDomainIdentifier
        var records: [AppleSpotlightRecord] = []
        records += snapshot.memos.map { value in
            let title = String.localizedStringWithFormat(
                NSLocalizedString("read_entity.memo.title", value: "Memo · %@", comment: ""),
                value.dateString
            )
            return AppleSpotlightRecord(
                identifier: "read-memo:\(value.id)",
                domainIdentifier: domain,
                title: title,
                summary: NSLocalizedString("不含正文的 Memo 引用", comment: ""),
                keywords: ["DayPage", "Memo"],
                expirationDate: Calendar.current.date(byAdding: .day, value: 30, to: Date()),
                contentURL: DayPageReadOnlyEntitySnapshotStore.NavigationRequest(
                    schemaVersion: 1,
                    kind: .memo,
                    identifier: value.id,
                    dateString: value.dateString
                ).url,
                privacySensitive: false
            )
        }
        records += snapshot.dailyPages.map { value in
            AppleSpotlightRecord(
                identifier: "read-daily:\(value.id)",
                domainIdentifier: domain,
                title: String.localizedStringWithFormat(
                    NSLocalizedString("read_entity.daily.title", value: "Daily Page · %@", comment: ""), value.id
                ),
                summary: String.localizedStringWithFormat(
                    NSLocalizedString("read_entity.daily.memo_count", value: "%lld memos", comment: ""), value.memoCount
                ),
                keywords: ["DayPage", "Daily Page"],
                expirationDate: Calendar.current.date(byAdding: .day, value: 30, to: Date()),
                contentURL: DayPageReadOnlyEntitySnapshotStore.NavigationRequest(
                    schemaVersion: 1,
                    kind: .dailyPage,
                    identifier: value.id,
                    dateString: nil
                ).url,
                privacySensitive: false
            )
        }
        records += snapshot.places.map { value in
            AppleSpotlightRecord(
                identifier: "read-place:\(value.id)",
                domainIdentifier: domain,
                title: NSLocalizedString("已保存地点", comment: ""),
                summary: NSLocalizedString("名称与坐标保持私密", comment: ""),
                keywords: ["DayPage"],
                expirationDate: Calendar.current.date(byAdding: .day, value: 30, to: Date()),
                contentURL: DayPageReadOnlyEntitySnapshotStore.NavigationRequest(
                    schemaVersion: 1,
                    kind: .place,
                    identifier: value.id,
                    dateString: nil
                ).url,
                privacySensitive: false
            )
        }
        do {
            try await indexer.clear(domainIdentifier: domain)
            if !records.isEmpty { try await indexer.upsert(records) }
        } catch {
            // Derived iOS 16 CoreSpotlight fallback; the bounded App Group
            // snapshot remains authoritative and a later refresh retries.
        }
    }
}
#endif

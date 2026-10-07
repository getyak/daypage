import Foundation

// MARK: - InsightStrategy

/// A user-chosen "洞察视角" (insight lens): a short title plus free-form
/// instructions that shape how the memo-anchored chat should look at the
/// record the user is holding open.
///
/// Data-safety contract (flomo-native refinement):
/// - Strategies are pure *user preference* — title + instructions only.
///   They must NEVER carry credentials, memo contents, retrieval evidence,
///   or any other vault material into UserDefaults. The store below only
///   persists this struct's two text fields plus a stable selection ID.
/// - A strategy is composed into the **user** question of a chat turn (see
///   ``composedInstruction()`` / `MemoryChatService.ask(insight:)`), never
///   into the system prompt. It cannot override the evidence, honesty, or
///   privacy rules that `MemoryChatService.systemPrompt` mandates.
/// - Builtins have stable IDs so tests, defaults, and future migrations can
///   address them without depending on localized titles.
public struct InsightStrategy: Identifiable, Equatable, Codable, Sendable {

    public enum Kind: String, Codable, Sendable {
        case builtin
        case custom
    }

    public let id: String
    public var title: String
    public var instructions: String
    public var kind: Kind

    public var isBuiltin: Bool { kind == .builtin }

    public init(id: String, title: String, instructions: String, kind: Kind = .custom) {
        self.id = id
        self.title = title
        self.instructions = instructions
        self.kind = kind
    }

    // MARK: Limits

    /// Trimmed non-empty title, capped at 40 characters.
    public static let maxTitleLength = 40
    /// Trimmed non-empty instructions, capped at 600 characters. Long enough
    /// for a real lens, short enough to keep one chat turn affordable.
    public static let maxInstructionsLength = 600

    // MARK: Stable builtin IDs

    public static let patternsID = "builtin.patterns"
    public static let challengeAssumptionID = "builtin.challenge-assumption"
    public static let nextSmallStepID = "builtin.next-small-step"

    /// The three useful builtins shipped with the product: look for
    /// recurring patterns, challenge the assumption inside the entry, and
    /// turn the reflection into one small next step.
    ///
    /// Localized at access time via the app's strings tables; the English
    /// `value:` defaults double as the host-test fallback (no bundle).
    public static let builtinStrategies: [InsightStrategy] = [
        InsightStrategy(
            id: patternsID,
            title: NSLocalizedString(
                "insight.strategy.patterns.title",
                value: "Recurring patterns",
                comment: "Insight strategy — look for recurring patterns"
            ),
            instructions: NSLocalizedString(
                "insight.strategy.patterns.body",
                value: "Look across my dated records for genuine repetitions or shifts around this entry. Only call something a pattern when several dated records support it, and say so when the evidence is thin.",
                comment: "Insight strategy — recurring patterns instructions"
            ),
            kind: .builtin
        ),
        InsightStrategy(
            id: challengeAssumptionID,
            title: NSLocalizedString(
                "insight.strategy.challenge.title",
                value: "Challenge the assumption",
                comment: "Insight strategy — challenge the assumption"
            ),
            instructions: NSLocalizedString(
                "insight.strategy.challenge.body",
                value: "Find the assumption this entry rests on, then offer at least one plausible alternative reading grounded in my records. Keep facts and interpretation clearly separate.",
                comment: "Insight strategy — challenge the assumption instructions"
            ),
            kind: .builtin
        ),
        InsightStrategy(
            id: nextSmallStepID,
            title: NSLocalizedString(
                "insight.strategy.nextStep.title",
                value: "One small next step",
                comment: "Insight strategy — one small next step"
            ),
            instructions: NSLocalizedString(
                "insight.strategy.nextStep.body",
                value: "Turn this reflection into one small, concrete step I could try before the week ends, plus one question that would tell me whether the step was worth it.",
                comment: "Insight strategy — one small next step instructions"
            ),
            kind: .builtin
        ),
    ]

    /// The strategy a fresh install (or a repaired store) falls back to.
    public static var defaultStrategy: InsightStrategy {
        builtinStrategies[0]
    }

    // MARK: Composition (user instruction, never a system instruction)

    /// The text the "开始洞察" action sends as the *user* question. The lens
    /// is the user's own instruction on how to look at their anchored memo —
    /// it is deliberately assembled on the user side of the prompt so it can
    /// never masquerade as (or override) the evidence/privacy system rules.
    public func composedInstruction() -> String {
        let label = NSLocalizedString(
            "insight.strategy.prompt.label",
            value: "Insight lens",
            comment: "Prefix label when a strategy is composed into the user question"
        )
        return "\(label): \(title)\n\(instructions)"
    }
}

// MARK: - InsightStrategyValidationError

public enum InsightStrategyValidationError: Error, Equatable {
    case emptyTitle
    case emptyInstructions
    case titleTooLong
    case instructionsTooLong
}

// MARK: - InsightStrategyDraft

/// Trim + validate helper shared by the strategy editor UI and any future
/// import path. Kept pure (no store access) so the rules are unit-testable.
public enum InsightStrategyDraft {

    /// Trims both fields, validates non-empty + length, and returns the
    /// normalized pair. Throws ``InsightStrategyValidationError`` otherwise.
    public static func validated(
        title: String,
        instructions: String
    ) throws -> (title: String, instructions: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw InsightStrategyValidationError.emptyTitle }
        guard !cleanInstructions.isEmpty else { throw InsightStrategyValidationError.emptyInstructions }
        guard cleanTitle.count <= InsightStrategy.maxTitleLength else {
            throw InsightStrategyValidationError.titleTooLong
        }
        guard cleanInstructions.count <= InsightStrategy.maxInstructionsLength else {
            throw InsightStrategyValidationError.instructionsTooLong
        }
        return (cleanTitle, cleanInstructions)
    }
}

// MARK: - InsightStrategyStore

/// Local preference store for custom insight strategies + the current
/// selection. Backed by an **injected** `UserDefaults` so tests never touch
/// the app suite, mirroring the FeatureFlagStore pattern.
///
/// Persisted keys (both v1):
/// - `insight.customStrategies.v1` — JSON array of custom strategies.
/// - `insight.selectedStrategyID.v1` — the selected strategy's stable ID.
///
/// Repair rule: if the selected ID no longer resolves (e.g. the custom
/// strategy was deleted), selection resets to ``InsightStrategy/defaultStrategy``
/// and the repair is persisted immediately.
@MainActor
public final class InsightStrategyStore: ObservableObject {

    public static let customStrategiesKey = "insight.customStrategies.v1"
    public static let selectedStrategyKey = "insight.selectedStrategyID.v1"

    /// Builtins first (stable order), then custom strategies in user order.
    @Published public private(set) var customStrategies: [InsightStrategy] = []
    @Published public private(set) var selectedID: String = InsightStrategy.defaultStrategy.id

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.customStrategiesKey),
           let decoded = try? JSONDecoder().decode([InsightStrategy].self, from: data) {
            customStrategies = decoded.filter { $0.kind == .custom }
        }
        let saved = defaults.string(forKey: Self.selectedStrategyKey) ?? InsightStrategy.defaultStrategy.id
        // Resolve through the lookup so a stale ID repairs immediately.
        selectedID = strategy(id: saved)?.id ?? InsightStrategy.defaultStrategy.id
        if selectedID != saved { defaults.set(selectedID, forKey: Self.selectedStrategyKey) }
    }

    // MARK: Read

    public var builtinStrategies: [InsightStrategy] { InsightStrategy.builtinStrategies }

    public var allStrategies: [InsightStrategy] { builtinStrategies + customStrategies }

    public func strategy(id: String) -> InsightStrategy? {
        allStrategies.first { $0.id == id }
    }

    /// The currently selected strategy. If the selection is stale (deleted
    /// custom strategy, unknown ID) this repairs the store: selection falls
    /// back to the default builtin and is persisted.
    public var selectedStrategy: InsightStrategy {
        if let found = strategy(id: selectedID) { return found }
        let fallback = InsightStrategy.defaultStrategy
        selectedID = fallback.id
        defaults.set(fallback.id, forKey: Self.selectedStrategyKey)
        return fallback
    }

    // MARK: Selection

    /// Selects an existing strategy. Unknown IDs are ignored (no-op).
    @discardableResult
    public func select(_ id: String) -> Bool {
        guard strategy(id: id) != nil else { return false }
        selectedID = id
        defaults.set(id, forKey: Self.selectedStrategyKey)
        return true
    }

    // MARK: Create / edit / delete custom strategies

    /// Creates a new custom strategy (when `id == nil`) or edits the custom
    /// strategy with the given ID. Builtin strategies are never overwritten.
    /// Returns the stored strategy.
    @discardableResult
    public func saveCustom(
        id: String? = nil,
        title: String,
        instructions: String
    ) throws -> InsightStrategy {
        let (cleanTitle, cleanInstructions) = try InsightStrategyDraft.validated(
            title: title, instructions: instructions
        )
        if let id, let index = customStrategies.firstIndex(where: { $0.id == id }) {
            customStrategies[index].title = cleanTitle
            customStrategies[index].instructions = cleanInstructions
            persist()
            return customStrategies[index]
        }
        let strategy = InsightStrategy(
            id: "custom.\(UUID().uuidString)",
            title: cleanTitle,
            instructions: cleanInstructions,
            kind: .custom
        )
        customStrategies.append(strategy)
        persist()
        return strategy
    }

    /// Deletes a custom strategy. Builtin IDs are ignored. When the deleted
    /// strategy was selected, selection resets to the default builtin and the
    /// fallback is persisted — the UI never ends up with a dangling lens.
    public func deleteCustom(id: String) {
        guard customStrategies.contains(where: { $0.id == id }) else { return }
        customStrategies.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = InsightStrategy.defaultStrategy.id
            defaults.set(selectedID, forKey: Self.selectedStrategyKey)
        }
        persist()
    }

    // MARK: Private

    private func persist() {
        if let data = try? JSONEncoder().encode(customStrategies) {
            defaults.set(data, forKey: Self.customStrategiesKey)
        }
    }
}

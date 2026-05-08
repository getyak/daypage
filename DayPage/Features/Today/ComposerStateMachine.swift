import Foundation

// MARK: - ComposerState

enum ComposerState: Equatable {
    case idle
    case expanding
    case open
    case collapsing
}

// MARK: - ComposerStateMachine

/// Pure state machine for the text-composer open/close lifecycle.
/// Extracted from InputBarV4 so it can be unit-tested without SwiftUI.
///
/// Legal transitions:
///   idle       → expanding   (user taps "Aa")
///   expanding  → open        (spring animation settles)
///   open       → collapsing  (user taps chevron-down or sends)
///   collapsing → idle        (spring animation settles)
///
/// All other transitions are rejected. While .expanding or .collapsing,
/// no new transition is accepted (debounce).
@MainActor
final class ComposerStateMachine: ObservableObject {

    @Published private(set) var state: ComposerState = .idle

    /// Attempt a transition. Returns `true` if accepted, `false` if rejected.
    @discardableResult
    func transition(to next: ComposerState) -> Bool {
        guard state != .expanding && state != .collapsing else { return false }
        guard state != next else { return false }

        switch (state, next) {
        case (.idle, .expanding),
             (.expanding, .open),
             (.open, .collapsing),
             (.collapsing, .idle):
            state = next
            return true
        default:
            return false
        }
    }
}

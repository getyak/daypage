import Foundation

// MARK: - ComposerState

/// Lifecycle states for the text-composer open/close animation.
///
/// - `idle`:        composer is collapsed to the input pill.
/// - `expanding`:   spring animation from pill → card is in flight.
/// - `open`:        composing card is fully presented; keyboard up.
/// - `collapsing`:  spring animation from card → pill is in flight.
enum ComposerState: Equatable {
    case idle
    case expanding
    case open
    case collapsing
}

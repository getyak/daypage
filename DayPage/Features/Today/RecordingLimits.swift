import Foundation

// MARK: - RecordingLimits
//
// Single source of truth for the recording duration warning thresholds shared
// by the three recording surfaces (DynamicIslandView, RecordingSheetView,
// VoiceRecordingView). Each surface keeps its own color palette — the amber and
// red tints differ because they sit on different backgrounds (black pill / dark
// sheet / light sheet) — so this type owns only the *thresholds* and the stage
// classification, not the colors.
enum RecordingLimits {

    /// Soft cap: the timer warms to amber past 5:00.
    static let amberThreshold = 300  // 5:00
    /// Hard warning: the timer flips to red past 9:00 (approaching the practical
    /// transcription limit).
    static let redThreshold = 540  // 9:00

    /// The warning stage a given elapsed time falls into. Each view maps these
    /// stages onto its own tint tokens.
    enum Stage {
        case normal
        case warning
        case critical
    }

    /// Classify whole elapsed seconds into a warning stage.
    static func stage(for elapsedSeconds: Int) -> Stage {
        if elapsedSeconds >= redThreshold {
            return .critical
        } else if elapsedSeconds >= amberThreshold {
            return .warning
        } else {
            return .normal
        }
    }
}
